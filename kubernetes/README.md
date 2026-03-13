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
# Authenticate to OCIR first:
docker login aga.ocir.io

# Build and push CUDA image (defaults to tag cuda-latest if omitted)
./kubernetes/build-and-push.sh cuda a100-latest
```

- Dockerfile: `kubernetes/Dockerfile.cuda`
- Registry target: `aga.ocir.io/hpc/cpv/torchtitan:<tag>`

### AMD BM.GPU.MI300X.8

```bash
# Authenticate to OCIR first, then:
./kubernetes/build-and-push.sh rocm              # tags as rocm-latest
./kubernetes/build-and-push.sh rocm v1.0.0       # optional custom tag
# Backward-compatible usage still works:
./kubernetes/build-and-push.sh v1.0.0
```

- Dockerfile: `kubernetes/Dockerfile.rocm` (base `docker.io/rocm/primus:v25.9_gfx942`)

## Deploy

### NVIDIA BM.GPU4.8 / A100

```bash
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
