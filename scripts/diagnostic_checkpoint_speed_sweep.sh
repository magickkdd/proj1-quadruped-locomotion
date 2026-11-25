#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data/proj1}"
SWEEP_LOG="${DATA_ROOT}/results/diagnostic_checkpoint_speed_sweep.log"
mkdir -p "${DATA_ROOT}/results"
exec > >(tee "${SWEEP_LOG}") 2>&1
printf '%s\n' "sweep_package=diagnostic_checkpoint_speed_sweep_v2" "sweep_start=$(date -Is 2>/dev/null || date)" "sweep_log=${SWEEP_LOG}"
export CONSOLIDATED_LOG=1
export RUN_GLOB="go2-flat-baseline-*"
export TASK="go2"
export EPISODES="10"
export NUM_ENVS="10"
export FRAMES="300"

for checkpoint in 400 1000 1500; do
  for speed in 0.0 0.3; do
    export CHECKPOINT="${checkpoint}"
    export COMMAND_X="${speed}"
    export EVAL_ID="go2-flat-ckpt-${checkpoint}-speed-${speed}"
    bash "${SCRIPT_DIR}/eval_and_record_job.sh"
  done
done
printf '%s\n' "sweep_end=$(date -Is 2>/dev/null || date)" "sweep_status=success"
