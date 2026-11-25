#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data/proj1}"
RUN_DIR="${RUN_DIR:-$(find "${DATA_ROOT}/runs" -maxdepth 1 -type d -name 'go2-flat-clean-*' | sort | tail -1)}"
CHECKPOINT_PATH="${CHECKPOINT_PATH:-$(find "${RUN_DIR}/logs" -type f -name 'model_*.pt' -size +0c -printf '%f %p\n' | awk '{gsub(/^model_|\.pt$/,"",$1); print $1" "$2}' | sort -n | tail -1 | cut -d' ' -f2-)}"
CHECKPOINT="$(basename "${CHECKPOINT_PATH}" | sed -E 's/^model_([0-9]+)\.pt$/\1/')"
RUN_NAME="$(basename "$(dirname "${CHECKPOINT_PATH}")")"
EVAL_ID="${EVAL_ID:-go2-flat-repaired-$(date +%Y%m%d-%H%M%S)-$$}"

[ -d "${RUN_DIR}/logs" ] || { printf '%s\n' "missing_run_dir=${RUN_DIR}" >&2; exit 1; }
[ -s "${CHECKPOINT_PATH}" ] || { printf '%s\n' "missing_checkpoint=${CHECKPOINT_PATH}" >&2; exit 1; }

export DATA_ROOT RUN_DIR CHECKPOINT_PATH CHECKPOINT RUN_NAME EVAL_ID
export TASK="${TASK:-go2}"
export EPISODES="${EPISODES:-20}"
export NUM_ENVS="${NUM_ENVS:-20}"
export FRAMES="${FRAMES:-900}"
export STATE_INTERVAL="${STATE_INTERVAL:-30}"
export COMMAND_X="${COMMAND_X:-0.3}"
export CONSOLIDATED_LOG=1

printf '%s\n' \
  "eval_repair_package=command_observation_refresh_v1" \
  "run_dir=${RUN_DIR}" \
  "checkpoint_path=${CHECKPOINT_PATH}" \
  "checkpoint=${CHECKPOINT}" \
  "run_name=${RUN_NAME}" \
  "command_x=${COMMAND_X}" \
  "stage=eval_and_record"
bash "${SCRIPT_DIR}/eval_and_record_job.sh"
