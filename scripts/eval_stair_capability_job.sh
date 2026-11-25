#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data/proj1}"
RUN_GLOB="${RUN_GLOB:-go2-rough-curriculum-*}"
EVAL_ID="${EVAL_ID:-go2-matrix-$(date +%Y%m%d-%H%M%S)-$$}"
LOG="${DATA_ROOT}/results/${EVAL_ID}.log"

mkdir -p "${DATA_ROOT}/results" "${DATA_ROOT}/media"
exec > >(tee -a "${LOG}") 2>&1
printf '%s\n' "eval_package=matrix_eval_v7" "eval_id=${EVAL_ID}" "log=${LOG}"

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
  find "${DATA_ROOT}/runs" -maxdepth 1 -mindepth 1 -type d -printf '  %f\n' | sort || true
  exit 1
fi

CHECKPOINT_PATH="${CHECKPOINT_PATH:-$(find "${RUN_DIR}/logs" -type f -name 'model_*.pt' -size +0c \
  -printf '%f %p\n' | awk '{gsub(/^model_|\.pt$/,"",$1); print $1" "$2}' | sort -n | tail -1 | cut -d' ' -f2-)}"
if [ -z "${CHECKPOINT_PATH}" ] || [ ! -s "${CHECKPOINT_PATH}" ]; then
  printf '%s\n' "error=no_rough_checkpoint_found" "run_dir=${RUN_DIR}"
  exit 1
fi

CHECKPOINT="$(basename "${CHECKPOINT_PATH}" | sed -E 's/^model_([0-9]+)\.pt$/\1/')"
RUN_NAME="$(basename "$(dirname "${CHECKPOINT_PATH}")")"

# Stairs column is the last terrain type of this curriculum.
export TERRAIN_TYPES="${TERRAIN_TYPES:-9}"
export TERRAIN_LEVEL="${TERRAIN_LEVEL:-matrix}"
export TERRAIN_MATRIX_LEVELS="${TERRAIN_MATRIX_LEVELS:-4,7,9}"
export TERRAIN_CAMERA_TYPE="${TERRAIN_CAMERA_TYPE:-7}"
export TERRAIN_CAMERA_LEVEL="${TERRAIN_CAMERA_LEVEL:-7}"

printf '%s\n' \
  "stair_eval_package=stair_capability_v1" \
  "stage=resolve" \
  "run_dir=${RUN_DIR}" \
  "checkpoint_path=${CHECKPOINT_PATH}" \
  "checkpoint=${CHECKPOINT}" \
  "checkpoint_sha256=$(sha256sum "${CHECKPOINT_PATH}" | awk '{print $1}')" \
  "run_name=${RUN_NAME}" \
  "eval_id=${EVAL_ID}" \
  "terrain_types=${TERRAIN_TYPES}" \
  "terrain_levels=${TERRAIN_LEVEL}" \
  "camera_terrain_level=${TERRAIN_CAMERA_LEVEL}" \
  "log=${LOG}"

export DATA_ROOT RUN_DIR RUN_NAME TASK="${TASK:-go2_ts}"
export CHECKPOINT CHECKPOINT_PATH EVAL_ID
export EPISODES="${EPISODES:-60}" NUM_ENVS="${NUM_ENVS:-30}"
export FRAMES="${FRAMES:-2000}" STATE_INTERVAL="${STATE_INTERVAL:-30}"
export COMMAND_X="${COMMAND_X:-0.4}" CONSOLIDATED_LOG=1

printf '%s\n' "stage=stair_eval" "task=${TASK}" "command_x=${COMMAND_X}" "episodes=${EPISODES}" "num_envs=${NUM_ENVS}"
bash "${SCRIPT_DIR}/eval_and_record_job.sh"

SUMMARY="${DATA_ROOT}/results/${EVAL_ID}.summary.txt"
if [ -f "${SUMMARY}" ]; then
  printf '%s\n' "stage=summary"
  cat "${SUMMARY}"
fi
printf '%s\n' "stage=complete"
