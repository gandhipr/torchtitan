#!/usr/bin/env bash
set -euo pipefail

# Run a parameter sweep for TorchTitan JobSet and collect logs per run.
#
# Usage:
#   bash kubernetes/run_benchmark_matrix.sh [namespace] [base_dir]
#
# Optional env vars to control sweep:
#   START_SEQ_LEN="1024"
#   MAX_SEQ_LEN="8192"
#   START_BATCH_SIZE="1"
#   MAX_BATCH_SIZE="32"
#   COMPILES="0 1"
#   STEPS="25 50 100 250 500"
#   NODE_SELECTOR="BM.GPU.B4.8"
#   IMAGE="aga.ocir.io/...:tag"
#   TIMEOUT="90m"
#   CLEANUP_AFTER_RUN="1"
#   STEP_PLATEAU_PCT="1.0"
#   TAIL_STEPS_WINDOW="5"
#   TAIL_STABILITY_PCT="1.0"
#     (tail_stable=1 when tail_tflops_delta_pct <= threshold,
#      where tail_tflops_delta_pct = (max(tail)-min(tail))/avg(tail)*100)
#   TEMPLATE="kubernetes/torchtitan-health-check-cuda.jobset.yaml"

NAMESPACE="${1:-default}"
BASE_DIR="${2:-./logs}"
TEMPLATE="${TEMPLATE:-kubernetes/torchtitan-health-check-cuda.jobset.yaml}"

COMPILES="${COMPILES:-0 1}"
STEPS="${STEPS:-25 50 100 250 500}"
TIMEOUT="${TIMEOUT:-90m}"
START_SEQ_LEN="${START_SEQ_LEN:-1024}"
MAX_SEQ_LEN="${MAX_SEQ_LEN:-8192}"
START_BATCH_SIZE="${START_BATCH_SIZE:-1}"
MAX_BATCH_SIZE="${MAX_BATCH_SIZE:-32}"
CLEANUP_AFTER_RUN="${CLEANUP_AFTER_RUN:-1}"
STEP_PLATEAU_PCT="${STEP_PLATEAU_PCT:-1.0}"
TAIL_STEPS_WINDOW="${TAIL_STEPS_WINDOW:-5}"
TAIL_STABILITY_PCT="${TAIL_STABILITY_PCT:-1.0}"

NODE_SELECTOR="${NODE_SELECTOR:-}"
IMAGE="${IMAGE:-}"

timestamp="$(date +%Y%m%d-%H%M%S)"
suite_dir="${BASE_DIR}/benchmark-suite-${timestamp}"
tmp_dir="${suite_dir}/manifests"
mkdir -p "${tmp_dir}"

summary_csv="${suite_dir}/summary.csv"
echo "run_id,jobset,batch_size,seq_len,compile,steps,status,last_step,last_loss,last_tflops,last_mfu,max_tflops,max_mfu,tail_steps_count,tail_tflops_delta_pct,tail_stable,log_dir" > "${summary_csv}"

replace_env_value() {
  local infile="$1"
  local outfile="$2"
  local key="$3"
  local value="$4"
  awk -v key="$key" -v value="$value" '
    $0 ~ "name:[[:space:]]*" key "$" {
      print
      if (getline > 0) {
        sub(/value:[[:space:]]*"[^"]*"/, "value: \"" value "\"")
        print
        next
      }
    }
    { print }
  ' "$infile" > "$outfile"
}

wait_for_jobset_pods_terminal() {
  local jobset="$1"
  local namespace="$2"
  local timeout_secs
  timeout_secs=$(python3 - <<'PY'
import os
t=os.environ.get('TIMEOUT','90m')
if t.endswith('m'):
    print(int(t[:-1])*60)
elif t.endswith('h'):
    print(int(t[:-1])*3600)
else:
    print(int(t.rstrip('s')))
PY
)

  local start now elapsed
  start=$(date +%s)
  while true; do
    now=$(date +%s)
    elapsed=$((now-start))
    if (( elapsed > timeout_secs )); then
      echo "timeout"
      return 1
    fi

    phases=$(kubectl get pods -n "$namespace" -l "jobset.sigs.k8s.io/jobset-name=$jobset" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || true)
    if [[ -z "$phases" ]]; then
      sleep 10
      continue
    fi

    non_terminal=$(echo "$phases" | grep -Ev '^(Succeeded|Failed)$' || true)
    if [[ -z "$non_terminal" ]]; then
      if echo "$phases" | grep -q '^Failed$'; then
        echo "failed"
      else
        echo "succeeded"
      fi
      return 0
    fi
    sleep 15
  done
}

