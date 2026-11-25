#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/data/proj1}"
REPO_DIR="${REPO_DIR:-${DATA_ROOT}/vendor/LeggedGym-Ex}"
ISAAC_PY="${ISAAC_PY:-${DATA_ROOT}/vendor/isaacgym/python}"
RUN_ID="${RUN_ID:-go2-rough-curriculum-smoke-$(date +%Y%m%d-%H%M%S)}"
RUN_DIR="${DATA_ROOT}/runs/${RUN_ID}"
TASK="${TASK:-go2_ts}"
NUM_ENVS="${NUM_ENVS:-1024}"
MAX_ITERATIONS="${MAX_ITERATIONS:-100}"
if [ "${MAX_ITERATIONS}" -lt 500 ] && [ "${ALLOW_SMOKE_TEST:-0}" != "1" ]; then
  printf '%s\n' "refuse_smoke_test=max_iterations_${MAX_ITERATIONS}" \
    "hint=export MAX_ITERATIONS or set ALLOW_SMOKE_TEST=1" >&2
  exit 1
fi
RESUME="${RESUME:-0}"
LOAD_RUN="${LOAD_RUN:-}"
CHECKPOINT="${CHECKPOINT:-}"
RESTORE_GO2_CONFIG=0

mkdir -p "${RUN_DIR}/logs" "${RUN_DIR}/checkpoints" "${RUN_DIR}/tb"
cd "${REPO_DIR}"

export SIMULATOR=isaacgym
export PYTHONPATH="${REPO_DIR}:${ISAAC_PY}:${PYTHONPATH:-}"
export LD_LIBRARY_PATH="${ENV_DIR}/lib:${ISAAC_PY}/isaacgym/_bindings/linux-x86_64:${LD_LIBRARY_PATH:-}"
export RSL_RL_ROOT_DIR="${REPO_DIR}/rsl_rl"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-8}"
export MKL_NUM_THREADS="${MKL_NUM_THREADS:-8}"

if [ -z "${ENV_DIR:-}" ] || [ ! -x "${ENV_DIR}/bin/python" ]; then
  printf '%s\n' "缺少 ENV_DIR 或 Python 环境不可执行" >&2
  exit 1
fi

if [ ! -f "${ISAAC_PY}/setup.py" ]; then
  printf '%s\n' "缺少 Isaac Gym Python 包：${ISAAC_PY}" >&2
  exit 1
fi

if [ -e "${REPO_DIR}/logs" ] && [ ! -L "${REPO_DIR}/logs" ]; then
  cp -a "${REPO_DIR}/logs/." "${RUN_DIR}/logs/" 2>/dev/null || true
  rm -rf "${REPO_DIR}/logs"
fi
ln -sfn "${RUN_DIR}/logs" "${REPO_DIR}/logs"

printf '%s\n' "run_id=${RUN_ID}" | tee "${RUN_DIR}/run.env"
printf '%s\n' "task=${TASK}" | tee -a "${RUN_DIR}/run.env"
printf '%s\n' "num_envs=${NUM_ENVS}" | tee -a "${RUN_DIR}/run.env"
printf '%s\n' "max_iterations=${MAX_ITERATIONS}" | tee -a "${RUN_DIR}/run.env"
printf '%s\n' "resume=${RESUME}" | tee -a "${RUN_DIR}/run.env"
printf '%s\n' "load_run=${LOAD_RUN}" | tee -a "${RUN_DIR}/run.env"
printf '%s\n' "checkpoint=${CHECKPOINT}" | tee -a "${RUN_DIR}/run.env"
printf '%s\n' "repo_commit=$(git -C "${REPO_DIR}" rev-parse HEAD)" | tee -a "${RUN_DIR}/run.env"
printf '%s\n' "started_at=$(date -Is)" | tee -a "${RUN_DIR}/run.env"

if [ "${FLAT_DIAGNOSTIC_CONFIG:-0}" = "1" ]; then
  printf '%s\n' "flat_diagnostic_config=1" "randomize_friction=false" "randomize_base_mass=false" "randomize_com_displacement=false" "push_robots=false" "joint_reset_noise=disabled_by_source_patch" "heading_command=false" | tee -a "${RUN_DIR}/run.env"
  for config in \
    "${REPO_DIR}/legged_gym/envs/go2/go2.py" \
    "${REPO_DIR}/legged_gym/envs/go2/go2_config.py"; do
    [ -f "${config}" ] || continue
    cp "${config}" "${RUN_DIR}/$(basename "${config}").original"
  done
  RESTORE_GO2_CONFIG=1
  restore_go2_config() {
    cp "${RUN_DIR}/go2.py.original" "${REPO_DIR}/legged_gym/envs/go2/go2.py" 2>/dev/null || true
    cp "${RUN_DIR}/go2_config.py.original" "${REPO_DIR}/legged_gym/envs/go2/go2_config.py" 2>/dev/null || true
  }
  trap restore_go2_config EXIT
  "${ENV_DIR}/bin/python" - "${REPO_DIR}/legged_gym/envs/go2/go2.py" "${REPO_DIR}/legged_gym/envs/go2/go2_config.py" <<'PY'
