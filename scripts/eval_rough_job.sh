#!/usr/bin/env bash
set -Eeuo pipefail
export EVAL_ID="go2-rough-eval"
export RUN_GLOB="go2-rough-curriculum-3000-*"
export TASK="go2_ts"
export CHECKPOINT="3000"
exec bash "$(dirname "$0")/eval_and_record_job.sh"
