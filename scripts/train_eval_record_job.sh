#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data/proj1}"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
RUN_ID="${RUN_ID:-go2-flat-clean-${STAMP}}"
TASK="${TASK:-go2}"
NUM_ENVS="${NUM_ENVS:-4096}"
FALLBACK_ENVS="${FALLBACK_ENVS:-2048}"
MAX_ITERATIONS="${MAX_ITERATIONS:-3000}"
EPISODES="${EPISODES:-20}"
EVAL_ENVS="${EVAL_ENVS:-20}"
COMMAND_X="${COMMAND_X:-0.3}"
FRAMES="${FRAMES:-900}"
STATE_INTERVAL="${STATE_INTERVAL:-30}"
RUN_DIR="${DATA_ROOT}/runs/${RUN_ID}"
RESULT_DIR="${DATA_ROOT}/results"
MEDIA_DIR="${DATA_ROOT}/media"
LOG="${RESULT_DIR}/${RUN_ID}.log"
MANIFEST="${RESULT_DIR}/${RUN_ID}.manifest.txt"

mkdir -p "${RESULT_DIR}" "${MEDIA_DIR}"
exec > >(tee -a "${LOG}") 2>&1

printf '%s\n' \
  "integrated_package=go2_flat_train_eval_v2" \
  "started_at=$(date -Is)" \
  "run_id=${RUN_ID}" \
  "task=${TASK}" \
  "num_envs_requested=${NUM_ENVS}" \
  "num_envs_fallback=${FALLBACK_ENVS}" \
  "max_iterations=${MAX_ITERATIONS}" \
  "command_x=${COMMAND_X}" \
  "log=${LOG}"

export DATA_ROOT RUN_ID RUN_DIR TASK NUM_ENVS MAX_ITERATIONS RESUME=0 LOAD_RUN= CHECKPOINT=
export ENV_PACK="${ENV_PACK:-${DATA_ROOT}/env/isaacgym-py38.tar.gz}"
export FLAT_DIAGNOSTIC_CONFIG=1
USED_TRAIN_ENVS="${NUM_ENVS}"
REQUESTED_TRAIN_ENVS="${NUM_ENVS}"

run_train() {
  export NUM_ENVS
  printf '%s\n' "stage=train" "num_envs=${NUM_ENVS}"
  bash "${SCRIPT_DIR}/train_job.sh"
}

if ! run_train; then
  if grep -Eqi 'out of memory|cuda.*memory|oom' "${LOG}"; then
    printf '%s\n' "stage=train_retry" "reason=oom" "num_envs=${FALLBACK_ENVS}"
    NUM_ENVS="${FALLBACK_ENVS}"
    USED_TRAIN_ENVS="${NUM_ENVS}"
    run_train
  else
    printf '%s\n' "stage=train_failed" "reason=non_oom"
    exit 1
  fi
fi

printf '%s\n' "stage=train_done" "run_dir=${RUN_DIR}" "num_envs=${NUM_ENVS}"
CHECKPOINT_PATH="$(find "${RUN_DIR}/logs" -type f -name 'model_[0-9]*.pt' -size +0c -printf '%f %p\n' | awk '{gsub(/^model_|\.pt$/,"",$1); print $1" "$2}' | sort -n | tail -1 | cut -d' ' -f2-)"
[ -n "${CHECKPOINT_PATH}" ] || { printf '%s\n' "stage=checkpoint_missing"; exit 1; }
CHECKPOINT="$(basename "${CHECKPOINT_PATH}" | sed -E 's/^model_([0-9]+)\.pt$/\1/')"
RUN_NAME="$(basename "$(dirname "${CHECKPOINT_PATH}")")"
CHECKPOINT_SHA256="$(sha256sum "${CHECKPOINT_PATH}" | awk '{print $1}')"
printf '%s\n' "stage=checkpoint_selected" "checkpoint_path=${CHECKPOINT_PATH}" "checkpoint=${CHECKPOINT}" "run_name=${RUN_NAME}" "checkpoint_sha256=${CHECKPOINT_SHA256}"

EVAL_ID="${RUN_ID}-eval"
export RUN_DIR RUN_NAME CHECKPOINT CHECKPOINT_PATH TASK EPISODES EVAL_ID
export NUM_ENVS="${EVAL_ENVS}" FRAMES STATE_INTERVAL COMMAND_X CONSOLIDATED_LOG=1
printf '%s\n' "stage=eval_and_record" "eval_id=${EVAL_ID}" "episodes=${EPISODES}" "eval_envs=${NUM_ENVS}"
bash "${SCRIPT_DIR}/eval_and_record_job.sh"

CSV="${RESULT_DIR}/${EVAL_ID}.csv"
STATE="${RESULT_DIR}/${EVAL_ID}.state.csv"
SUMMARY="${RESULT_DIR}/${EVAL_ID}.summary.txt"
VIDEO="${MEDIA_DIR}/${EVAL_ID}.mp4"
{
  printf '%s\n' \
    "integrated_package=go2_flat_train_eval_v2" \
    "run_dir=${RUN_DIR}" \
    "task=${TASK}" \
    "requested_train_envs=${REQUESTED_TRAIN_ENVS}" \
    "actual_train_envs=${USED_TRAIN_ENVS}" \
    "eval_envs=${EVAL_ENVS}" \
    "max_iterations=${MAX_ITERATIONS}" \
    "checkpoint_path=${CHECKPOINT_PATH}" \
    "checkpoint=${CHECKPOINT}" \
    "checkpoint_sha256=${CHECKPOINT_SHA256}" \
    "repo_commit=$(git -C "${DATA_ROOT}/vendor/LeggedGym-Ex" rev-parse HEAD 2>/dev/null || printf unknown)" \
    "train_script_sha256=$(sha256sum "${SCRIPT_DIR}/train.sh" | awk '{print $1}')" \
    "eval_script_sha256=$(sha256sum "${SCRIPT_DIR}/eval_and_record.py" | awk '{print $1}')" \
    "command_x=${COMMAND_X}" \
    "log=${LOG}" \
    "csv=${CSV}" \
    "state_csv=${STATE}" \
    "summary=${SUMMARY}" \
    "video=${VIDEO}" \
    "finished_at=$(date -Is)"
} > "${MANIFEST}"
printf '%s\n' "stage=complete" "manifest=${MANIFEST}"
