#!/usr/bin/env bash
set -euo pipefail

# Collect logs from all pods in a JobSet and store them on the local VM.
#
# Usage:
#   ./kubernetes/collect_jobset_logs.sh [jobset_name] [namespace] [base_dir]
#
# Defaults:
#   jobset_name = torchtitan-health-check-cuda
#   namespace   = default
#   base_dir    = /home/ubuntu/logs

JOBSET_NAME="${1:-torchtitan-health-check-cuda}"
NAMESPACE="${2:-default}"
BASE_DIR="${3:-/home/ubuntu/logs}"

timestamp="$(date +%Y%m%d-%H%M%S)"
run_dir="${BASE_DIR}/${JOBSET_NAME}/run-${timestamp}"
pods_dir="${run_dir}/pods"

mkdir -p "${pods_dir}"

label="jobset.sigs.k8s.io/jobset-name=${JOBSET_NAME}"

echo "[info] Collecting logs for JobSet='${JOBSET_NAME}' Namespace='${NAMESPACE}'"
echo "[info] Output directory: ${run_dir}"

# Snapshot useful metadata for this run folder.
kubectl get jobset "${JOBSET_NAME}" -n "${NAMESPACE}" -o yaml > "${run_dir}/jobset.yaml" 2>/dev/null || true
kubectl get pods -n "${NAMESPACE}" -l "${label}" -o wide > "${run_dir}/pods.txt" 2>/dev/null || true

pods="$(kubectl get pods -n "${NAMESPACE}" -l "${label}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"

if [[ -z "${pods}" ]]; then
  echo "[warn] No pods found for label '${label}'."
  echo "[warn] If pods were deleted already, Kubernetes logs may no longer be available."
  exit 0
fi

for pod in ${pods}; do
  echo "[info] Saving logs for pod ${pod}"
  # Current container logs
  kubectl logs -n "${NAMESPACE}" "${pod}" --all-containers=true > "${pods_dir}/${pod}.log" 2>&1 || true
  # Previous container logs (if restarted)
  kubectl logs -n "${NAMESPACE}" "${pod}" --all-containers=true --previous > "${pods_dir}/${pod}.previous.log" 2>&1 || true
done

# Combined view across pods (helps when you don't want to switch files).
kubectl logs -n "${NAMESPACE}" -l "${label}" --all-containers=true --prefix=true > "${run_dir}/all-pods.log" 2>&1 || true

echo "[done] Logs collected under: ${run_dir}"
