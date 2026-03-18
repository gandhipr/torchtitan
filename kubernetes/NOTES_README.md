# TorchTitan Kubernetes Notes (Quick Understanding)

This is a short, practical guide for understanding the full flow on OKE.

## 1) HPC mindset -> Kubernetes mindset

- `sbatch` job (Slurm) -> `JobSet` (Kubernetes)
- allocated nodes -> pods scheduled to nodes
- rank/task id -> pod index (`JOB_COMPLETION_INDEX`)
- container image -> runtime env for each pod

## 2) End-to-end flow

1. Build + push image to OCIR
2. Ensure cluster can pull private image (secret or instance principal)
3. Apply JobSet
4. Watch pods and logs
5. Tune workload if OOM

## 3) Why 2 pods?

In `torchtitan-health-check-cuda.jobset.yaml`:

- `completions: 2`
- `parallelism: 2`
- `NNODES: "2"`

So Kubernetes creates **2 pods** (rank-0 and rank-1), one per GPU node.

For 1-node smoke test, set all three to `1`.

## 4) What is Kueue and why use it?

Kueue is queue/admission control for batch workloads.

- Use Kueue for quota/fair scheduling
- Skip Kueue for quick debugging and bring-up

### With Kueue
- Keep label: `kueue.x-k8s.io/queue-name: torchtitan-cuda`
- Apply: `kubernetes/kueue-cuda.yaml`

### Without Kueue
- Remove queue label from JobSet
- Apply JobSet directly

## 5) Secrets (private OCIR image pulls)

If you see `ErrImagePull` / `ImagePullBackOff` with anonymous-read errors,
pods are not using OCIR credentials.

### Why secret is needed for YAML, but not for build/push script

These are two different authentication contexts:

1. **Build/push script** (`docker build`, `docker push`)
   - Runs on your local shell host.
   - Uses your local Docker login session (`docker login`).
   - Kubernetes is not involved.

2. **Kubernetes YAML deployment** (`kubectl apply`)
   - Image pull is done by kubelet on worker nodes.
   - Worker nodes do not automatically use your local Docker login.
   - Nodes need their own pull auth via:
     - `imagePullSecrets` (this guide), or
     - OKE credential provider / instance principal.

So even if push succeeds locally, pod pulls can still fail without node-side auth.

Use `ocir-secret` and attach to default serviceaccount:

```bash
kubectl create secret docker-registry ocir-secret \
  --docker-server=aga.ocir.io \
  --docker-username='<namespace>/<username>' \
  --docker-password='<auth-token>' \
  --docker-email='noreply@example.com' \
  -n default --dry-run=client -o yaml | kubectl apply -f -

kubectl patch serviceaccount default -n default \
  -p '{"imagePullSecrets":[{"name":"ocir-secret"}]}'
```

## 6) Common status meanings

- `SUSPENDED=true` on JobSet -> waiting for Kueue admission
- `ContainerCreating` -> image pull / startup in progress
- `ErrImagePull` -> auth/path/tag issue
- `OutOfMemoryError` -> lower `LOCAL_BATCH_SIZE` and/or `SEQ_LEN`

## 7) Basic tuning understanding: batch size vs sequence length

When running training benchmarks, `LOCAL_BATCH_SIZE` and `SEQ_LEN` both affect
how hard the GPUs are pushed.

- Higher **batch size** usually improves GPU utilization, up to a limit.
- Higher **sequence length** increases work per sample, also up to a limit.
- Increasing either one too much can cause failures (OOM, timeout, instability).

So there is no simple “always proportional” or “always inverse” relationship.
In practice, you tune both together and stop when runs stop improving or become
unstable.

Practical approach:
1. Increase `SEQ_LEN` step by step until failure.
2. At the max passing `SEQ_LEN`, increase `LOCAL_BATCH_SIZE` until failure.
3. Rank passing runs by highest throughput (TFLOPs), then efficiency (MFU).

## 8) `COMPILE=0` vs `COMPILE=1`

- **`COMPILE=0`**: normal eager execution (no `torch.compile`)
  - Usually more predictable
  - Simpler debugging
  - Lower startup overhead

- **`COMPILE=1`**: enables `torch.compile` graph compilation
  - Can improve steady-state speed/TFLOPs on some configs
  - Can add compile/startup cost
  - Can show different stability/performance behavior depending on shape/model/config

So in practice:
- `COMPILE=0` is a stable baseline
- `COMPILE=1` is an optimization mode that may be faster (or sometimes not) for a given combo