extract_metrics_from_log() {
  local log_file="$1"
  python3 - "$log_file" "$TAIL_STEPS_WINDOW" "$TAIL_STABILITY_PCT" <<'PY'
import re, sys
path = sys.argv[1]
tail_window = int(sys.argv[2])
stable_pct_threshold = float(sys.argv[3])
last_step = ""
last_loss = ""
last_tflops = ""
last_mfu = ""
max_tflops = None
max_mfu = None
series = []

# TorchTitan log lines can include ANSI color codes and comma-separated numbers.
# Strip ANSI escapes, then parse fields independently so formatting changes are
# less likely to break summary extraction.
ansi_re = re.compile(r"\x1b\[[0-9;]*m")
step_re = re.compile(r"\bstep:\s*(\d+)\b")
loss_re = re.compile(r"\bloss:\s*([0-9]*\.?[0-9]+)\b")
tflops_re = re.compile(r"\btflops:\s*([0-9][0-9,]*\.?[0-9]*)\b")
mfu_re = re.compile(r"\bmfu:\s*([0-9]*\.?[0-9]+)%")

def to_float(num: str) -> float:
    return float(num.replace(",", ""))

try:
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = ansi_re.sub("", line)
            ms = step_re.search(line)
            ml = loss_re.search(line)
            mt = tflops_re.search(line)
            if not (ms and ml and mt):
                continue
            step = int(ms.group(1))
            loss = ml.group(1)
            tflops = to_float(mt.group(1))
            mm = mfu_re.search(line)
            mfu = float(mm.group(1)) if mm else None

            last_step = str(step)
            last_loss = loss
            last_tflops = f"{tflops}"
            last_mfu = "" if mfu is None else f"{mfu}"

            if max_tflops is None or tflops > max_tflops:
                max_tflops = tflops
            if mfu is not None and (max_mfu is None or mfu > max_mfu):
                max_mfu = mfu

            series.append((step, tflops, mfu))

except FileNotFoundError:
    pass

max_tflops_s = "" if max_tflops is None else f"{max_tflops:.4f}".rstrip('0').rstrip('.')
max_mfu_s = "" if max_mfu is None else f"{max_mfu:.4f}".rstrip('0').rstrip('.')

tail_steps_count = ""
tail_tflops_delta_pct = ""
tail_stable = ""
if len(series) >= 2:
    tail = series[-tail_window:] if tail_window > 0 else series
    tvals = [x[1] for x in tail]
    if len(tvals) >= 2:
        avg = sum(tvals) / len(tvals)
        if avg > 0:
            # Percent spread across the tail window (not just last-vs-first):
            #   (max(tail) - min(tail)) / avg(tail) * 100
            delta_pct = ((max(tvals) - min(tvals)) * 100.0) / avg
            tail_steps_count = str(len(tvals))
            tail_tflops_delta_pct = f"{delta_pct:.4f}".rstrip('0').rstrip('.')
            tail_stable = "1" if delta_pct <= stable_pct_threshold else "0"

print(f"{last_step},{last_loss},{last_tflops},{last_mfu},{max_tflops_s},{max_mfu_s},{tail_steps_count},{tail_tflops_delta_pct},{tail_stable}")
PY
}

has_extracted_metrics() {
  local metrics_csv="$1"
  local first
  first="${metrics_csv%%,*}"
  [[ -n "$first" ]]
}

best_tflops_for_compile_step() {
  local cp="$1"
  local st="$2"
  python3 - "$summary_csv" "$cp" "$st" <<'PY'
import csv, sys
path, cp, st = sys.argv[1], sys.argv[2], sys.argv[3]
best = None
with open(path, newline='', encoding='utf-8') as f:
    for r in csv.DictReader(f):
        if r.get("compile") != cp or r.get("steps") != st:
            continue
        if r.get("status") != "succeeded":
            continue
        try:
            v = float(r.get("max_tflops", ""))
        except Exception:
            continue
        if best is None or v > best:
            best = v
print("" if best is None else best)
PY
}

