#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/data/proj1}"
RUN_ID="${RUN_ID:-go2-flat-baseline-20261122-140507}"
TASK="${TASK:-go2}"
LOAD_RUN="${LOAD_RUN:-Nov22_14-05-53_simple_rl_isaacgym}"
START_CHECKPOINT="${START_CHECKPOINT:-1500}"
TARGET_ITERATIONS="${TARGET_ITERATIONS:-3000}"
TRAIN_ENVS="${TRAIN_ENVS:-8192}"
FALLBACK_ENVS="${FALLBACK_ENVS:-4096}"
EVAL_EPISODES="${EVAL_EPISODES:-20}"
EVAL_ENVS="${EVAL_ENVS:-20}"
COMMAND_X="${COMMAND_X:-0.3}"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
RESULT_DIR="${DATA_ROOT}/results"
MEDIA_DIR="${DATA_ROOT}/media"
RUN_DIR="${DATA_ROOT}/runs/${RUN_ID}"
LOG="${RESULT_DIR}/integrated-flat-${STAMP}.log"
MANIFEST="${RESULT_DIR}/integrated-flat-${STAMP}.manifest.txt"

mkdir -p "${RESULT_DIR}" "${MEDIA_DIR}"
exec > >(tee -a "${LOG}") 2>&1

printf '%s\n' \
  "integrated_package=flat_train_eval_record_v1" \
  "started_at=$(date -Is)" \
  "run_id=${RUN_ID}" \
  "task=${TASK}" \
  "resume_checkpoint=${START_CHECKPOINT}" \
  "target_iterations=${TARGET_ITERATIONS}" \
  "requested_train_envs=${TRAIN_ENVS}" \
  "fallback_train_envs=${FALLBACK_ENVS}" \
  "eval_command_x=${COMMAND_X}" \
  "log=${LOG}"

write_manifest() {
  {
    printf '%s\n' \
      "integrated_package=flat_train_eval_record_v1" \
      "run_dir=${RUN_DIR}" \
      "task=${TASK}" \
      "load_run=${LOAD_RUN}" \
      "resume_checkpoint=${START_CHECKPOINT}" \
      "target_iterations=${TARGET_ITERATIONS}" \
      "train_envs=${USED_TRAIN_ENVS:-unknown}" \
      "eval_command_x=${COMMAND_X}" \
      "log=${LOG}" \
      "finished_at=$(date -Is)"
    find "${RUN_DIR}" -type f \( -name 'model_*.pt' -o -name 'events.out.tfevents.*' \) -printf 'artifact=%p\n' 2>/dev/null | sort
    find "${RESULT_DIR}" -maxdepth 1 -type f -name "integrated-flat-eval-${STAMP}*" -printf 'result=%p\n' 2>/dev/null | sort
    find "${MEDIA_DIR}" -maxdepth 1 -type f -name "integrated-flat-eval-${STAMP}*" -printf 'media=%p\n' 2>/dev/null | sort
  } > "${MANIFEST}"
}

trap 'status=$?; write_manifest; printf "%s\n" "exit_status=${status}" "manifest=${MANIFEST}"; exit "${status}"' EXIT

export DATA_ROOT RUN_ID TASK LOAD_RUN CHECKPOINT="${START_CHECKPOINT}" MAX_ITERATIONS="${TARGET_ITERATIONS}" RESUME=1
export NUM_ENVS="${TRAIN_ENVS}"
export RUN_DIR

run_training() {
  printf '%s\n' "stage=train" "num_envs=${NUM_ENVS}"
  set +e
  bash "$(dirname "$0")/train_job.sh"
  status=$?
  set -e
  return "${status}"
}

if ! run_training; then
  if grep -Eqi 'out of memory|cuda.*memory|oom' "${LOG}"; then
    printf '%s\n' "stage=train_retry" "reason=oom" "num_envs=${FALLBACK_ENVS}"
    export NUM_ENVS="${FALLBACK_ENVS}"
    run_training
  else
    printf '%s\n' "stage=train_failed" "reason=non_oom"
    exit 1
  fi
fi

USED_TRAIN_ENVS="${NUM_ENVS}"
printf '%s\n' "stage=train_done" "num_envs=${USED_TRAIN_ENVS}"

CHECKPOINT_PATH="$(find "${RUN_DIR}/logs" -type f -name 'model_*.pt' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)"
[ -n "${CHECKPOINT_PATH}" ] || { printf '%s\n' "没有找到训练 checkpoint"; exit 1; }
CHECKPOINT="$(basename "${CHECKPOINT_PATH}" | sed -E 's/^model_([0-9]+)\.pt$/\1/')"
RUN_NAME="$(basename "$(dirname "${CHECKPOINT_PATH}")")"
printf '%s\n' "stage=checkpoint_selected" "checkpoint_path=${CHECKPOINT_PATH}" "checkpoint=${CHECKPOINT}" "run_name=${RUN_NAME}"

export CHECKPOINT RUN_NAME RUN_GLOB='unused' TASK EPISODES="${EVAL_EPISODES}" NUM_ENVS="${EVAL_ENVS}" FRAMES=900 STATE_INTERVAL=30 COMMAND_X
export CHECKPOINT_PATH RUN_DIR EVAL_ID="integrated-flat-eval-${STAMP}" CONSOLIDATED_LOG=1
printf '%s\n' "stage=eval_and_record" "eval_id=${EVAL_ID}" "episodes=${EPISODES}" "num_envs=${NUM_ENVS}"
bash "$(dirname "$0")/eval_and_record_job.sh"
printf '%s\n' "stage=complete" "manifest=${MANIFEST}"
