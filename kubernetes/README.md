# torchtitan on Kubernetes (OCI OKE)

Runs `llama3_health_check` (Llama3-8B with synthetic data) on OCI OKE GPU nodes and reports TFLOPs/MFU. No dataset or tokenizer required.

## Setup

Go to https://github.com/oracle-quickstart/oci-hpc-oke -> Deploy to Oracle Cloud to deploy your OKE cluster.

When it is deployed, connect locally by going to console -> OKE -> Select your cluster -> Actions -> Access cluster -> Local Access.

You are now ready to deploy in the next steps.

## Prerequisites (both AMD + NVIDIA)

- OCI OKE cluster with GPU worker nodes
- [JobSet controller](https://github.com/kubernetes-sigs/jobset) installed
- [Kueue](https://kueue.sigs.k8s.io/) installed (or remove the `kueue.x-k8s.io/queue-name` label from the JobSet)
- OCI Container Registry credentials configured (`kubectl create secret` or instance principal)

## Build and push image

### NVIDIA BM.GPU4.8 / A100 (2-node default)

```bash
# Pick a tag for this run (example: a100-dev-0316-0943)
export TAG="a100-dev-$(date +%m%d-%H%M)"

# Build and push CUDA image with that tag
./kubernetes/build-and-push.sh cuda "${TAG}"
```

What tag should you use?
- For quick iteration: `a100-dev-<date>-<time>` (recommended)
- For stable/shared runs: `a100-latest` or a release tag like `v1.0.0`

The pushed CUDA image path is:
`aga.ocir.io/hpc/cpv/torchtitan_cuda/torchtitan:${TAG}`

### AMD BM.GPU.MI300X.8

```bash
# Authenticate to OCIR first, then:
./kubernetes/build-and-push.sh rocm              # tags as rocm-latest
./kubernetes/build-and-push.sh rocm v1.0.0       # optional custom tag
# Backward-compatible usage still works:
./kubernetes/build-and-push.sh v1.0.0
```

- Dockerfile: `kubernetes/Dockerfile.rocm` (base `docker.io/rocm/primus:v25.9_gfx942`)

## OCIR pull secret (for private images)

If pods fail with `ErrImagePull` / `ImagePullBackOff` and an anonymous pull error,
create an OCIR pull secret and attach it to the `default` service account:

```bash
kubectl create secret docker-registry ocir-secret \
  --docker-server=aga.ocir.io \
  --docker-username='<namespace>/<username>' \
  --docker-password='<auth-token>' \
  --docker-email='noreply@example.com' \
  -n default --dry-run=client -o yaml | kubectl apply -f -

kubectl patch serviceaccount default -n default \
  -p '{"imagePullSecrets":[{"name":"ocir-secret"}]}'

# verify
kubectl get sa default -n default -o yaml | grep -A3 imagePullSecrets
```

> Note: `docker-email` is required by command syntax, but any placeholder value is fine.

## Deploy

### NVIDIA BM.GPU4.8 / A100

#### Option A (recommended now): run **without Kueue**

Use this mode when you do **not** want queue admission:
- Remove `kueue.x-k8s.io/queue-name` label from the JobSet.

```bash
# Remove queue label so JobSet is not suspended waiting for LocalQueue/ClusterQueue.
sed -i '/kueue.x-k8s.io\/queue-name:/d' kubernetes/torchtitan-health-check-a100.jobset.yaml

# Keep image tag in sync with what you just pushed
sed -i "s|image: .*|image: aga.ocir.io/hpc/cpv/torchtitan_cuda/torchtitan:${TAG}|" kubernetes/torchtitan-health-check-a100.jobset.yaml

kubectl delete jobset torchtitan-health-check-a100 --ignore-not-found
kubectl apply -f kubernetes/torchtitan-health-check-a100.jobset.yaml
```

#### Option B: run with Kueue [Not yet validated]

Use this mode when you want queue admission/scheduling:
- Keep/add `kueue.x-k8s.io/queue-name: torchtitan-a100` in the JobSet.

```bash
# Create matching ClusterQueue + LocalQueue for queue label "torchtitan-a100"
kubectl apply -f kubernetes/kueue-a100.yaml

# Ensure queue label exists in JobSet metadata.labels
grep -q 'kueue.x-k8s.io/queue-name:' kubernetes/torchtitan-health-check-a100.jobset.yaml || \
  sed -i '/^  labels:/a\    kueue.x-k8s.io/queue-name: torchtitan-a100' kubernetes/torchtitan-health-check-a100.jobset.yaml

# Verify queues are present
kubectl get clusterqueue
kubectl get localqueue -n default

# Keep image tag in sync with what you just pushed
sed -i "s|image: .*|image: aga.ocir.io/hpc/cpv/torchtitan_cuda/torchtitan:${TAG}|" kubernetes/torchtitan-health-check-a100.jobset.yaml

kubectl delete jobset torchtitan-health-check-a100 --ignore-not-found
kubectl apply -f kubernetes/torchtitan-health-check-a100.jobset.yaml
```

```bash
# (Optional) keep image tag in sync with what you just pushed
sed -i "s|image: .*|image: aga.ocir.io/hpc/cpv/torchtitan_cuda/torchtitan:${TAG}|" kubernetes/torchtitan-health-check-a100.jobset.yaml

kubectl apply -f kubernetes/torchtitan-health-check-a100.jobset.yaml
```

### AMD BM.GPU.MI300X.8

```bash
kubectl apply -f kubernetes/torchtitan-health-check.jobset.yaml
```

## Check results

```bash
# Watch pod status
kubectl get pods -w -l jobset.sigs.k8s.io/jobset-name=torchtitan-health-check-a100

# View logs (training metrics + health check summary)
kubectl logs -l jobset.sigs.k8s.io/jobset-name=torchtitan-health-check-a100 --tail=20
```

For AMD, replace the label value with `torchtitan-health-check`.

The last lines of each pod's log print:
```
===========================================
TORCHTITAN HEALTH CHECK RESULT
  Node rank : 0
  TFLOPs    : 103.95
  MFU       : 8.00%
  Status    : PASS
===========================================
```

## Clean up

```bash
kubectl delete jobset torchtitan-health-check-a100
```

For AMD, delete `torchtitan-health-check`.

## Tuning

Edit env vars in the manifest you are running:
- NVIDIA: `torchtitan-health-check-a100.jobset.yaml`
- AMD: `torchtitan-health-check.jobset.yaml`

| Variable | Default | Description |
|---|---|---|
| `NNODES` | `2` (A100) / `4` (MI300X) | Number of nodes (also set `completions`/`parallelism`) |
| `LOCAL_BATCH_SIZE` | `20` | Per-GPU batch size; increase to raise memory/MFU |
| `SEQ_LEN` | `8192` | Sequence length |
| `STEPS` | `25` | Training steps |
| `COMPILE` | `0` | Set to `1` to enable `torch.compile` |
