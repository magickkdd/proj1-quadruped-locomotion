#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/data/proj1}"
REPO_DIR="${REPO_DIR:-${DATA_ROOT}/vendor/LeggedGym-Ex}"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
OUT_DIR="${DATA_ROOT}/results/source-dump/${STAMP}"
LOG="${DATA_ROOT}/results/source-dump-${STAMP}.log"
ARCHIVE="${OUT_DIR}/leggedgym-src.tar.gz"

mkdir -p "${OUT_DIR}" "${DATA_ROOT}/results"
exec > >(tee -a "${LOG}") 2>&1

printf '%s\n' \
  "source_dump_package=leggedgym_source_v1" \
  "started_at=$(date -Is)" \
  "repo_dir=${REPO_DIR}" \
  "out_dir=${OUT_DIR}" \
  "log=${LOG}"

[ -d "${REPO_DIR}/legged_gym" ] || {
  printf '%s\n' "error=repo_not_found" "path=${REPO_DIR}"
  find "${DATA_ROOT}" -maxdepth 3 -type d -name 'legged_gym' 2>/dev/null | head -10 || true
  exit 1
}

printf '%s\n' "stage=repo_state"
{
  printf '%s\n' "commit=$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
  printf '%s\n' "describe=$(git -C "${REPO_DIR}" describe --always --dirty 2>/dev/null || echo unknown)"
  printf '%s\n' "--- git status ---"
  git -C "${REPO_DIR}" status --porcelain 2>/dev/null || true
} > "${OUT_DIR}/repo_state.txt"
cat "${OUT_DIR}/repo_state.txt"

printf '%s\n' "stage=collect_python"
cd "${REPO_DIR}"
find . -name '*.py' \
  -not -path './.git/*' \
  -not -path './.torch_extensions/*' \
  -not -path './assets/*' \
  -print0 2>/dev/null | tar --null -czf "${ARCHIVE}" --files-from=- 2>/dev/null
printf '%s\n' "archive=${ARCHIVE}" "archive_bytes=$(wc -c < "${ARCHIVE}")" \
  "archive_sha256=$(sha256sum "${ARCHIVE}" | awk '{print $1}')"

printf '%s\n' "stage=grep_report"
{
  printf '%s\n' '### _update_terrain_curriculum'
  grep -rn "_update_terrain_curriculum" --include='*.py' . 2>/dev/null || true
  printf '%s\n' ''
  printf '%s\n' '### terrain_levels / max_init_terrain_level'
  grep -rn "terrain_levels\|max_init_terrain_level" --include='*.py' . 2>/dev/null || true
  printf '%s\n' ''
  printf '%s\n' '### make_env / make_alg_runner'
  grep -rn "def make_env\|def make_alg_runner\|def get_cfgs" --include='*.py' . 2>/dev/null || true
  printf '%s\n' ''
  printf '%s\n' '### terrain init / origins'
  grep -rn "_get_env_origins\|terrain_origins\|randint(0, self.cfg.terrain" --include='*.py' . 2>/dev/null || true
} > "${OUT_DIR}/grep_report.txt"

printf '%s\n' "stage=config_snapshot"
{
  for rel in \
    legged_gym/envs/base/legged_robot_config.py \
    legged_gym/envs/base/common_cfgs.py \
    legged_gym/utils/terrain.py; do
    [ -f "${rel}" ] || continue
    printf '%s\n' "===== ${rel} ====="
    grep -nE "num_rows|num_cols|terrain_proportions|max_init_terrain_level|terrain_curriculum_difficulty|step_height|slope|curriculum|max_curriculum|lin_vel_x|episode_length_s" "${rel}" 2>/dev/null || true
    printf '%s\n' ''
  done
} > "${OUT_DIR}/config_snapshot.txt"
cat "${OUT_DIR}/config_snapshot.txt"

printf '%s\n' "stage=go2_files"
find legged_gym/envs/go2 -name '*.py' -printf '%p\n' | sort > "${OUT_DIR}/go2_files.txt"
cat "${OUT_DIR}/go2_files.txt"

printf '%s\n' "stage=complete" "out_dir=${OUT_DIR}"
printf '%s\n' "download_archive=${ARCHIVE}"
printf '%s\n' "download_grep=${OUT_DIR}/grep_report.txt"
printf '%s\n' "download_config=${OUT_DIR}/config_snapshot.txt"
printf '%s\n' "download_repo_state=${OUT_DIR}/repo_state.txt"
