#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data/proj1}"
ENV_PACK="${ENV_PACK:-${DATA_ROOT}/env/isaacgym-py38.tar.gz}"
RUNTIME_ROOT="${RUNTIME_ROOT:-/tmp/proj1-runtime-wtw}"
ENV_DIR="${RUNTIME_ROOT}/py38"
ISAAC_PY="${DATA_ROOT}/vendor/isaacgym/python"
REPO_DIR="${DATA_ROOT}/vendor/LeggedGym-Ex"

RUN_ID="${RUN_ID:-go2-wtw-rough-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_DIR="${DATA_ROOT}/runs/${RUN_ID}"
LOG="${DATA_ROOT}/results/${RUN_ID}.log"

TASK="${TASK:-go2_wtw}"
NUM_ENVS="${NUM_ENVS:-4096}"
MAX_ITERATIONS="${MAX_ITERATIONS:-4000}"
EVAL_TYPES="${EVAL_TYPES:-0,1,2,3,4,5,6,7,8,9}"
EVAL_COMMAND_X="${EVAL_COMMAND_X:-0.4}"

mkdir -p "${DATA_ROOT}/results" "${DATA_ROOT}/media" "${RUN_DIR}/logs"
exec > >(tee -a "${LOG}") 2>&1

printf '%s\n' "wtw_package=go2_wtw_rough_v1" "started_at=$(date -Is)" \
  "run_id=${RUN_ID}" "task=${TASK}" "num_envs=${NUM_ENVS}" \
  "max_iterations=${MAX_ITERATIONS}" "log=${LOG}"

[ -f "${ENV_PACK}" ] || { printf '%s\n' "error=missing_env_pack" "path=${ENV_PACK}"; exit 1; }
[ -d "${REPO_DIR}" ] || { printf '%s\n' "error=missing_repo" "path=${REPO_DIR}"; exit 1; }

if ! ldconfig -p 2>/dev/null | grep -q 'libX11.so.6'; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/tmp/proj1-wtw-apt.log 2>&1 || true
  apt-get install -y -qq --no-install-recommends \
    libx11-6 libxext6 libxrender1 libgl1 libglu1-mesa ffmpeg xvfb \
    >>/tmp/proj1-wtw-apt.log 2>&1 || true
fi

if [ ! -x "${ENV_DIR}/bin/python" ]; then
  printf '%s\n' "stage=env_unpack" "env_dir=${ENV_DIR}"
  rm -rf "${ENV_DIR}"
  mkdir -p "${ENV_DIR}"
  tar -xzf "${ENV_PACK}" -C "${ENV_DIR}"
  "${ENV_DIR}/bin/conda-unpack"
fi

export ENV_DIR DATA_ROOT REPO_DIR ISAAC_PY SIMULATOR=isaacgym
export PYTHONPATH="${REPO_DIR}:${ISAAC_PY}:${SCRIPT_DIR}:${PYTHONPATH:-}"
export LD_LIBRARY_PATH="${ENV_DIR}/lib:${ISAAC_PY}/isaacgym/_bindings/linux-x86_64:${LD_LIBRARY_PATH:-}"
export PYTHONUNBUFFERED=1

if [ -e "${REPO_DIR}/logs" ] && [ ! -L "${REPO_DIR}/logs" ]; then
  cp -a "${REPO_DIR}/logs/." "${RUN_DIR}/logs/" 2>/dev/null || true
  rm -rf "${REPO_DIR}/logs"
fi
ln -sfn "${RUN_DIR}/logs" "${REPO_DIR}/logs"

TRAIN_LOG="${RUN_DIR}/train.log"
printf '%s\n' "stage=train" "train_log=${TRAIN_LOG}"
set +e
"${ENV_DIR}/bin/python" "${SCRIPT_DIR}/train_wtw.py" \
  --task "${TASK}" --headless --num_envs "${NUM_ENVS}" \
  --max_iterations "${MAX_ITERATIONS}" 2>&1 | tee "${TRAIN_LOG}"
TRAIN_EXIT=${PIPESTATUS[0]}
set -e
printf '%s\n' "stage=train_done" "exit=${TRAIN_EXIT}"
[ "${TRAIN_EXIT}" -eq 0 ] || { printf '%s\n' "error=train_failed"; exit 1; }

LAST_ITER="$(grep -a 'Learning iteration' "${TRAIN_LOG}" | tail -1 | sed -E 's|.*iteration ([0-9]+)/.*|\1|')"
printf '%s\n' "train_last_iteration=${LAST_ITER:-0}"
if [ -n "${LAST_ITER}" ] && [ "${LAST_ITER}" -lt $((MAX_ITERATIONS / 2)) ]; then
  printf '%s\n' "error=iteration_too_low" "last=${LAST_ITER}" "target=${MAX_ITERATIONS}"
  exit 1
fi

EXPERIMENT="${EXPERIMENT:-go2_wtw}"
CHECKPOINT_PATH="$(find "${RUN_DIR}/logs/${EXPERIMENT}" -name 'model_*.pt' -size +0c \
  -printf '%f %p\n' 2>/dev/null | awk '{gsub(/^model_|\.pt$/,"",$1); print $1" "$2}' \
  | sort -n | tail -1 | cut -d' ' -f2-)"
if [ -z "${CHECKPOINT_PATH}" ]; then
  CHECKPOINT_PATH="$(find "${RUN_DIR}/logs" -name 'model_*.pt' -size +0c \
    -printf '%f %p\n' | awk '{gsub(/^model_|\.pt$/,"",$1); print $1" "$2}' \
    | sort -n | tail -1 | cut -d' ' -f2-)"
fi
[ -s "${CHECKPOINT_PATH}" ] || { printf '%s\n' "error=no_checkpoint"; exit 1; }
printf '%s\n' "stage=checkpoint_selected" "checkpoint_path=${CHECKPOINT_PATH}" \
  "checkpoint_sha256=$(sha256sum "${CHECKPOINT_PATH}" | awk '{print $1}')"

export CHECKPOINT_PATH RUN_DIR
export EVAL_ID="${RUN_ID}-levelsweep"
export TASK="${TASK}"
export COMMAND_X="${EVAL_COMMAND_X}"
export TYPES="${EVAL_TYPES}"
export TERRAIN_LEVEL="${TERRAIN_LEVEL:-0}"
printf '%s\n' "stage=eval_and_record" "eval_id=${EVAL_ID}"
bash "${SCRIPT_DIR}/eval_level_sweep_job.sh" || printf '%s\n' "stage=eval_failed"

printf '%s\n' "stage=complete" "log=${LOG}" \
  "video_dir=${DATA_ROOT}/media/${EVAL_ID}"
