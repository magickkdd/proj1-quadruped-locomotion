#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data/proj1}"
REPO_DIR="${REPO_DIR:-${DATA_ROOT}/vendor/LeggedGym-Ex}"
ENV_PACK="${ENV_PACK:-${DATA_ROOT}/env/isaacgym-py38.tar.gz}"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"

RUN_ID="${RUN_ID:-go2-rough-curriculum-6000-${STAMP}}"
RUN_DIR="${DATA_ROOT}/runs/${RUN_ID}"
NUM_ENVS="${NUM_ENVS:-4096}"
FALLBACK_ENVS="${FALLBACK_ENVS:-2048}"
MAX_ITERATIONS="${MAX_ITERATIONS:-15000}"
INIT_TERRAIN_LEVEL="${INIT_TERRAIN_LEVEL:-1}"
BACKUP_DIR="${DATA_ROOT}/config-backups/${RUN_ID}"
LOG="${DATA_ROOT}/results/${RUN_ID}.log"

mkdir -p "${DATA_ROOT}/results" "${DATA_ROOT}/media"
exec > >(tee -a "${LOG}") 2>&1

printf '%s\n' \
  "rough_train_package=rough_ts_curriculum_v1" \
  "started_at=$(date -Is)" \
  "run_id=${RUN_ID}" \
  "task=go2_ts" \
  "num_envs_requested=${NUM_ENVS}" \
  "num_envs_fallback=${FALLBACK_ENVS}" \
  "max_iterations=${MAX_ITERATIONS}" \
  "init_terrain_level=${INIT_TERRAIN_LEVEL}" \
  "log=${LOG}"

PATCH_PY="${SCRIPT_DIR}/patch_terrain_curriculum.py"
[ -f "${PATCH_PY}" ] || { printf '%s\n' "error=missing_patch_script"; exit 1; }

restore_curriculum() {
  python3 "${PATCH_PY}" restore "${REPO_DIR}" "${BACKUP_DIR}" 2>/dev/null || true
}
trap restore_curriculum EXIT

printf '%s\n' "stage=curriculum_patch"
python3 "${PATCH_PY}" apply "${REPO_DIR}" "${BACKUP_DIR}" "${INIT_TERRAIN_LEVEL}"

export DATA_ROOT RUN_ID RUN_DIR
export TASK=go2_ts
export RESUME=0 LOAD_RUN= CHECKPOINT=
export ENV_PACK MAX_ITERATIONS
printf '%s\n' "effective_max_iterations=${MAX_ITERATIONS}" "effective_num_envs=${NUM_ENVS}"
USED_TRAIN_ENVS="${NUM_ENVS}"
REQUESTED_TRAIN_ENVS="${NUM_ENVS}"

