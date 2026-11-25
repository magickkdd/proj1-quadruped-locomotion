#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/data/proj1}"
RUN_ID="${RUN_ID:-go2-rough-curriculum-3000-$(date +%Y%m%d-%H%M%S)}"
TASK="${TASK:-go2_ts}"
NUM_ENVS="${NUM_ENVS:-1024}"
MAX_ITERATIONS="${MAX_ITERATIONS:-3000}"

export DATA_ROOT RUN_ID TASK NUM_ENVS MAX_ITERATIONS
printf '%s\n' "experiment=go2_rough_curriculum" "task=${TASK}" "num_envs=${NUM_ENVS}" "max_iterations=${MAX_ITERATIONS}"
exec bash "$(dirname "$0")/train_job.sh"
