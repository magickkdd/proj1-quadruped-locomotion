#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data/proj1}"
ENV_PACK="${ENV_PACK:-${DATA_ROOT}/env/isaacgym-py38.tar.gz}"
RUNTIME_ROOT="${RUNTIME_ROOT:-/tmp/proj1-runtime-train}"
ENV_DIR="${RUNTIME_ROOT}/py38"
ISAAC_PY="${DATA_ROOT}/vendor/isaacgym/python"
REPO_DIR="${DATA_ROOT}/vendor/LeggedGym-Ex"

RUN_ID="${RUN_ID:-go2-staged-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_DIR="${DATA_ROOT}/runs/${RUN_ID}"
LOG="${DATA_ROOT}/results/${RUN_ID}.log"

NUM_ENVS="${NUM_ENVS:-4096}"
STAGE_ITERS="${STAGE_ITERS:-600}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
MAX_LEVEL="${MAX_LEVEL:-9}"
TARGET_LEN="${TARGET_LEN:-950}"
TARGET_TRACK="${TARGET_TRACK:-0.85}"
TASK="${TASK:-go2_ts}"

mkdir -p "${DATA_ROOT}/results" "${DATA_ROOT}/media" "${RUN_DIR}/logs"
exec > >(tee -a "${LOG}") 2>&1

printf '%s\n' \
  "staged_package=mastery_curriculum_v1" \
  "started_at=$(date -Is)" \
  "run_id=${RUN_ID}" \
  "task=${TASK}" \
  "num_envs=${NUM_ENVS}" \
  "stage_iters=${STAGE_ITERS}" \
  "max_attempts=${MAX_ATTEMPTS}" \
  "target_episode_length=${TARGET_LEN}" \
  "target_tracking_reward=${TARGET_TRACK}" \
  "log=${LOG}"

[ -f "${ENV_PACK}" ] || { printf '%s\n' "error=missing_env_pack" "path=${ENV_PACK}"; exit 1; }
[ -d "${REPO_DIR}" ] || { printf '%s\n' "error=missing_repo" "path=${REPO_DIR}"; exit 1; }

if ! ldconfig -p 2>/dev/null | grep -q 'libX11.so.6'; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/tmp/proj1-staged-apt.log 2>&1 || true
  apt-get install -y -qq --no-install-recommends \
    libx11-6 libxext6 libxrender1 libgl1 libglu1-mesa >>/tmp/proj1-staged-apt.log 2>&1 || true
fi

if [ ! -x "${ENV_DIR}/bin/python" ]; then
  printf '%s\n' "stage=env_unpack" "env_dir=${ENV_DIR}"
  rm -rf "${ENV_DIR}"
  mkdir -p "${ENV_DIR}"
  tar -xzf "${ENV_PACK}" -C "${ENV_DIR}"
  "${ENV_DIR}/bin/conda-unpack"
fi

export ENV_DIR DATA_ROOT REPO_DIR ISAAC_PY
export SIMULATOR=isaacgym
export PYTHONPATH="${REPO_DIR}:${ISAAC_PY}:${SCRIPT_DIR}:${PYTHONPATH:-}"
export LD_LIBRARY_PATH="${ENV_DIR}/lib:${ISAAC_PY}/isaacgym/_bindings/linux-x86_64:${LD_LIBRARY_PATH:-}"
export PYTHONUNBUFFERED=1

if [ -e "${REPO_DIR}/logs" ] && [ ! -L "${REPO_DIR}/logs" ]; then
  cp -a "${REPO_DIR}/logs/." "${RUN_DIR}/logs/" 2>/dev/null || true
  rm -rf "${REPO_DIR}/logs"
fi
ln -sfn "${RUN_DIR}/logs" "${REPO_DIR}/logs"

RESUME_ARGS=()
LATEST_RUN=""
LATEST_CKPT=""

find_latest_stage() {
  local newest_dir
  newest_dir="$(find "${RUN_DIR}/logs/${EXPERIMENT_NAME:-go2_rough}" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -1 | cut -d' ' -f2-)"
  [ -n "${newest_dir}" ] || return 1
  local newest_ckpt
  newest_ckpt="$(find "${newest_dir}" -maxdepth 1 -name 'model_*.pt' -size +0c -printf '%f\n' 2>/dev/null \
    | sed -E 's/^model_([0-9]+)\.pt$/\1/' | sort -n | tail -1)"
  [ -n "${newest_ckpt}" ] || return 1
  LATEST_RUN="$(basename "${newest_dir}")"
  LATEST_CKPT="${newest_ckpt}"
}

measure_stage() {
  local stage_log="$1"
  LEN_AVG="$(grep -a 'Mean episode length' "${stage_log}" 2>/dev/null | tail -20 \
    | awk '{s+=$NF; n++} END{if(n>0) printf "%.1f", s/n; else printf "0"}')"
  TRACK_AVG="$(grep -a 'Mean episode rew_tracking_lin_vel' "${stage_log}" 2>/dev/null | tail -20 \
    | awk '{s+=$NF; n++} END{if(n>0) printf "%.4f", s/n; else printf "0"}')"
  TERRAIN_AVG="$(grep -a 'Mean episode terrain_level' "${stage_log}" 2>/dev/null | tail -20 \
    | awk '{s+=$NF; n++} END{if(n>0) printf "%.4f", s/n; else printf "-1"}')"
  MASTERED="$(awk -v l="${LEN_AVG}" -v t="${TRACK_AVG}" -v L="${TARGET_LEN}" -v T="${TARGET_TRACK}" \
    'BEGIN{print (l+0 >= L+0 && t+0 >= T+0) ? "1" : "0"}')"
}

