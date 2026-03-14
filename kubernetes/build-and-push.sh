#!/usr/bin/env bash
set -x
# Build and push torchtitan images to OCI Container Registry.
#
# Usage:
#   ./kubernetes/build-and-push.sh [TARGET] [TAG]
#
# Targets:
#   rocm  -> kubernetes/Dockerfile.rocm, "aga.ocir.io/hpc/cpv/torchtitan_rocm"
#   cuda  -> kubernetes/Dockerfile.cuda, "aga.ocir.io/hpc/cpv/torchtitan_cuda"
#
# Backward-compatible usage:
#   ./kubernetes/build-and-push.sh               # rocm-latest
#   ./kubernetes/build-and-push.sh rocm-20260311  # rocm + custom tag
#
# Examples:
#   ./kubernetes/build-and-push.sh rocm rocm-latest
#   ./kubernetes/build-and-push.sh cuda a100-latest

set -euo pipefail

IMAGE_NAME="torchtitan"

TARGET="${1:-rocm}"
TAG=""
REGISTRY=""
DOCKERFILE=""

if [[ "${TARGET}" == "rocm" || "${TARGET}" == "cuda" ]]; then
  TAG="${2:-${TARGET}-latest}"
else
  # Backward compatibility: first arg is a tag for the ROCm image.
  TARGET="rocm"
  TAG="${1}"
fi

case "${TARGET}" in
  rocm)
    REGISTRY="aga.ocir.io/hpc/cpv/torchtitan_rocm"
    DOCKERFILE="kubernetes/Dockerfile.rocm"
    ;;
  cuda)
    REGISTRY="aga.ocir.io/hpc/cpv/torchtitan_cuda"
    DOCKERFILE="kubernetes/Dockerfile.cuda"
    ;;
  *)
    echo "Unsupported target: ${TARGET}. Use 'rocm' or 'cuda'." >&2
    exit 1
    ;;
esac

FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"

# Build from repo root so COPY . . captures the full torchtitan source tree.
REPO_ROOT="$(pwd)"

BUILD_ARGS=()
if [[ "${TARGET}" == "cuda" && -n "${NCCL_PKG_VERSION:-}" ]]; then
  BUILD_ARGS+=(--build-arg "NCCL_PKG_VERSION=${NCCL_PKG_VERSION}")
fi

echo "Building ${FULL_IMAGE} using ${DOCKERFILE} ..."
docker build \
  --file "${REPO_ROOT}/${DOCKERFILE}" \
  --tag "${FULL_IMAGE}" \
  "${BUILD_ARGS[@]}" \
  "${REPO_ROOT}"

echo "Pushing ${FULL_IMAGE} ..."
docker push "${FULL_IMAGE}"

echo "Done: ${FULL_IMAGE}"
