#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/data/proj1}"
RUN_DIR="${RUN_DIR:-${DATA_ROOT}/runs/go2-flat-baseline-20261122-140507}"
TASK="${TASK:-go2}"
CHECKPOINT="${CHECKPOINT:-4000}"
EPISODES="${EPISODES:-20}"
NUM_ENVS="${NUM_ENVS:-20}"
COMMAND_X="${COMMAND_X:-0.3}"
EVAL_ID="${EVAL_ID:-go2-flat-model-${CHECKPOINT}-eval}"
CHECKPOINT_PATH="${CHECKPOINT_PATH:-$(find "${RUN_DIR}/logs" -type f -name "model_${CHECKPOINT}.pt" -print | sort | tail -1)}"

[ -n "${CHECKPOINT_PATH}" ] || { echo "找不到固定 checkpoint: model_${CHECKPOINT}.pt"; exit 1; }
[ -f "${CHECKPOINT_PATH}" ] || { echo "checkpoint 不存在: ${CHECKPOINT_PATH}"; exit 1; }

export DATA_ROOT RUN_DIR TASK CHECKPOINT EPISODES NUM_ENVS COMMAND_X EVAL_ID CHECKPOINT_PATH
export FRAMES="${FRAMES:-900}"
export STATE_INTERVAL="${STATE_INTERVAL:-30}"
export CONSOLIDATED_LOG=0

echo "fixed_eval_package=go2_fixed_checkpoint_eval_v1"
echo "mode=eval_only"
echo "task=${TASK}"
echo "checkpoint=${CHECKPOINT}"
echo "checkpoint_path=${CHECKPOINT_PATH}"
echo "checkpoint_sha256=$(sha256sum "${CHECKPOINT_PATH}" | awk '{print $1}')"
echo "episodes=${EPISODES}"
echo "num_envs=${NUM_ENVS}"
echo "command_x=${COMMAND_X}"
echo "run_dir=${RUN_DIR}"

bash "$(dirname "$0")/eval_and_record_job.sh"

RESULT_DIR="${DATA_ROOT}/results"
MEDIA_DIR="${DATA_ROOT}/media"
MANIFEST="${RESULT_DIR}/${EVAL_ID}.manifest.txt"
{
  echo "fixed_eval_package=go2_fixed_checkpoint_eval_v1"
  echo "task=${TASK}"
  echo "checkpoint=${CHECKPOINT}"
  echo "checkpoint_path=${CHECKPOINT_PATH}"
  echo "checkpoint_sha256=$(sha256sum "${CHECKPOINT_PATH}" | awk '{print $1}')"
  echo "csv=${RESULT_DIR}/${EVAL_ID}.csv"
  echo "state_csv=${RESULT_DIR}/${EVAL_ID}.state.csv"
  echo "summary=${RESULT_DIR}/${EVAL_ID}.summary.txt"
  echo "video=${MEDIA_DIR}/${EVAL_ID}.mp4"
  echo "finished_at=$(date -Is)"
} > "${MANIFEST}"
echo "manifest=${MANIFEST}"
