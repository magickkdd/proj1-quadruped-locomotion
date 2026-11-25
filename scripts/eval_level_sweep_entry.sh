#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data/proj1}"
RUN_GLOB="${RUN_GLOB:-go2-rough-curriculum-*}"
EVAL_ID="${EVAL_ID:-go2-levelsweep-$(date +%Y%m%d-%H%M%S)-$$}"
LOG="${DATA_ROOT}/results/${EVAL_ID}.log"

mkdir -p "${DATA_ROOT}/results" "${DATA_ROOT}/media"
exec > >(tee -a "${LOG}") 2>&1
printf '%s\n' "entry_package=level_sweep_entry_v1" "eval_id=${EVAL_ID}" "log=${LOG}"

RUN_DIR="${RUN_DIR:-}"
if [ -z "${RUN_DIR}" ]; then
  for candidate in $(find "${DATA_ROOT}/runs" -maxdepth 1 -type d -name "${RUN_GLOB}" \
    ! -name '*-config-backup' | sort -r); do
    if [ -d "${candidate}/logs" ]; then
      RUN_DIR="${candidate}"
      break
    fi
  done
fi
if [ -z "${RUN_DIR}" ] || [ ! -d "${RUN_DIR}/logs" ]; then
  printf '%s\n' "error=no_run_found" "glob=${RUN_GLOB}"
  find "${DATA_ROOT}/runs" -maxdepth 1 -mindepth 1 -type d -printf '  %f\n' | sort || true
  exit 1
fi
printf '%s\n' "run_dir=${RUN_DIR}"

if [ -n "${CHECKPOINT_PATH:-}" ]; then
  :
elif [ -n "${CHECKPOINT:-}" ]; then
  CHECKPOINT_PATH="$(find "${RUN_DIR}/logs" -type f -name "model_${CHECKPOINT}.pt" -print | sort | tail -1)"
else
  CHECKPOINT_PATH="$(find "${RUN_DIR}/logs" -type f -name 'model_*.pt' -size +0c \
    -printf '%f %p\n' | awk '{gsub(/^model_|\.pt$/,"",$1); print $1" "$2}' | sort -n | tail -1 | cut -d' ' -f2-)"
fi
if [ -z "${CHECKPOINT_PATH}" ] || [ ! -s "${CHECKPOINT_PATH}" ]; then
  printf '%s\n' "error=no_checkpoint_found" "run_dir=${RUN_DIR}"
  find "${RUN_DIR}/logs" -type f -name 'model_*.pt' -printf '  %p\n' | sort | tail -10 || true
  exit 1
fi
printf '%s\n' "checkpoint_path=${CHECKPOINT_PATH}" \
  "checkpoint_sha256=$(sha256sum "${CHECKPOINT_PATH}" | awk '{print $1}')"

export DATA_ROOT RUN_DIR EVAL_ID CHECKPOINT_PATH
export TASK="${TASK:-go2_ts}"
export COMMAND_X="${COMMAND_X:-0.4}"
export MAX_STEPS="${MAX_STEPS:-12000}"
export FRAME_STRIDE="${FRAME_STRIDE:-5}"
export FPS="${FPS:-20}"
export TYPES="${TYPES:-0,1,2,3,4,5,6,7,8,9}"
export TERRAIN_LEVEL="${TERRAIN_LEVEL:-0}"

printf '%s\n' "stage=level_sweep" "task=${TASK}" "command_x=${COMMAND_X}" \
  "max_steps=${MAX_STEPS}" "types=${TYPES}" "terrain_level=${TERRAIN_LEVEL}"
bash "${SCRIPT_DIR}/eval_level_sweep_job.sh"

CSV="${DATA_ROOT}/media/${EVAL_ID}/level_sweep.csv"
if [ -f "${CSV}" ]; then
  printf '%s\n' "stage=results"
  cat "${CSV}"
fi
printf '%s\n' "stage=complete" "out_dir=${DATA_ROOT}/media/${EVAL_ID}"
