# torchtitan on Kubernetes (OCI OKE)

Runs `llama3_health_check` (Llama3-8B with synthetic data) on OCI OKE GPU nodes and reports TFLOPs/MFU. No dataset or tokenizer required.

For an easy conceptual overview (sbatch vs JobSet, Kueue, secrets, pod states), see:
`kubernetes/NOTES_README.md`

## Choose your GPU shape first (important)

Use the matching files/commands below to avoid mixing AMD and NVIDIA paths.

| GPU Shape | Vendor | Build target | JobSet file | Kueue file |
|---|---|---|---|---|
| `BM.GPU4.8` | NVIDIA (CUDA) | `./kubernetes/build-and-push.sh cuda <tag>` | `kubernetes/torchtitan-health-check-cuda.jobset.yaml` | `kubernetes/kueue-cuda.yaml` |
| `BM.GPU.MI300X.8` | AMD (MI300X) | `./kubernetes/build-and-push.sh rocm <tag>` | `kubernetes/torchtitan-health-check.jobset.yaml` | `kubernetes/kueue-mi300x.yaml` |

Quick check of your cluster shape labels:

```bash
kubectl get nodes --show-labels | grep -E 'node.kubernetes.io/instance-type|nvidia.com/gpu.present|amd.com/gpu'
```

## Setup

Go to https://github.com/oracle-quickstart/oci-hpc-oke -> Deploy to Oracle Cloud to deploy your OKE cluster.

When it is deployed, connect locally by going to console -> OKE -> Select your cluster -> Actions -> Access cluster -> Local Access.

You are now ready to deploy in the next steps.

## Prerequisites (both AMD + NVIDIA)

- OCI OKE cluster with GPU worker nodes
- [JobSet controller](https://github.com/kubernetes-sigs/jobset) installed
- [Kueue](https://kueue.sigs.k8s.io/) installed (or remove the `kueue.x-k8s.io/queue-name` label from the JobSet)
- OCI Container Registry credentials configured (`kubectl create secret` or instance principal)
- If Docker is not installed on your build host, install and verify it first:

```bash
sudo apt-get install -y docker.io
ls -l /var/run/docker.sock
sudo usermod -aG docker ubuntu
newgrp docker
docker ps
```

## Recommended run order (same steps, shape-specific commands)

### Step 1) Login + set tag

**CUDA/NVIDIA**
```bash
docker login aga.ocir.io -u '<namespace>/<username>'
export TAG="cuda-dev-$(date +%m%d-%H%M)"
```

**MI300X (AMD)**
```bash
docker login aga.ocir.io -u '<namespace>/<username>'
export TAG="rocm-dev-$(date +%m%d-%H%M)"
```

### Step 2) Build and push image

**CUDA/NVIDIA**
```bash
./kubernetes/build-and-push.sh cuda "${TAG}"
```

Pushed image format (CUDA):
`aga.ocir.io/hpc/cpv/torchtitan_cuda/torchtitan:${TAG}`

**MI300X (AMD)**
```bash
./kubernetes/build-and-push.sh rocm "${TAG}"
```

### Step 3) Configure OCIR pull secret in cluster (one-time, both shapes)

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

### Step 4) Set image tag in JobSet

**CUDA/NVIDIA**
```bash
sed -i "s|image: .*|image: aga.ocir.io/hpc/cpv/torchtitan_cuda/torchtitan:${TAG}|" kubernetes/torchtitan-health-check-cuda.jobset.yaml
```

**MI300X (AMD)**
```bash
# update this only if you use a custom ROCm tag
sed -i "s|image: .*|image: aga.ocir.io/hpc/cpv/torchtitan_rocm/torchtitan:${TAG}|" kubernetes/torchtitan-health-check.jobset.yaml
```

### Step 5A) Deploy without Kueue (recommended for bring-up)

**CUDA/NVIDIA**
```bash
sed -i '/kueue.x-k8s.io\/queue-name:/d' kubernetes/torchtitan-health-check-cuda.jobset.yaml
kubectl delete jobset torchtitan-health-check-cuda --ignore-not-found
kubectl apply -f kubernetes/torchtitan-health-check-cuda.jobset.yaml
```

**MI300X (AMD)**
```bash
sed -i '/kueue.x-k8s.io\/queue-name:/d' kubernetes/torchtitan-health-check.jobset.yaml
kubectl delete jobset torchtitan-health-check --ignore-not-found
kubectl apply -f kubernetes/torchtitan-health-check.jobset.yaml
```

### Step 5B) Deploy with Kueue (optional)

**CUDA/NVIDIA**
```bash
kubectl apply -f kubernetes/kueue-cuda.yaml
kubectl delete jobset torchtitan-health-check-cuda --ignore-not-found
kubectl apply -f kubernetes/torchtitan-health-check-cuda.jobset.yaml
```

**MI300X (AMD)**
```bash
kubectl apply -f kubernetes/kueue-mi300x.yaml
kubectl delete jobset torchtitan-health-check --ignore-not-found
kubectl apply -f kubernetes/torchtitan-health-check.jobset.yaml
```

## Check results

```bash
# Watch pod status
kubectl get pods -w -l jobset.sigs.k8s.io/jobset-name=torchtitan-health-check-cuda

# View logs (training metrics + health check summary)
kubectl logs -l jobset.sigs.k8s.io/jobset-name=torchtitan-health-check-cuda --tail=20
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
kubectl delete jobset torchtitan-health-check-cuda
```

For AMD, delete `torchtitan-health-check`.

## Tuning

Edit env vars in the manifest you are running:
- NVIDIA: `torchtitan-health-check-cuda.jobset.yaml`
- AMD: `torchtitan-health-check.jobset.yaml`

| Variable | Default | Description |
|---|---|---|
| `NNODES` | `2` (CUDA default) / `4` (MI300X) | Number of nodes (also set `completions`/`parallelism`) |
| `LOCAL_BATCH_SIZE` | `1` (CUDA default) | Per-GPU batch size; decrease on OOM, increase when stable |
| `SEQ_LEN` | `1024` (CUDA default) | Sequence length; reduce to `1024` for quick smoke test |
| `STEPS` | `25` | Training steps |
| `COMPILE` | `0` | Set to `1` to enable `torch.compile` |

## NVIDIA/CUDA files

- `kubernetes/torchtitan-health-check-cuda.jobset.yaml`
- `kubernetes/kueue-cuda.yaml`
