#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data/proj1}"
ENV_PACK="${ENV_PACK:-${DATA_ROOT}/env/isaacgym-py38.tar.gz}"
RUNTIME_ROOT="${RUNTIME_ROOT:-/tmp/proj1-runtime-eval}"
ENV_DIR="${RUNTIME_ROOT}/py38"
ISAAC_PY="${DATA_ROOT}/vendor/isaacgym/python"
REPO_DIR="${DATA_ROOT}/vendor/LeggedGym-Ex"

EVAL_ID="${EVAL_ID:-go2-levelsweep-$(date +%Y%m%d-%H%M%S)-$$}"
LOG="${DATA_ROOT}/results/${EVAL_ID}.log"
OUT_DIR="${DATA_ROOT}/media/${EVAL_ID}"
CHECKPOINT_PATH="${CHECKPOINT_PATH:-}"

mkdir -p "${DATA_ROOT}/results" "${DATA_ROOT}/media" "${OUT_DIR}"
exec > >(tee -a "${LOG}") 2>&1

printf '%s\n' "eval_package=level_sweep_v1" "eval_id=${EVAL_ID}" \
  "checkpoint_path=${CHECKPOINT_PATH}" "out_dir=${OUT_DIR}" "log=${LOG}"

if [ -z "${CHECKPOINT_PATH}" ] || [ ! -s "${CHECKPOINT_PATH}" ]; then
  printf '%s\n' "error=missing_checkpoint" "path=${CHECKPOINT_PATH}"
  exit 1
fi
CHECKPOINT="$(basename "${CHECKPOINT_PATH}" | sed -E 's/^model_([0-9]+)\.pt$/\1/')"
RUN_NAME="$(basename "$(dirname "${CHECKPOINT_PATH}")")"
printf '%s\n' "checkpoint=${CHECKPOINT}" "run_name=${RUN_NAME}"

export DEBIAN_FRONTEND=noninteractive
if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v Xvfb >/dev/null 2>&1; then
  printf '%s\n' "stage=apt_install"
  apt-get update -qq >/tmp/proj1-levelsweep-apt.log 2>&1 || true
  apt-get install -y -qq --no-install-recommends \
    ffmpeg xvfb libgl1 libglu1-mesa libx11-6 libxext6 libxrender1 \
    >>/tmp/proj1-levelsweep-apt.log 2>&1 || true
fi

export DISPLAY="${DISPLAY:-:99}"
Xvfb "${DISPLAY}" -screen 0 1280x720x24 -ac >/tmp/proj1-levelsweep-xvfb.log 2>&1 &
XVFB_PID=$!
trap 'kill "${XVFB_PID}" 2>/dev/null || true' EXIT
sleep 1
printf '%s\n' "stage=xvfb_ready" "display=${DISPLAY}"

if [ ! -x "${ENV_DIR}/bin/python" ]; then
  printf '%s\n' "stage=env_unpack" "env_dir=${ENV_DIR}"
  rm -rf "${ENV_DIR}"
  mkdir -p "${ENV_DIR}"
  tar -xzf "${ENV_PACK}" -C "${ENV_DIR}"
  "${ENV_DIR}/bin/conda-unpack"
fi

export ENV_DIR SIMULATOR=isaacgym
export PYTHONPATH="${REPO_DIR}:${ISAAC_PY}:${SCRIPT_DIR}:${PYTHONPATH:-}"
export LD_LIBRARY_PATH="${ENV_DIR}/lib:${ISAAC_PY}/isaacgym/_bindings/linux-x86_64:${LD_LIBRARY_PATH:-}"
export PYTHONUNBUFFERED=1

run_check_dir() {
  [ -d "${ISAAC_PY}" ] || { printf '%s\n' "error=missing_isaacgym" "path=${ISAAC_PY}"; return 1; }
  [ -d "${REPO_DIR}" ] || { printf '%s\n' "error=missing_repo" "path=${REPO_DIR}"; return 1; }
}
run_check_dir || exit 1

LOGS_ROOT="$(dirname "$(dirname "$(dirname "${CHECKPOINT_PATH}")")")"
if [ -d "${LOGS_ROOT}" ]; then
  rm -f "${REPO_DIR}/logs"
  ln -s "${LOGS_ROOT}" "${REPO_DIR}/logs" 2>/dev/null || true
fi

printf '%s\n' "stage=before_python" "task=${TASK:-go2_ts}" "command_x=${COMMAND_X:-0.4}"
"${ENV_DIR}/bin/python" "${SCRIPT_DIR}/eval_level_sweep.py" \
  --task "${TASK:-go2_ts}" \
  --load_run "${RUN_NAME}" \
  --ckpt "${CHECKPOINT}" \
  --checkpoint_path "${CHECKPOINT_PATH}" \
  --command_x "${COMMAND_X:-0.4}" \
  --max_steps "${MAX_STEPS:-12000}" \
  --frame_stride "${FRAME_STRIDE:-5}" \
  --fps "${FPS:-20}" \
  --out_dir "${OUT_DIR}" \
  --types "${TYPES:-0,1,2,3,4,5,6,7,8,9}" \
  --level "${TERRAIN_LEVEL:-0}"

printf '%s\n' "stage=complete" "out_dir=${OUT_DIR}"
