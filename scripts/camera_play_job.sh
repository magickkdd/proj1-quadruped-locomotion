#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/data/proj1}"
RUNTIME_ROOT="${RUNTIME_ROOT:-/tmp/proj1-runtime-camera}"
ENV_DIR="${RUNTIME_ROOT}/py38"
ENV_PACK="${ENV_PACK:-${DATA_ROOT}/env/isaacgym-py38.tar.gz}"
ISAAC_PY="${DATA_ROOT}/vendor/isaacgym/python"
REPO_DIR="${DATA_ROOT}/vendor/LeggedGym-Ex"
RUN_DIR="${RUN_DIR:-$(find "${DATA_ROOT}/runs" -maxdepth 1 -type d -name "${RUN_GLOB:-go2-flat-baseline-*}" | sort | tail -1)}"
MEDIA_DIR="${DATA_ROOT}/media"
FRAME_DIR="${FRAME_DIR:-${MEDIA_DIR}/go2-flat-camera-frames}"
VIDEO_PATH="${VIDEO_PATH:-${MEDIA_DIR}/go2-flat-baseline-camera.mp4}"
LOG_PATH="${LOG_PATH:-${MEDIA_DIR}/go2-flat-baseline-camera-play.log}"
APT_LOG="${MEDIA_DIR}/camera-apt.log"
TASK="${TASK:-go2}"
CHECKPOINT="${CHECKPOINT:-1500}"
FRAMES="${FRAMES:-900}"

mkdir -p "${MEDIA_DIR}"
exec > >(tee -a "${LOG_PATH}") 2>&1
printf '%s\n' "camera_play_package=camera_play_job_v3_quiet_apt"
printf '%s\n' "camera_play_start=$(date -Is 2>/dev/null || date)"
export DEBIAN_FRONTEND=noninteractive
command -v ffmpeg >/dev/null 2>&1 || {
  printf '%s\n' "apt_start=$(date -Is 2>/dev/null || date)" "apt_log=${APT_LOG}"
  apt-get update -qq >"${APT_LOG}" 2>&1
  apt-get install -y -qq --no-install-recommends ffmpeg >>"${APT_LOG}" 2>&1
  printf '%s\n' "apt_end=$(date -Is 2>/dev/null || date)"
}
[ -f "${ENV_PACK}" ] || { echo "缺少环境包：${ENV_PACK}"; exit 1; }
if [ ! -x "${ENV_DIR}/bin/python" ]; then
  rm -rf "${ENV_DIR}"
  mkdir -p "${ENV_DIR}"
  tar -xzf "${ENV_PACK}" -C "${ENV_DIR}"
  "${ENV_DIR}/bin/conda-unpack"
fi
[ -d "${ISAAC_PY}" ] || { echo "缺少 Isaac Gym：${ISAAC_PY}"; exit 1; }
[ -d "${REPO_DIR}" ] || { echo "缺少 LeggedGym-Ex：${REPO_DIR}"; exit 1; }
[ -d "${RUN_DIR}/logs" ] || { echo "缺少训练日志目录：${RUN_DIR}/logs"; exit 1; }
ln -sfn "${RUN_DIR}/logs" "${REPO_DIR}/logs"
TASK_LOG_DIR="${RUN_DIR}/logs/${TASK}"
RUN_NAME="$(find "${TASK_LOG_DIR}" -mindepth 1 -maxdepth 1 -type d | sort | tail -1 | xargs -r basename)"
[ -f "${TASK_LOG_DIR}/${RUN_NAME}/model_${CHECKPOINT}.pt" ] || { echo "找不到 checkpoint: ${TASK_LOG_DIR}/${RUN_NAME}/model_${CHECKPOINT}.pt"; exit 1; }
rm -rf "${FRAME_DIR}"
mkdir -p "${FRAME_DIR}"
export ENV_DIR SIMULATOR=isaacgym
export PYTHONPATH="${REPO_DIR}:${ISAAC_PY}:${PYTHONPATH:-}"
export LD_LIBRARY_PATH="${ENV_DIR}/lib:${ISAAC_PY}/isaacgym/_bindings/linux-x86_64:${LD_LIBRARY_PATH:-}"
printf '%s\n' "run_dir=${RUN_DIR}" "run_name=${RUN_NAME}" "checkpoint=${CHECKPOINT}" "frames=${FRAMES}" "video=${VIDEO_PATH}"
"${ENV_DIR}/bin/python" /code/workspace/scripts/camera_play.py \
  --task "${TASK}" --load_run "${RUN_NAME}" --ckpt "${CHECKPOINT}" \
  --frames "${FRAMES}" --out_dir "${FRAME_DIR}" --video "${VIDEO_PATH}"
printf '%s\n' "camera_play_end=$(date -Is 2>/dev/null || date)"
