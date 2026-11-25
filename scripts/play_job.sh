#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/data/proj1}"
RUNTIME_ROOT="${RUNTIME_ROOT:-/tmp/proj1-runtime}"
ENV_DIR="${RUNTIME_ROOT}/py38"
ENV_PACK="${ENV_PACK:-${DATA_ROOT}/env/isaacgym-py38.tar.gz}"
ISAAC_PY="${DATA_ROOT}/vendor/isaacgym/python"
REPO_DIR="${DATA_ROOT}/vendor/LeggedGym-Ex"
RUN_DIR="${RUN_DIR:-$(find "${DATA_ROOT}/runs" -maxdepth 1 -type d -name 'go2-flat-baseline-*' | sort | tail -1)}"
MEDIA_DIR="${DATA_ROOT}/media"
VIDEO_PATH="${VIDEO_PATH:-${MEDIA_DIR}/go2-flat-baseline.mp4}"
TASK="${TASK:-go2}"
CHECKPOINT="${CHECKPOINT:-1500}"
PLAY_SECONDS="${PLAY_SECONDS:-40}"
PLAY_LOG="${MEDIA_DIR}/go2-flat-baseline-play.log"
LAUNCH_LOG="${MEDIA_DIR}/play_launcher.log"
APT_MARKER="${MEDIA_DIR}/play-apt.done"

mkdir -p "${MEDIA_DIR}"
printf '%s\n' "launcher_seen=$(date -Is 2>/dev/null || date)" >> "${LAUNCH_LOG}"
printf '%s\n' "script=$0" "cwd=$PWD" "user=$(id -un 2>/dev/null || true)" >> "${LAUNCH_LOG}"
exec > >(tee -a "${PLAY_LOG}") 2>&1
printf '%s\n' "play_job_start=$(date -Is 2>/dev/null || date)"
printf '%s\n' "play_log=${PLAY_LOG}" "launch_log=${LAUNCH_LOG}" >> "${LAUNCH_LOG}"
if [ ! -f "${APT_MARKER}" ] || ! command -v Xvfb >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ffmpeg xvfb libx11-6 libx11-xcb1 libxcb1 libxext6 libxfixes3 libxrender1 \
    libxrandr2 libxinerama1 libxcursor1 libxi6 libxxf86vm1 libsm6 libice6 \
    libgl1 libglu1-mesa libegl1 libvulkan1 mesa-vulkan-drivers vulkan-tools
  touch "${APT_MARKER}"
fi
command -v Xvfb >/dev/null 2>&1 || { printf '%s\n' "缺少 Xvfb" >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { printf '%s\n' "缺少 ffmpeg" >&2; exit 1; }
[ -f "${ENV_PACK}" ] || { printf '%s\n' "缺少环境包：${ENV_PACK}" >&2; exit 1; }
if [ ! -x "${ENV_DIR}/bin/python" ]; then
  rm -rf "${ENV_DIR}"
  mkdir -p "${ENV_DIR}"
  tar -xzf "${ENV_PACK}" -C "${ENV_DIR}"
  "${ENV_DIR}/bin/conda-unpack"
fi
[ -x "${ENV_DIR}/bin/python" ] || { printf '%s\n' "环境包解包后 Python 不可执行：${ENV_DIR}" >&2; exit 1; }
[ -d "${ISAAC_PY}" ] || { printf '%s\n' "缺少 Isaac Gym：${ISAAC_PY}" >&2; exit 1; }
[ -d "${REPO_DIR}" ] || { printf '%s\n' "缺少 LeggedGym-Ex：${REPO_DIR}" >&2; exit 1; }
[ -d "${RUN_DIR}/logs" ] || { printf '%s\n' "缺少平地训练日志目录：${RUN_DIR}/logs" >&2; exit 1; }

export ENV_DIR
export SIMULATOR=isaacgym
export PYTHONPATH="${REPO_DIR}:${ISAAC_PY}:${PYTHONPATH:-}"
export LD_LIBRARY_PATH="${ENV_DIR}/lib:${ISAAC_PY}/isaacgym/_bindings/linux-x86_64:${LD_LIBRARY_PATH:-}"

LOG_LINK="${REPO_DIR}/logs"
if [ -e "${LOG_LINK}" ] && [ ! -L "${LOG_LINK}" ]; then
  rm -rf "${LOG_LINK}"
fi
ln -sfn "${RUN_DIR}/logs" "${LOG_LINK}"

RUN_NAME="$(find "${RUN_DIR}/logs/go2" -mindepth 1 -maxdepth 1 -type d | sort | tail -1 | xargs -r basename)"
[ -n "${RUN_NAME}" ] || { printf '%s\n' "找不到 go2 checkpoint 目录：${RUN_DIR}/logs/go2" >&2; exit 1; }
[ -f "${RUN_DIR}/logs/go2/${RUN_NAME}/model_${CHECKPOINT}.pt" ] || {
  printf '%s\n' "找不到 checkpoint：${RUN_DIR}/logs/go2/${RUN_NAME}/model_${CHECKPOINT}.pt" >&2
  exit 1
}

printf '%s\n' "run_dir=${RUN_DIR}" "task=${TASK}" "run_name=${RUN_NAME}" "checkpoint=${CHECKPOINT}" "video=${VIDEO_PATH}"

DISPLAY_NUM=":99"
export DISPLAY="${DISPLAY_NUM}"
Xvfb "${DISPLAY_NUM}" -screen 0 1280x720x24 -ac +extension GLX +render -noreset >/tmp/proj1-xvfb.log 2>&1 &
XVFB_PID=$!
cleanup() {
  kill "${PLAY_PID:-}" 2>/dev/null || true
  kill "${FFMPEG_PID:-}" 2>/dev/null || true
  kill "${XVFB_PID}" 2>/dev/null || true
}
trap cleanup EXIT
sleep 2

ffmpeg -hide_banner -loglevel error -y \
  -f x11grab -video_size 1280x720 -framerate 30 -i "${DISPLAY_NUM}" \
  -t "${PLAY_SECONDS}" -c:v libx264 -preset veryfast -pix_fmt yuv420p "${VIDEO_PATH}" >/tmp/proj1-ffmpeg.log 2>&1 &
FFMPEG_PID=$!

set +e
timeout "$((PLAY_SECONDS + 15))" "${ENV_DIR}/bin/python" "${REPO_DIR}/legged_gym/scripts/play.py" \
  --task "${TASK}" \
  --viewer native \
  --load_run "${RUN_NAME}" \
  --ckpt "${CHECKPOINT}" \
  --follow_robot &
PLAY_PID=$!
wait "${PLAY_PID}"
PLAY_RC=$?
set -e

wait "${FFMPEG_PID}" || true
if [ ! -s "${VIDEO_PATH}" ]; then
  printf '%s\n' "视频没有生成：${VIDEO_PATH}" >&2
  cat /tmp/proj1-xvfb.log /tmp/proj1-ffmpeg.log >&2 || true
  exit 1
fi
printf '%s\n' "video_ready=${VIDEO_PATH}" "play_rc=${PLAY_RC}" "play_job_end=$(date -Is 2>/dev/null || date)"
