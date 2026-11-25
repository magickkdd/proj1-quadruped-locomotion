#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/data/proj1}"
RUN_ID="${RUN_ID:-go2-flat-baseline-20261122-140507}"
TASK="${TASK:-go2}"
NUM_ENVS="${NUM_ENVS:-4096}"
MAX_ITERATIONS="${MAX_ITERATIONS:-3000}"
LOAD_RUN="${LOAD_RUN:-Nov22_14-05-53_simple_rl_isaacgym}"
CHECKPOINT="${CHECKPOINT:-1500}"

export DATA_ROOT RUN_ID TASK NUM_ENVS MAX_ITERATIONS LOAD_RUN CHECKPOINT
export RESUME=1
printf '%s\n' \
  "experiment=resume_training" \
  "task=${TASK}" \
  "run_id=${RUN_ID}" \
  "load_run=${LOAD_RUN}" \
  "checkpoint=${CHECKPOINT}" \
  "target_iterations=${MAX_ITERATIONS}" \
  "num_envs=${NUM_ENVS}"
exec bash "$(dirname "$0")/train_job.sh"
