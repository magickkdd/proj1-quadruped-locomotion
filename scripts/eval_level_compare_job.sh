#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data/proj1}"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
LOG="${DATA_ROOT}/results/go2-level-ab-${STAMP}.log"
LEVELS="${LEVELS:-9 0}"
TYPES="${TYPES:-6,7}"
CKPT="${CKPT:-6000}"

mkdir -p "${DATA_ROOT}/results" "${DATA_ROOT}/media"
exec > >(tee -a "${LOG}") 2>&1

printf '%s\n' "ab_package=level_ab_v1" "started_at=$(date -Is)" \
  "levels=${LEVELS}" "types=${TYPES}" "ckpt=${CKPT}" "log=${LOG}"

RUN_DIR="${RUN_DIR:-}"
if [ -z "${RUN_DIR}" ]; then
  for candidate in $(find "${DATA_ROOT}/runs" -maxdepth 1 -type d \
    \( -name 'go2-staged-*' -o -name 'go2-rough-curriculum-*' \) \
    ! -name '*-config-backup' | sort -r); do
    if find "${candidate}/logs" -name "model_${CKPT}.pt" -print -quit 2>/dev/null | grep -q .; then
      RUN_DIR="${candidate}"
      break
    fi
  done
fi
[ -n "${RUN_DIR}" ] && [ -d "${RUN_DIR}/logs" ] || {
  printf '%s\n' "error=no_run_dir"; exit 1; }

CHECKPOINT_PATH="$(find "${RUN_DIR}/logs" -name "model_${CKPT}.pt" -print | sort | tail -1)"
if [ -z "${CHECKPOINT_PATH}" ]; then
  CHECKPOINT_PATH="$(find "${RUN_DIR}/logs" -name 'model_*.pt' -size +0c \
    -printf '%f %p\n' | sort -n | tail -1 | cut -d' ' -f2-)"
fi
[ -s "${CHECKPOINT_PATH}" ] || { printf '%s\n' "error=no_checkpoint"; exit 1; }

printf '%s\n' "run_dir=${RUN_DIR}" "checkpoint_path=${CHECKPOINT_PATH}" \
  "checkpoint_sha256=$(sha256sum "${CHECKPOINT_PATH}" | awk '{print $1}')"

MASTER_LOG="${DATA_ROOT}/results/$(basename "${RUN_DIR}").log"
if [ -f "${MASTER_LOG}" ]; then
  printf '%s\n' "stage=stage_history" "source=${MASTER_LOG}"
  grep -A 6 "stage=stage_result" "${MASTER_LOG}" || true
fi

for LEVEL in ${LEVELS}; do
  EVAL_ID="go2-ab-level${LEVEL}-${STAMP}"
  printf '%s\n' "stage=run_level" "level=${LEVEL}" "eval_id=${EVAL_ID}"
  set +e
  CHECKPOINT_PATH="${CHECKPOINT_PATH}" \
  RUN_DIR="${RUN_DIR}" \
  EVAL_ID="${EVAL_ID}" \
  TERRAIN_LEVEL="${LEVEL}" \
  TYPES="${TYPES}" \
  COMMAND_X="${COMMAND_X:-0.4}" \
    bash "${SCRIPT_DIR}/eval_level_sweep_job.sh"
  RC=$?
  set -e
  printf '%s\n' "stage=run_level_done" "level=${LEVEL}" "exit=${RC}"
  CSV="${DATA_ROOT}/media/${EVAL_ID}/level_sweep.csv"
  if [ -f "${CSV}" ]; then
    tail -n +2 "${CSV}" | awk -F, -v lv="${LEVEL}" \
      '{printf "compare level=%s terrain=%s label=%s distance=%s reached_row=%s lateral=%s fell=%s exit=%s\n", lv, $1, $3, $5, $6, $10, $11, $12}'
  fi
done

printf '%s\n' "stage=complete" "log=${LOG}"