import pathlib
import sys

robot = pathlib.Path(sys.argv[1])
config = pathlib.Path(sys.argv[2])
if not robot.is_file() or not config.is_file():
    raise SystemExit("Go2 config files not found")
source = robot.read_text()
source = source.replace("torch_rand_float(-0.2, 0.2, (len(env_ids), 4), self.device)", "torch.zeros((len(env_ids), 4), device=self.device)", 1)
source = source.replace("torch_rand_float(-0.4, 0.4, (len(env_ids), 4), self.device)", "torch.zeros((len(env_ids), 4), device=self.device)", 2)
if "torch_rand_float(-0.2, 0.2, (len(env_ids), 4), self.device)" in source or "torch_rand_float(-0.4, 0.4, (len(env_ids), 4), self.device)" in source:
    raise SystemExit("joint reset patch did not fully apply")
robot.write_text(source)
source = config.read_text()
source = source.replace("        randomize_friction = True", "        randomize_friction = False")
source = source.replace("        randomize_base_mass = True", "        randomize_base_mass = False")
source = source.replace("        push_robots = True", "        push_robots = False")
source = source.replace("        randomize_com_displacement = True", "        randomize_com_displacement = False")
source = source.replace("        heading_command = True", "        heading_command = False")
for needle in (
    "        randomize_friction = False",
    "        randomize_base_mass = False",
    "        push_robots = False",
    "        randomize_com_displacement = False",
    "        heading_command = False",
):
    if needle not in source:
        raise SystemExit("configuration patch did not apply: " + needle)
config.write_text(source)
PY
  cp "${REPO_DIR}/legged_gym/envs/go2/go2.py" "${RUN_DIR}/go2.py.effective"
  cp "${REPO_DIR}/legged_gym/envs/go2/go2_config.py" "${RUN_DIR}/go2_config.py.effective"
fi

sync_tensorboard() {
  if [ -n "${TENSORBOARD_LOGDIR:-}" ] && [ -d "${TENSORBOARD_LOGDIR}" ]; then
    find "${RUN_DIR}/logs" -type f \( -name 'events.out.tfevents.*' -o -name '*.tfevents.*' \) -exec cp -f {} "${TENSORBOARD_LOGDIR}/" \; 2>/dev/null || true
  fi
}

cleanup() {
  sync_tensorboard
  if [ "${RESTORE_GO2_CONFIG}" = "1" ]; then
    cp "${RUN_DIR}/go2.py.original" "${REPO_DIR}/legged_gym/envs/go2/go2.py" 2>/dev/null || true
    cp "${RUN_DIR}/go2_config.py.original" "${REPO_DIR}/legged_gym/envs/go2/go2_config.py" 2>/dev/null || true
  fi
  printf '%s\n' "finished_at=$(date -Is)" >> "${RUN_DIR}/run.env"
}
trap cleanup EXIT

"${ENV_DIR}/bin/python" -c 'import isaacgym; import torch; print("isaacgym_import=ok"); print("torch_version=" + torch.__version__); print("cuda_available=" + str(torch.cuda.is_available()))'
TRAIN_ARGS=(
  --task "${TASK}"
  --headless
  --num_envs "${NUM_ENVS}"
  --max_iterations "${MAX_ITERATIONS}"
)
if [ "${RESUME}" = "1" ]; then
  [ -n "${LOAD_RUN}" ] || { printf '%s\n' "续训缺少 LOAD_RUN" >&2; exit 1; }
  [ -n "${CHECKPOINT}" ] || { printf '%s\n' "续训缺少 CHECKPOINT" >&2; exit 1; }
  TRAIN_ARGS+=(--resume --load_run "${LOAD_RUN}" --ckpt "${CHECKPOINT}")
fi
printf '%s\n' "train_command=python -m legged_gym.scripts.train ${TRAIN_ARGS[*]}"
"${ENV_DIR}/bin/python" -m legged_gym.scripts.train "${TRAIN_ARGS[@]}"
sync_tensorboard
