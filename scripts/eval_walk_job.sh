#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data/proj1}"
REPO_DIR="${REPO_DIR:-${DATA_ROOT}/vendor/LeggedGym-Ex}"
ENV_PACK="${ENV_PACK:-${DATA_ROOT}/env/isaacgym-py38.tar.gz}"
RUNTIME_ROOT="${RUNTIME_ROOT:-/tmp/proj1-runtime-eval}"

# Pick the newest trained Go2 run unless one is supplied explicitly.
RUN_DIR="${RUN_DIR:-$(find "${DATA_ROOT}/runs" -maxdepth 1 -type d -name 'go2-flat-clean-*' | sort | tail -1)}"
[ -n "${RUN_DIR}" ] && [ -d "${RUN_DIR}/logs" ] || {
  printf '%s\n' "error=no_trained_run_found" "hint=dir=${DATA_ROOT}/runs" >&2
  exit 1
}

CHECKPOINT_PATH="${CHECKPOINT_PATH:-$(find "${RUN_DIR}/logs" -type f -name 'model_*.pt' -size +0c \
  -printf '%f %p\n' | awk '{gsub(/^model_|\.pt$/,"",$1); print $1" "$2}' | sort -n | tail -1 | cut -d' ' -f2-)}"
[ -n "${CHECKPOINT_PATH}" ] && [ -s "${CHECKPOINT_PATH}" ] || {
  printf '%s\n' "error=no_checkpoint_found" "run_dir=${RUN_DIR}" >&2
  exit 1
}

CHECKPOINT="$(basename "${CHECKPOINT_PATH}" | sed -E 's/^model_([0-9]+)\.pt$/\1/')"
RUN_NAME="$(basename "$(dirname "${CHECKPOINT_PATH}")")"
EVAL_ID="${EVAL_ID:-go2-walk-$(date +%Y%m%d-%H%M%S)-$$}"
BACKUP_DIR="${RUNTIME_ROOT}/config-backup"
LOG="${DATA_ROOT}/results/${EVAL_ID}.log"

mkdir -p "${DATA_ROOT}/results" "${DATA_ROOT}/media"
exec > >(tee -a "${LOG}") 2>&1

printf '%s\n' \
  "walk_package=checkpoint_loading_v1" \
  "stage=resolve" \
  "run_dir=${RUN_DIR}" \
  "checkpoint_path=${CHECKPOINT_PATH}" \
  "checkpoint=${CHECKPOINT}" \
  "checkpoint_sha256=$(sha256sum "${CHECKPOINT_PATH}" | awk '{print $1}')" \
  "run_name=${RUN_NAME}" \
  "eval_id=${EVAL_ID}" \
  "log=${LOG}"

# Eval must use the same environment contract as training.
mkdir -p "${BACKUP_DIR}"
PATCH_PY="${SCRIPT_DIR}/go2_flat_patch.py"
if [ ! -f "${PATCH_PY}" ]; then
  printf '%s\n' "error=missing_patch_script" "path=${PATCH_PY}" >&2
  exit 1
fi
restore_config() {
  "${RUNTIME_ROOT}/py38/bin/python" "${PATCH_PY}" restore "${REPO_DIR}" "${BACKUP_DIR}" 2>/dev/null \
    || python3 "${PATCH_PY}" restore "${REPO_DIR}" "${BACKUP_DIR}" 2>/dev/null \
    || true
}
trap restore_config EXIT

if [ ! -x "${RUNTIME_ROOT}/py38/bin/python" ]; then
  printf '%s\n' "stage=env_unpack" "env_pack=${ENV_PACK}"
  rm -rf "${RUNTIME_ROOT}/py38"
  mkdir -p "${RUNTIME_ROOT}/py38"
  tar -xzf "${ENV_PACK}" -C "${RUNTIME_ROOT}/py38"
  "${RUNTIME_ROOT}/py38/bin/conda-unpack"
fi

printf '%s\n' "stage=config_patch"
"${RUNTIME_ROOT}/py38/bin/python" "${PATCH_PY}" apply "${REPO_DIR}" "${BACKUP_DIR}"

export DATA_ROOT RUN_DIR RUN_NAME TASK="${TASK:-go2}"
export CHECKPOINT CHECKPOINT_PATH
export EVAL_ID EPISODES="${EPISODES:-20}" NUM_ENVS="${NUM_ENVS:-20}"
export FRAMES="${FRAMES:-1000}" STATE_INTERVAL="${STATE_INTERVAL:-30}"
export COMMAND_X="${COMMAND_X:-0.3}" CONSOLIDATED_LOG=1

printf '%s\n' "stage=eval_and_record" "command_x=${COMMAND_X}" "episodes=${EPISODES}"
bash "${SCRIPT_DIR}/eval_and_record_job.sh"

SUMMARY="${DATA_ROOT}/results/${EVAL_ID}.summary.txt"
if [ -f "${SUMMARY}" ]; then
  printf '%s\n' "stage=summary"
  cat "${SUMMARY}"
fi
printf '%s\n' "stage=complete"
