#!/usr/bin/env bash
set -Eeuo pipefail
export EVAL_ID="go2-flat-eval"
export RUN_GLOB="go2-flat-baseline-*"
export TASK="go2"
export CHECKPOINT="1500"
exec bash "$(dirname "$0")/eval_and_record_job.sh"
