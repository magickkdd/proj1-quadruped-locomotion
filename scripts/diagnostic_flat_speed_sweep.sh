#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/data/proj1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export RUN_GLOB="go2-flat-baseline-*"
export TASK="go2"
export CHECKPOINT="1500"
export EPISODES="10"
export NUM_ENVS="10"
export FRAMES="900"

for speed in 0.3 0.5 1.0; do
  export COMMAND_X="${speed}"
  export EVAL_ID="go2-flat-speed-${speed}"
  bash "${SCRIPT_DIR}/eval_and_record_job.sh"
done