run_one_config() {
  local bs="$1"
  local sl="$2"
  local cp="$3"
  local st="$4"

  local run_id="bs${bs}-sl${sl}-cp${cp}-st${st}-$(date +%H%M%S)-$RANDOM"
  local jobset_name="tt-bench-${run_id}"
  local manifest="${tmp_dir}/${run_id}.yaml"
  local work="${tmp_dir}/${run_id}.tmp.yaml"

  cp "$TEMPLATE" "$work"

  # metadata.name and JOBSET_NAME
  # Update the first "name:" after "metadata:" so template base name is not hardcoded.
  awk -v new_name="$jobset_name" '
    BEGIN { in_meta = 0; done = 0 }
    /^metadata:[[:space:]]*$/ { in_meta = 1; print; next }
    in_meta && !done && /^[[:space:]]*name:[[:space:]]*/ {
      sub(/name:[[:space:]]*.*/, "name: " new_name)
      done = 1
      in_meta = 0
      print
      next
    }
    { print }
  ' "$work" > "${work}.meta" && mv "${work}.meta" "$work"
  replace_env_value "$work" "${work}.1" "JOBSET_NAME" "$jobset_name"
  replace_env_value "${work}.1" "${work}.2" "LOCAL_BATCH_SIZE" "$bs"
  replace_env_value "${work}.2" "${work}.3" "SEQ_LEN" "$sl"
  replace_env_value "${work}.3" "${work}.4" "COMPILE" "$cp"
  replace_env_value "${work}.4" "${manifest}" "STEPS" "$st"
  rm -f "$work" "${work}.1" "${work}.2" "${work}.3" "${work}.4"

  if [[ -n "$NODE_SELECTOR" ]]; then
    sed -E -i.bak "s/(node.kubernetes.io\/instance-type:[[:space:]]*).*/\1${NODE_SELECTOR}/" "$manifest"
    rm -f "${manifest}.bak"
  fi
  if [[ -n "$IMAGE" ]]; then
    sed -E -i.bak "s|([[:space:]]*image:[[:space:]]*).*|\1${IMAGE}|" "$manifest"
    rm -f "${manifest}.bak"
  fi

  echo "[run] ${run_id} -> ${jobset_name} (steps=${st} bs=${bs} sl=${sl} cp=${cp})" >&2
  kubectl delete jobset "$jobset_name" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply -n "$NAMESPACE" -f "$manifest" >&2

  local status
  status=$(wait_for_jobset_pods_terminal "$jobset_name" "$NAMESPACE" || echo timeout)

  local run_log_dir="${suite_dir}/${run_id}"
  bash kubernetes/collect_jobset_logs.sh "$jobset_name" "$NAMESPACE" "$run_log_dir" >&2 || true

  if [[ "$CLEANUP_AFTER_RUN" == "1" ]]; then
    echo "  cleanup: deleting jobset ${jobset_name}" >&2
    kubectl delete jobset "$jobset_name" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  fi

  local all_pods_log metrics_csv
  all_pods_log=$(ls -1t "${run_log_dir}/${jobset_name}"/run-*/all-pods.log 2>/dev/null | head -n 1 || true)
  metrics_csv=""
  if [[ -n "${all_pods_log}" ]]; then
    metrics_csv=$(extract_metrics_from_log "${all_pods_log}" 2>/dev/null | tail -n 1 || true)
  fi

  # Fallback: if aggregated all-pods log is empty/non-metric, parse per-pod logs.
  # Pick the pod with the highest parsed last_step as representative.
  if ! has_extracted_metrics "${metrics_csv}"; then
    local best_metrics=""
    local best_step=-1
    while IFS= read -r pod_log; do
      [[ -z "$pod_log" ]] && continue
      local one_metrics one_step
      one_metrics=$(extract_metrics_from_log "$pod_log" 2>/dev/null | tail -n 1 || true)
      one_step="${one_metrics%%,*}"
      if [[ "$one_step" =~ ^[0-9]+$ ]]; then
        if (( one_step > best_step )); then
          best_step=$one_step
          best_metrics="$one_metrics"
        fi
      fi
    done < <(ls -1t "${run_log_dir}/${jobset_name}"/run-*/pods/*.log 2>/dev/null | grep -v '\.previous\.log$' || true)

    if [[ -n "$best_metrics" ]]; then
      metrics_csv="$best_metrics"
    fi
  fi

  if [[ -z "${metrics_csv}" ]]; then
    metrics_csv=",,,,,,,,"
  fi

  IFS=',' read -r m_last_step m_last_loss m_last_tflops m_last_mfu m_max_tflops m_max_mfu m_tail_steps_count m_tail_tflops_delta_pct m_tail_stable <<< "$metrics_csv"
  echo "  recap: status=${status} last_step=${m_last_step:-NA} max_tflops=${m_max_tflops:-NA} max_mfu=${m_max_mfu:-NA} tail_stable=${m_tail_stable:-NA} tail_delta_pct=${m_tail_tflops_delta_pct:-NA}" >&2

  echo "${run_id},${jobset_name},${bs},${sl},${cp},${st},${status},${metrics_csv},${run_log_dir}" >> "$summary_csv"
  echo "$status"
}

for cp in $COMPILES; do
  echo "[adaptive] ===== compile bucket start: cp=${cp} ====="
  prev_step_best_tflops=""
  for st in $STEPS; do
    base_bs="$START_BATCH_SIZE"
    max_seq_pass=""
    current_sl="$START_SEQ_LEN"

    echo "[adaptive] compile=${cp} steps=${st}: sweep seq_len ${START_SEQ_LEN}..${MAX_SEQ_LEN} (x2) with bs=${base_bs}"
    while (( current_sl <= MAX_SEQ_LEN )); do
      status=$(run_one_config "$base_bs" "$current_sl" "$cp" "$st")
      if [[ "$status" == "succeeded" ]]; then
        max_seq_pass="$current_sl"
        current_sl=$(( current_sl * 2 ))
      else
        echo "[adaptive] stop seq_len sweep at sl=${current_sl} (status=${status})"
        break
      fi
    done

    if [[ -z "$max_seq_pass" ]]; then
      echo "[adaptive] no passing seq_len for compile=${cp} steps=${st}; skip batch sweep"
      continue
    fi

    echo "[adaptive] max passing seq_len=${max_seq_pass}; now sweep batch_size ${START_BATCH_SIZE}..${MAX_BATCH_SIZE} (x2)"
    current_bs=$(( START_BATCH_SIZE * 2 ))
    while (( current_bs <= MAX_BATCH_SIZE )); do
      status=$(run_one_config "$current_bs" "$max_seq_pass" "$cp" "$st")
      if [[ "$status" != "succeeded" ]]; then
        echo "[adaptive] stop batch_size sweep at bs=${current_bs} (status=${status})"
        break
      fi
      current_bs=$(( current_bs * 2 ))
    done

    curr_step_best_tflops=$(best_tflops_for_compile_step "$cp" "$st")
    if [[ -n "$prev_step_best_tflops" && -n "$curr_step_best_tflops" ]]; then
      plateau=$(python3 - "$prev_step_best_tflops" "$curr_step_best_tflops" "$STEP_PLATEAU_PCT" <<'PY'
import sys
prev_v = float(sys.argv[1])
curr_v = float(sys.argv[2])
th = float(sys.argv[3])
if prev_v <= 0:
    print("0")
else:
    pct = abs(curr_v - prev_v) * 100.0 / prev_v
    print("1" if pct <= th else "0")
PY
)
      if [[ "$plateau" == "1" ]]; then
        echo "[adaptive] cp=${cp}: stop steps at st=${st} due to plateau vs previous step (threshold <= ${STEP_PLATEAU_PCT}% ; prev_best_tflops=${prev_step_best_tflops} curr_best_tflops=${curr_step_best_tflops})"
        break
      fi
    fi

    if [[ -n "$curr_step_best_tflops" ]]; then
      prev_step_best_tflops="$curr_step_best_tflops"
    fi
  done
done

echo "[done] Benchmark suite complete: ${suite_dir}"
echo "[done] Summary: ${summary_csv}"

best_csv="${suite_dir}/best_config.csv"
python3 - "$summary_csv" "$best_csv" <<'PY'
import csv, sys
summary, out = sys.argv[1], sys.argv[2]

def to_float(x):
    try:
        return float(x)
    except Exception:
        return None

def to_int(x):
    try:
        return int(float(x))
    except Exception:
        return None

rows = []
with open(summary, newline='', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("status") != "succeeded":
            continue
        max_mfu = to_float(r.get("max_mfu", ""))
        max_tflops = to_float(r.get("max_tflops", ""))
        steps = to_int(r.get("steps", ""))
        if max_mfu is None or max_tflops is None or steps is None:
            continue
        rows.append((max_tflops, max_mfu, steps, r))

# Rank by: highest max TFLOPs, then highest max MFU, then fewer steps.
rows.sort(key=lambda x: (-x[0], -x[1], x[2]))

fields = [
    "rank", "run_id", "jobset", "batch_size", "seq_len", "compile", "steps",
    "max_tflops", "max_mfu", "log_dir"
]

with open(out, "w", newline='', encoding='utf-8') as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    for i, (_, _, _, r) in enumerate(rows, start=1):
        w.writerow({
            "rank": i,
            "run_id": r.get("run_id", ""),
            "jobset": r.get("jobset", ""),
            "batch_size": r.get("batch_size", ""),
            "seq_len": r.get("seq_len", ""),
            "compile": r.get("compile", ""),
            "steps": r.get("steps", ""),
            "max_tflops": r.get("max_tflops", ""),
            "max_mfu": r.get("max_mfu", ""),
            "log_dir": r.get("log_dir", ""),
        })
PY

echo "[done] Best-ranked configs: ${best_csv}"
echo "[done] Top 5 by max TFLOPs/MFU:"
python3 - "$best_csv" <<'PY'
import csv, sys
path = sys.argv[1]
with open(path, newline='', encoding='utf-8') as f:
    rows = list(csv.DictReader(f))
if not rows:
    print("  (no successful ranked runs)")
else:
    for r in rows[:5]:
        print(
            f"  #{r['rank']} run={r['run_id']} "
            f"bs={r.get('batch_size','')} sl={r.get('seq_len','')} cp={r.get('compile','')} steps={r.get('steps','')} "
            f"max_tflops={r.get('max_tflops','')} max_mfu={r.get('max_mfu','')}"
        )
PY