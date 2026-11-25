#!/usr/bin/env bash
set -Eeuo pipefail
export TASK="go2_ts"
export CHECKPOINT="3000"
export RUN_GLOB="go2-rough-curriculum-3000-*"
export FRAME_DIR="${DATA_ROOT:-/data/proj1}/media/go2-rough-camera-frames"
export VIDEO_PATH="${DATA_ROOT:-/data/proj1}/media/go2-rough-curriculum-camera.mp4"
exec bash "$(dirname "$0")/camera_play_job.sh"
