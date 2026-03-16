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

In `torchtitan-health-check-a100.jobset.yaml`:

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
- Keep label: `kueue.x-k8s.io/queue-name: torchtitan-a100`
- Apply: `kubernetes/kueue-a100.yaml`

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
