#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data/proj1}"
RUN_GLOB="${RUN_GLOB:-go2-rough-curriculum-*}"

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
  printf '%s\n' "error=no_rough_run_found" "glob=${RUN_GLOB}"
  printf '%s\n' "available_runs:"
  find "${DATA_ROOT}/runs" -maxdepth 1 -mindepth 1 -type d -printf '  %f\n' | sort || true
  exit 1
fi

CHECKPOINT_PATH="${CHECKPOINT_PATH:-$(find "${RUN_DIR}/logs" -type f -name 'model_*.pt' -size +0c \
  -printf '%f %p\n' | awk '{gsub(/^model_|\.pt$/,"",$1); print $1" "$2}' | sort -n | tail -1 | cut -d' ' -f2-)}"
if [ -z "${CHECKPOINT_PATH}" ] || [ ! -s "${CHECKPOINT_PATH}" ]; then
  printf '%s\n' "error=no_rough_checkpoint_found" "run_dir=${RUN_DIR}"
  find "${RUN_DIR}/logs" -type f -name '*.pt' -printf '  %p\n' | sort | tail -20 || true
  exit 1
fi

CHECKPOINT="$(basename "${CHECKPOINT_PATH}" | sed -E 's/^model_([0-9]+)\.pt$/\1/')"
RUN_NAME="$(basename "$(dirname "${CHECKPOINT_PATH}")")"
EVAL_ID="${EVAL_ID:-go2-rough-eval-$(date +%Y%m%d-%H%M%S)-$$}"
LOG="${DATA_ROOT}/results/${EVAL_ID}.log"

mkdir -p "${DATA_ROOT}/results" "${DATA_ROOT}/media"
exec > >(tee -a "${LOG}") 2>&1

printf '%s\n' \
  "rough_eval_package=rough_checkpoint_eval_v1" \
  "stage=resolve" \
  "run_dir=${RUN_DIR}" \
  "checkpoint_path=${CHECKPOINT_PATH}" \
  "checkpoint=${CHECKPOINT}" \
  "checkpoint_sha256=$(sha256sum "${CHECKPOINT_PATH}" | awk '{print $1}')" \
  "run_name=${RUN_NAME}" \
  "eval_id=${EVAL_ID}" \
  "note=no_config_patch_for_rough" \
  "log=${LOG}"

export DATA_ROOT RUN_DIR RUN_NAME TASK="${TASK:-go2_ts}"
export CHECKPOINT CHECKPOINT_PATH EVAL_ID
export EPISODES="${EPISODES:-20}" NUM_ENVS="${NUM_ENVS:-20}"
export FRAMES="${FRAMES:-1000}" STATE_INTERVAL="${STATE_INTERVAL:-30}"
export COMMAND_X="${COMMAND_X:-0.3}" CONSOLIDATED_LOG=1
export TERRAIN_LEVEL="${TERRAIN_LEVEL:-auto}" TERRAIN_TYPES="${TERRAIN_TYPES:-spread}"

printf '%s\n' "stage=config_state" "note=rough_uses_repo_config_as_is" \
  "terrain_level=${TERRAIN_LEVEL}" "terrain_types=${TERRAIN_TYPES}"
grep -nE "randomize_friction|randomize_base_mass|push_robots|randomize_com_displacement|heading_command" \
  "${REPO_DIR:-${DATA_ROOT}/vendor/LeggedGym-Ex}/legged_gym/envs/go2/go2_config.py" 2>/dev/null || true

printf '%s\n' "stage=eval_and_record" "task=${TASK}" "command_x=${COMMAND_X}" "episodes=${EPISODES}"
bash "${SCRIPT_DIR}/eval_and_record_job.sh"

SUMMARY="${DATA_ROOT}/results/${EVAL_ID}.summary.txt"
if [ -f "${SUMMARY}" ]; then
  printf '%s\n' "stage=summary"
  cat "${SUMMARY}"
fi
printf '%s\n' "stage=complete"