LEVEL="${START_LEVEL:-0}"
STALLED=0
while [ "${LEVEL}" -le "${MAX_LEVEL}" ]; do
  ATTEMPT=1
  LEVEL_DONE=0
  while [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; do
    STAGE_LOG="${RUN_DIR}/stage_level${LEVEL}_attempt${ATTEMPT}.log"
    export PIN_TERRAIN_LEVEL="${LEVEL}"
    printf '%s\n' "stage=train_stage" "level=${LEVEL}" "attempt=${ATTEMPT}" \
      "stage_iters=${STAGE_ITERS}" "pinned_level_env=${PIN_TERRAIN_LEVEL}" \
      "stage_log=${STAGE_LOG}"

    set +e
    if [ "${#RESUME_ARGS[@]}" -eq 0 ]; then
      "${ENV_DIR}/bin/python" "${SCRIPT_DIR}/train_stage.py" \
        --task "${TASK}" --headless --num_envs "${NUM_ENVS}" \
        --max_iterations "${STAGE_ITERS}" 2>&1 | tee "${STAGE_LOG}"
    else
      "${ENV_DIR}/bin/python" "${SCRIPT_DIR}/train_stage.py" \
        --task "${TASK}" --headless --num_envs "${NUM_ENVS}" \
        --max_iterations "${STAGE_ITERS}" \
        --resume --load_run "${LATEST_RUN}" --ckpt "${LATEST_CKPT}" 2>&1 | tee "${STAGE_LOG}"
    fi
    STAGE_EXIT=${PIPESTATUS[0]}
    set -e

    if [ "${STAGE_EXIT}" -ne 0 ]; then
      printf '%s\n' "stage=train_stage_failed" "level=${LEVEL}" "exit=${STAGE_EXIT}"
      ATTEMPT=$((ATTEMPT + 1))
      continue
    fi

    if ! grep -aq "pinned_terrain_level=${LEVEL}" "${STAGE_LOG}"; then
      printf '%s\n' "stage=pin_failed" "level=${LEVEL}" \
        "reason=pinned_level_not_applied" "stage_log=${STAGE_LOG}"
      exit 1
    fi

    if ! find_latest_stage; then
      printf '%s\n' "stage=checkpoint_missing" "level=${LEVEL}"
      ATTEMPT=$((ATTEMPT + 1))
      continue
    fi
    RESUME_ARGS=(--resume --load_run "${LATEST_RUN}" --ckpt "${LATEST_CKPT}")

    measure_stage "${STAGE_LOG}"
    printf '%s\n' "stage=stage_result" "level=${LEVEL}" "attempt=${ATTEMPT}" \
      "episode_length_avg=${LEN_AVG}" "tracking_reward_avg=${TRACK_AVG}" \
      "terrain_level_avg=${TERRAIN_AVG}" \
      "mastered=${MASTERED}" "run=${LATEST_RUN}" "ckpt=${LATEST_CKPT}"

    if [ "${TERRAIN_AVG}" != "-1" ] && awk -v a="${TERRAIN_AVG}" -v b="${LEVEL}" 'BEGIN{exit (a-b>0.1 || b-a>0.1) ? 0 : 1}'; then
      printf '%s\n' "stage=pin_drift" "level=${LEVEL}" "terrain_level_avg=${TERRAIN_AVG}"
      exit 1
    fi

    if [ "${MASTERED}" = "1" ]; then
      LEVEL_DONE=1
      break
    fi
    ATTEMPT=$((ATTEMPT + 1))
  done

  if [ "${LEVEL_DONE}" -ne 1 ]; then
    STALLED=1
    printf '%s\n' "stage=level_stalled" "level=${LEVEL}" \
      "reason=mastery_not_reached" "attempts=${MAX_ATTEMPTS}" \
      "episode_length_avg=${LEN_AVG:-0}" "tracking_reward_avg=${TRACK_AVG:-0}"
    break
  fi

  printf '%s\n' "stage=level_mastered" "level=${LEVEL}" "run=${LATEST_RUN}" "ckpt=${LATEST_CKPT}"
  LEVEL=$((LEVEL + 1))
done

printf '%s\n' "stage=train_finished" "final_level=$((LEVEL - 1))" "stalled=${STALLED}" \
  "final_run=${LATEST_RUN}" "final_ckpt=${LATEST_CKPT}"

if [ -n "${LATEST_RUN}" ] && [ -n "${LATEST_CKPT}" ]; then
  FINAL_CKPT_PATH="${RUN_DIR}/logs/${EXPERIMENT_NAME:-go2_rough}/${LATEST_RUN}/model_${LATEST_CKPT}.pt"
  printf '%s\n' "stage=start_eval" "checkpoint_path=${FINAL_CKPT_PATH}"
  export RUN_DIR CHECKPOINT_PATH="${CHECKPOINT_PATH:-${FINAL_CKPT_PATH}}"
  export EVAL_ID="${RUN_ID}-levelsweep"
  export COMMAND_X="${COMMAND_X:-0.4}"
  export FRAME_STRIDE="${FRAME_STRIDE:-5}"
  export FPS="${FPS:-20}"
  export MAX_STEPS="${MAX_STEPS:-12000}"
  bash "${SCRIPT_DIR}/eval_level_sweep_job.sh" || printf '%s\n' "stage=eval_failed"
fi

printf '%s\n' "stage=complete" "log=${LOG}"
