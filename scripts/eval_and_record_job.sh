#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/data/proj1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_ROOT="${RUNTIME_ROOT:-/tmp/proj1-runtime-eval}"
ENV_DIR="${RUNTIME_ROOT}/py38"
ENV_PACK="${ENV_PACK:-${DATA_ROOT}/env/isaacgym-py38.tar.gz}"
ISAAC_PY="${DATA_ROOT}/vendor/isaacgym/python"
REPO_DIR="${DATA_ROOT}/vendor/LeggedGym-Ex"
RUN_DIR="${RUN_DIR:-$(find "${DATA_ROOT}/runs" -maxdepth 1 -type d -name "${RUN_GLOB:?RUN_GLOB is required}" | sort | tail -1)}"
TASK="${TASK:?TASK is required}"
CHECKPOINT="${CHECKPOINT:?CHECKPOINT is required}"
EPISODES="${EPISODES:-100}"
NUM_ENVS="${NUM_ENVS:-100}"
FRAMES="${FRAMES:-1800}"
STATE_INTERVAL="${STATE_INTERVAL:-30}"
COMMAND_X="${COMMAND_X:-1.0}"
MEDIA_DIR="${DATA_ROOT}/media"
RESULT_DIR="${DATA_ROOT}/results"
FRAME_DIR="${MEDIA_DIR}/${EVAL_ID}-frames"
VIDEO_PATH="${MEDIA_DIR}/${EVAL_ID}.mp4"
CSV_PATH="${RESULT_DIR}/${EVAL_ID}.csv"
SUMMARY_PATH="${RESULT_DIR}/${EVAL_ID}.summary.txt"
STATE_LOG_PATH="${RESULT_DIR}/${EVAL_ID}.state.csv"
JOB_STAMP="$(date +%Y%m%d-%H%M%S)-$$"
LOG_PATH="${RESULT_DIR}/${EVAL_ID}-${JOB_STAMP}.log"
DEBUG_PATH="${RESULT_DIR}/${EVAL_ID}-${JOB_STAMP}.debug.log"
LATEST_LOG="${RESULT_DIR}/${EVAL_ID}.latest.log"
LATEST_DEBUG="${RESULT_DIR}/${EVAL_ID}.latest.debug.log"
CONSOLIDATED_LOG="${CONSOLIDATED_LOG:-0}"

mkdir -p "${MEDIA_DIR}" "${RESULT_DIR}"
if [ "${CONSOLIDATED_LOG}" = "1" ]; then
  exec 3>&1
  printf '%s\n' "eval_package=diagnostic_checkpoint_speed_sweep_v2" "eval_start=$(date -Is 2>/dev/null || date)" "checkpoint=${CHECKPOINT}" "command_x=${COMMAND_X}" "state_log=${STATE_LOG_PATH}"
  trap 'status=$?; printf "%s\n" "eval_exit=${status}" "eval_end=$(date -Is 2>/dev/null || date)"; exit "${status}"' EXIT
  trap 'status=$?; printf "%s\n" "eval_error_line=${LINENO}" "eval_error_status=${status}"; exit "${status}"' ERR
else
  exec > >(tee "${LOG_PATH}") 2>&1
  exec 3>>"${DEBUG_PATH}"
  ln -sfn "$(basename "${LOG_PATH}")" "${LATEST_LOG}"
  ln -sfn "$(basename "${DEBUG_PATH}")" "${LATEST_DEBUG}"
  printf '%s\n' "eval_package=diagnostic_checkpoint_speed_sweep_v2" "eval_start=$(date -Is 2>/dev/null || date)" "checkpoint=${CHECKPOINT}" "command_x=${COMMAND_X}" "log_path=${LOG_PATH}" "debug_path=${DEBUG_PATH}" "state_log=${STATE_LOG_PATH}" | tee /dev/fd/3
  trap 'status=$?; printf "%s\n" "eval_exit=${status}" "eval_end=$(date -Is 2>/dev/null || date)" | tee /dev/fd/3; exit "${status}"' EXIT
  trap 'status=$?; printf "%s\n" "eval_error_line=${LINENO}" "eval_error_status=${status}" | tee /dev/fd/3; exit "${status}"' ERR
fi
export DEBIAN_FRONTEND=noninteractive
printf '%s\n' "stage=apt_check" | tee /dev/fd/3
if ! command -v ffmpeg >/dev/null 2>&1; then
  printf '%s\n' "stage=apt_install" | tee /dev/fd/3
  apt-get update -qq >/tmp/proj1-eval-apt.log 2>&1
  apt-get install -y -qq --no-install-recommends ffmpeg xvfb libgl1 libglu1-mesa libx11-6 libxext6 libxrender1 >>/tmp/proj1-eval-apt.log 2>&1
