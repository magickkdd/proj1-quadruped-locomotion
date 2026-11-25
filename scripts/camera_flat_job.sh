#!/usr/bin/env bash
set -Eeuo pipefail
export TASK="go2"
export CHECKPOINT="1500"
export RUN_GLOB="go2-flat-baseline-*"
export FRAME_DIR="${DATA_ROOT:-/data/proj1}/media/go2-flat-camera-frames"
export VIDEO_PATH="${DATA_ROOT:-/data/proj1}/media/go2-flat-baseline-camera.mp4"
exec bash "$(dirname "$0")/camera_play_job.sh"
