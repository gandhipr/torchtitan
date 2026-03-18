# torchtitan on Kubernetes (OCI OKE)

Runs `llama3_health_check` (Llama3-8B with synthetic data) on OCI OKE GPU nodes and reports TFLOPs/MFU. No dataset or tokenizer required.

## Contents

- [Choose your GPU shape first (important)](#choose-your-gpu-shape-first-important)
- [Setup](#setup)
- [Prerequisites (both AMD + NVIDIA)](#prerequisites-both-amd--nvidia)
- [Recommended run order (same steps, shape-specific commands)](#recommended-run-order-same-steps-shape-specific-commands)
- [Check results](#check-results)
- [Clean up](#clean-up)
- [Small summary: Fields you typically update](#small-summary-fields-you-typically-update)
- [Tuning](#tuning)
- [Benchmarking matrix](#benchmarking-matrix)

For an easy conceptual overview (sbatch vs JobSet, Kueue, secrets, pod states), see:
`kubernetes/NOTES_README.md`

## Choose your GPU shape first (important)

Use the matching files/commands below to avoid mixing AMD and NVIDIA paths.

| GPU Shape | Vendor | Build target | JobSet file | Kueue file |
|---|---|---|---|---|
| `BM.GPU.B4.8` / `BM.GPU4.8` | NVIDIA (CUDA) | `./kubernetes/build-and-push.sh cuda <tag>` | `kubernetes/torchtitan-health-check-cuda.jobset.yaml` | `kubernetes/kueue-cuda.yaml` |
| `BM.GPU.MI300X.8` | AMD (MI300X) | `./kubernetes/build-and-push.sh rocm <tag>` | `kubernetes/torchtitan-health-check.jobset.yaml` | `kubernetes/kueue-mi300x.yaml` |

Quick check of your cluster shape labels:

```bash
kubectl get nodes --show-labels | grep -E 'node.kubernetes.io/instance-type|nvidia.com/gpu.present|amd.com/gpu'
```

> NVIDIA shape label note: some clusters report `BM.GPU.B4.8`, others `BM.GPU4.8`.
> Always match `node.kubernetes.io/instance-type` in your JobSet to the exact label
> shown by `kubectl get nodes --show-labels`.

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

### Step 5) Verify/update NVIDIA node selector (do once before deploy)

```bash
# See the actual NVIDIA instance-type label in your cluster
kubectl get nodes --show-labels | grep -E 'node.kubernetes.io/instance-type=.*BM.GPU'

# Example: update selector to BM.GPU.B4.8 if that's what your cluster uses
sed -i "s/node.kubernetes.io\/instance-type: .*/node.kubernetes.io\/instance-type: BM.GPU.B4.8/" kubernetes/torchtitan-health-check-cuda.jobset.yaml
```

### Step 6A) Deploy without Kueue (recommended for bring-up)

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

### Step 6B) Deploy with Kueue (optional)

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

### Save logs to one folder on your VM (post-run)

Use the helper script to collect all pod logs for a JobSet into one run folder:

```bash
bash kubernetes/collect_jobset_logs.sh
```

Output structure:
- `./logs/<jobset>/run-<timestamp>/pods/<pod>.log` (current logs)
- `./logs/<jobset>/run-<timestamp>/pods/<pod>.previous.log` (previous container logs, if restart happened)
- `./logs/<jobset>/run-<timestamp>/all-pods.log` (merged view)

Run this after job completion and before deleting pods/JobSet.

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

## Small summary: Fields you typically update

In most runs, these are the only fields you tweak:

- **Image tag** in JobSet (`image:`) to match the image you just pushed
- **Node selector** for NVIDIA shape label if needed (for example `BM.GPU.B4.8` vs `BM.GPU4.8`)
- **Kueue label usage**
  - keep queue label when using Kueue
  - remove queue label for direct (non-Kueue) scheduling

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

## Benchmarking matrix

If you are doing repeated benchmarking runs, use this short path:

- Do **Step 1** (login + tag)
- Do **Step 2** (build + push)
- Do **Step 3** (secret setup)
- Do **Step 4** (update image in YAML)
- Do **Step 5** (update node selector in YAML)
- Then run:

**CUDA/NVIDIA**
```bash
bash kubernetes/run_benchmark_matrix.sh
```

**AMD**
```bash
TEMPLATE="kubernetes/torchtitan-health-check.jobset.yaml" \
bash kubernetes/run_benchmark_matrix.sh
```

`run_benchmark_matrix.sh` executes in this order for each benchmark case:

- It treats the JobSet YAML as the source of truth.
- For each run, it creates a temp manifest from that YAML.
- It only changes run-specific values (`metadata.name`, `JOBSET_NAME`, `LOCAL_BATCH_SIZE`, `SEQ_LEN`, `COMPILE`, `STEPS`).
- Then it applies that manifest, collects logs, and summarizes.

Adaptive search behavior:
- Loop order is: `compile -> steps -> seq_len -> batch_size`.
- For a given `(compile, steps)`:
  1. Start from `START_SEQ_LEN`, then try larger seq_len values (doubling) until first failure or `MAX_SEQ_LEN`.
  2. Take the max passing seq_len.
  3. At that seq_len, start from `START_BATCH_SIZE`, then try larger batch sizes (doubling) until first failure or `MAX_BATCH_SIZE`.
- Step stopping (plateau logic):
  - After finishing one `steps` value, compare best TFLOPs vs previous `steps` value.
  - If change is within `STEP_PLATEAU_PCT`, stop trying larger `steps` for that **same compile bucket**.
  - Then script continues to the next compile value (if present).

Summary logic:
- For each run, logs are collected first.
- Metrics are parsed from logs into:
  - `last_step`, `last_loss`, `last_tflops`, `last_mfu`
  - `max_tflops`, `max_mfu`
  - `tail_steps_count`, `tail_tflops_delta_pct`, `tail_stable`
- One row per run is appended to `summary.csv` (including failed/timeout runs).
- If aggregated log parsing is empty, script falls back to per-pod logs and picks
  the pod with the highest parsed step.
- `best_config.csv` is built from successful runs with valid metrics and ranked/sorted by:
  1. highest `max_tflops`
  2. highest `max_mfu`
  3. fewer `steps`
- Use `best_config.csv` to pick the winning config and inspect benchmark details
  (batch size, seq len, compile, steps, TFLOPs/MFU).

Tail stability fields (last few steps):
- `tail_steps_count`: how many final parsed steps were checked.
- `tail_tflops_delta_pct`: TFLOPs variation in the tail window, computed as
  `((max_tail_tflops - min_tail_tflops) / avg_tail_tflops) * 100`.
- `tail_stable`: `1` if tail variation is within threshold, else `0`.

Tail stability knobs:
- `TAIL_STEPS_WINDOW` (default `5`): number of final steps used for tail check.
- `TAIL_STABILITY_PCT` (default `1.0`): max allowed tail TFLOPs delta percent to
  mark run as stable.

Values can be updated either:
1. via CLI env vars for a run, or
2. by editing defaults in `kubernetes/run_benchmark_matrix.sh`

Example CLI override:

```bash
COMPILES="0" \
STEPS="25 50 100" \
START_SEQ_LEN="1024" MAX_SEQ_LEN="8192" \
START_BATCH_SIZE="1" MAX_BATCH_SIZE="16" \
STEP_PLATEAU_PCT="1.0" \
CLEANUP_AFTER_RUN="1" \
bash kubernetes/run_benchmark_matrix.sh
```
