# TorchTitan Kubernetes folder (status)

This folder now contains only **image build assets** for TorchTitan:

- `kubernetes/build-and-push.sh`
- `kubernetes/Dockerfile.cuda`
- `kubernetes/Dockerfile.rocm`

The runtime Kubernetes manifests and benchmark/collection scripts were moved to
the `oci-dr-hpc-v2` repository.

## Where runtime K8s artifacts live now

Use these paths in `oci-dr-hpc-v2` for TorchTitan k8s jobs:

- `internal/active_tests/ml_training_job/torchtitan/k8s/yamls/cuda/`
- `internal/active_tests/ml_training_job/torchtitan/k8s/yamls/rocm/`
- `internal/active_tests/ml_training_job/torchtitan/k8s/scripts/`
- shape-specific config: `embedded/test_limits/<shape>.json`

## What to do from this repo

Build/push a CUDA image:

```bash
docker login aga.ocir.io -u '<namespace>/<username>'
TAG="cuda-dev-$(date +%m%d-%H%M)"
./kubernetes/build-and-push.sh cuda "$TAG"
```

Build/push a ROCm image:

```bash
docker login aga.ocir.io -u '<namespace>/<username>'
TAG="rocm-dev-$(date +%m%d-%H%M)"
./kubernetes/build-and-push.sh rocm "$TAG"
```

Then set that image tag in `oci-dr-hpc-v2` shape test-limits config and run
the k8s flow from there.