fi
if ! command -v Xvfb >/dev/null 2>&1; then
  printf '%s\n' "stage=xvfb_missing" | tee /dev/fd/3
  apt-get update -qq >/tmp/proj1-eval-apt.log 2>&1
  apt-get install -y -qq --no-install-recommends xvfb libgl1 libglu1-mesa libx11-6 libxext6 libxrender1 >>/tmp/proj1-eval-apt.log 2>&1
fi
export DISPLAY="${DISPLAY:-:99}"
Xvfb "${DISPLAY}" -screen 0 1280x720x24 -ac >/tmp/proj1-eval-xvfb.log 2>&1 &
XVFB_PID=$!
trap 'status=$?; kill "${XVFB_PID}" 2>/dev/null || true; printf "%s\n" "eval_exit=${status}" "eval_end=$(date -Is 2>/dev/null || date)" | tee /dev/fd/3; exit "${status}"' EXIT
sleep 1
printf '%s\n' "stage=xvfb_ready" "display=${DISPLAY}" | tee /dev/fd/3
printf '%s\n' "stage=env_check" "env_pack=${ENV_PACK}" | tee /dev/fd/3
[ -f "${ENV_PACK}" ] || { echo "缺少环境包: ${ENV_PACK}"; exit 1; }
if [ ! -x "${ENV_DIR}/bin/python" ]; then
  printf '%s\n' "stage=env_unpack" "env_dir=${ENV_DIR}" | tee /dev/fd/3
  rm -rf "${ENV_DIR}"
  mkdir -p "${ENV_DIR}"
  tar -xzf "${ENV_PACK}" -C "${ENV_DIR}"
  "${ENV_DIR}/bin/conda-unpack"
fi
printf '%s\n' "stage=vendor_check" "isaac_py=${ISAAC_PY}" "repo_dir=${REPO_DIR}" | tee /dev/fd/3
[ -d "${ISAAC_PY}" ] || { echo "缺少 Isaac Gym: ${ISAAC_PY}"; exit 1; }
[ -d "${REPO_DIR}" ] || { echo "缺少 LeggedGym-Ex: ${REPO_DIR}"; exit 1; }
printf '%s\n' "stage=run_check" "run_dir=${RUN_DIR}" | tee /dev/fd/3
[ -d "${RUN_DIR}/logs" ] || { echo "缺少训练目录: ${RUN_DIR}/logs"; exit 1; }
printf '%s\n' "stage=logs_link" | tee /dev/fd/3
rm -f "${REPO_DIR}/logs"
ln -s "${RUN_DIR}/logs" "${REPO_DIR}/logs"
printf '%s\n' "stage=checkpoint_search" | tee /dev/fd/3
if [ -z "${CHECKPOINT_PATH:-}" ]; then
  CHECKPOINT_PATH="$(find "${RUN_DIR}/logs" -type f -name "model_${CHECKPOINT}.pt" -print | sort | tail -1)"
else
  printf '%s\n' "checkpoint_path_supplied=1" | tee /dev/fd/3
fi
[ -n "${CHECKPOINT_PATH}" ] || { echo "找不到 checkpoint: ${RUN_DIR}/logs/model_${CHECKPOINT}.pt"; exit 1; }
RUN_NAME="$(basename "$(dirname "${CHECKPOINT_PATH}")")"
printf '%s\n' "checkpoint_path=${CHECKPOINT_PATH}"
export ENV_DIR SIMULATOR=isaacgym
export PYTHONPATH="${REPO_DIR}:${ISAAC_PY}:${PYTHONPATH:-}"
export LD_LIBRARY_PATH="${ENV_DIR}/lib:${ISAAC_PY}/isaacgym/_bindings/linux-x86_64:${LD_LIBRARY_PATH:-}"
printf '%s\n' "run_dir=${RUN_DIR}" "run_name=${RUN_NAME}" "task=${TASK}" "checkpoint=${CHECKPOINT}" "episodes=${EPISODES}" "num_envs=${NUM_ENVS}"
printf '%s\n' "stage=before_python" "python=${ENV_DIR}/bin/python" "script=/code/workspace/scripts/eval_and_record.py" | tee /dev/fd/3
export PYTHONUNBUFFERED=1
"${ENV_DIR}/bin/python" "${EVAL_SCRIPT:-${SCRIPT_DIR}/eval_and_record.py}" \
  --task "${TASK}" --load_run "${RUN_NAME}" --ckpt "${CHECKPOINT}" \
  --num_envs "${NUM_ENVS}" --episodes "${EPISODES}" --frames "${FRAMES}" \
  --frame_dir "${FRAME_DIR}" --video "${VIDEO_PATH}" --csv "${CSV_PATH}" --summary "${SUMMARY_PATH}" \
  --state_log "${STATE_LOG_PATH}" --state_interval "${STATE_INTERVAL}" --command_x "${COMMAND_X}"
printf '%s\n' "eval_end=$(date -Is 2>/dev/null || date)"