run_train() {
  export NUM_ENVS
  printf '%s\n' "stage=train" "num_envs=${NUM_ENVS}" "max_iterations=${MAX_ITERATIONS}"
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

printf '%s\n' "stage=train_done" "num_envs=${USED_TRAIN_ENVS}"
ACTUAL_ITERS="$(grep -oE 'Learning iteration [0-9]+/[0-9]+' "${LOG}" | tail -1 | sed -E 's#.*/##')"
printf '%s\n' "trained_iterations=${ACTUAL_ITERS:-unknown}" "expected_iterations=${MAX_ITERATIONS}"
if [ -n "${ACTUAL_ITERS}" ]; then
  MIN_ACCEPT=$(( MAX_ITERATIONS * 6 / 10 ))
  if [ "${ACTUAL_ITERS}" -lt "${MIN_ACCEPT}" ]; then
    printf '%s\n' "stage=iteration_too_low" "expected=${MAX_ITERATIONS}" "actual=${ACTUAL_ITERS}" "min_accept=${MIN_ACCEPT}"
    exit 1
  fi
fi
CURVE_FILE="${RUN_DIR}/terrain_curve.txt"
if grep -aq 'Mean episode terrain_level' "${LOG}"; then
  {
    printf '%s\n' "iteration terrain_level"
    grep -a 'Mean episode terrain_level' "${LOG}" | awk 'BEGIN{n=0} {n++; if (n % 500 == 0) print n, $NF}'
  } > "${CURVE_FILE}"
  printf '%s\n' "stage=terrain_curve" "file=${CURVE_FILE}"
  cat "${CURVE_FILE}"
fi
restore_curriculum
trap - EXIT

CHECKPOINT_PATH="$(find "${RUN_DIR}/logs" -type f -name 'model_[0-9]*.pt' -size +0c -printf '%f %p\n' \
  | awk '{gsub(/^model_|\.pt$/,"",$1); print $1" "$2}' | sort -n | tail -1 | cut -d' ' -f2-)"
if [ -z "${CHECKPOINT_PATH}" ] || [ ! -s "${CHECKPOINT_PATH}" ]; then
  printf '%s\n' "stage=checkpoint_missing" "run_dir=${RUN_DIR}"
  exit 1
fi

CHECKPOINT="$(basename "${CHECKPOINT_PATH}" | sed -E 's/^model_([0-9]+)\.pt$/\1/')"
RUN_NAME="$(basename "$(dirname "${CHECKPOINT_PATH}")")"
printf '%s\n' "stage=checkpoint_selected" \
  "checkpoint_path=${CHECKPOINT_PATH}" \
  "checkpoint=${CHECKPOINT}" \
  "run_name=${RUN_NAME}" \
  "checkpoint_sha256=$(sha256sum "${CHECKPOINT_PATH}" | awk '{print $1}')"

export RUN_DIR RUN_NAME CHECKPOINT CHECKPOINT_PATH
export EVAL_ID="${RUN_ID}-matrix"
export TERRAIN_TYPES="${TERRAIN_TYPES:-9}"
export TERRAIN_LEVEL="${TERRAIN_LEVEL:-matrix}"
export TERRAIN_MATRIX_LEVELS="${TERRAIN_MATRIX_LEVELS:-4,7,10}"
export TERRAIN_CAMERA_LEVEL="${TERRAIN_CAMERA_LEVEL:-8}"
export TERRAIN_CAMERA_TYPE="${TERRAIN_CAMERA_TYPE:-7}"
export COMMAND_X="${COMMAND_X:-0.4}"
export EPISODES="${EPISODES:-30}" NUM_ENVS="${NUM_ENVS_EVAL:-30}"
export FRAMES="${FRAMES:-700}" STATE_INTERVAL="${STATE_INTERVAL:-30}"

printf '%s\n' "stage=terrain_matrix_eval" "eval_id=${EVAL_ID}" \
  "terrain_levels=${TERRAIN_LEVEL}" "matrix_levels=${TERRAIN_MATRIX_LEVELS}" \
  "camera_type=${TERRAIN_CAMERA_TYPE}" "camera_level=${TERRAIN_CAMERA_LEVEL}" "command_x=${COMMAND_X}"
bash "${SCRIPT_DIR}/eval_stair_capability_job.sh"

SUMMARY="${DATA_ROOT}/results/${EVAL_ID}.summary.txt"
MANIFEST="${DATA_ROOT}/results/${RUN_ID}.manifest.txt"
{
  printf '%s\n' \
    "rough_train_package=rough_ts_curriculum_v1" \
    "run_dir=${RUN_DIR}" \
    "task=go2_ts" \
    "requested_train_envs=${REQUESTED_TRAIN_ENVS}" \
    "actual_train_envs=${USED_TRAIN_ENVS}" \
    "max_iterations=${MAX_ITERATIONS}" \
    "init_terrain_level=${INIT_TERRAIN_LEVEL}" \
    "eval_terrain_matrix=${TERRAIN_MATRIX_LEVELS}" \
    "eval_camera_terrain=type_${TERRAIN_CAMERA_TYPE}_level_${TERRAIN_CAMERA_LEVEL}" \
    "checkpoint_path=${CHECKPOINT_PATH}" \
    "checkpoint=${CHECKPOINT}" \
    "checkpoint_sha256=$(sha256sum "${CHECKPOINT_PATH}" | awk '{print $1}')" \
    "log=${LOG}" \
    "eval_summary=${SUMMARY}" \
    "video=${DATA_ROOT}/media/${EVAL_ID}.mp4" \
    "finished_at=$(date -Is)"
} > "${MANIFEST}"

if [ -f "${SUMMARY}" ]; then
  printf '%s\n' "stage=eval_summary"
  cat "${SUMMARY}"
fi
printf '%s\n' "stage=complete" "manifest=${MANIFEST}"
