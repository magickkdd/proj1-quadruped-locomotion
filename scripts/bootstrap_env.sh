#!/usr/bin/env bash
# 项目一环境构建脚本（可恢复版）
# 用法：bash /code/workspace/bootstrap_env.sh
# 可选：FORCE=1 重建环境；FORCE_VENDOR=1 重新解压 Isaac Gym / 重新 clone 仓库
# 前置：IsaacGym_Preview_4_Package.tar.gz 或 .tar 已上传到 /data/proj1/env/
# 产物：/data/proj1/env/isaacgym-py38.tar.gz、env-lock、分阶段日志

set -Eeuo pipefail

# 最早的心跳：即使后续日志/tee 出问题，也能确认脚本是否真的被执行
echo "bootstrap_script_start=$(date -Is 2>/dev/null || date)"
mkdir -p /data/proj1/env 2>/dev/null || true
echo "script_start $(date -Is 2>/dev/null || date)" >> /data/proj1/env/bootstrap_launcher.log 2>/dev/null || true

TS="$(date +%Y%m%d-%H%M%S)"
SCRIPT_SHA="$(sha256sum "$0" | awk '{print $1}')"
DATA_ROOT="/data/proj1"
ENV_ROOT="${DATA_ROOT}/env"
BUILD_ROOT="${ENV_ROOT}/build"
ENV_DIR="${BUILD_ROOT}/py38"
STATE_DIR="${ENV_ROOT}/build-state"
ENV_PACK="${ENV_ROOT}/isaacgym-py38.tar.gz"
VENDOR_DIR="${DATA_ROOT}/vendor"
ISAAC_DIR="${VENDOR_DIR}/isaacgym"
REPO_URL="${REPO_URL:-https://github.com/lupinjia/LeggedGym-Ex.git}"
REPO_REF="${REPO_REF:-09283fe0e768274feb79eacacd72f1dd4175c142}"
REPO_DIR="${VENDOR_DIR}/LeggedGym-Ex"
LOG="${ENV_ROOT}/bootstrap_${TS}.log"
LATEST_LOG="${ENV_ROOT}/bootstrap_latest.log"
LOCKFILE="${ENV_ROOT}/.bootstrap.lock"

mkdir -p "${ENV_ROOT}" "${BUILD_ROOT}" "${STATE_DIR}" "${VENDOR_DIR}" \
  "${DATA_ROOT}/runs" "${DATA_ROOT}/results" "${DATA_ROOT}/media"
export PIP_CACHE_DIR="${BUILD_ROOT}/pip-cache"
export PIP_PROGRESS_BAR=off
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_INPUT=1
mkdir -p "${PIP_CACHE_DIR}"
# 平台日志采集器对超长单行敏感；把 \r 转成换行并关闭 pip 进度条，避免 bufio.Scanner 报 token too long
exec > >(sed -u 's/\r/\n/g' | tee -a "${LOG}") 2>&1
ln -sfn "${LOG}" "${LATEST_LOG}"

CURRENT_STAGE="init"
LIBPY_DIR=""
ISAAC_PY=""
REPO_COMMIT=""
TORCH_VER=""
ISAAC_VER=""

section() { printf '\n===== %s =====\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
mark_done() { printf '%s\n' "$(date -Is)" > "${STATE_DIR}/$1.done"; }
done_marker() { [ -f "${STATE_DIR}/$1.done" ]; }
invalidate_after_env_change() {
  rm -f "${ENV_PACK}" "${ENV_PACK}.sha256"
  rm -f "${STATE_DIR}/deps.done" "${STATE_DIR}/import.done" \
        "${STATE_DIR}/pack.done" "${STATE_DIR}/pack_verify.done" \
        "${STATE_DIR}/env_lock.done" "${STATE_DIR}/99-success.done"
  rm -f "${STATE_DIR}/deps.fingerprint" "${STATE_DIR}/pack.fingerprint"
}

trap 'rc=$?; trap - ERR; printf "\n[FAIL] stage=%s line=%s rc=%s\n" "${CURRENT_STAGE}" "${LINENO}" "${rc}"; printf "[FAIL] 命令：%s\n" "${BASH_COMMAND}"; printf "[FAIL] 日志：%s\n" "${LATEST_LOG}"; exit "${rc}"' ERR

ISAAC_TGZ="${ISAAC_TGZ:-}"
if [ -z "${ISAAC_TGZ}" ]; then
  for f in \
    "${ENV_ROOT}/IsaacGym_Preview_4_Package.tar.gz" \
    "${ENV_ROOT}/IsaacGym_Preview_4_Package.tar"; do
    if [ -f "$f" ]; then
      ISAAC_TGZ="$f"
      break
    fi
  done
fi

http_head() {
  curl -sS -I -L -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null || echo "ERR"
}

find_isaac_py() {
  if [ -f "${ISAAC_DIR}/python/setup.py" ]; then
    printf '%s\n' "${ISAAC_DIR}/python"
    return 0
  fi
  find "${VENDOR_DIR}" -maxdepth 4 -type f -path '*/isaacgym/python/setup.py' \
    | head -1 | xargs -r dirname
}

ensure_libpython_path() {
  local libpy
  libpy="$(find "${ENV_DIR}" -name 'libpython3.8.so.1.0' -print -quit)"
  [ -n "${libpy}" ] || fail "conda 环境缺少 libpython3.8.so.1.0"
  LIBPY_DIR="$(dirname "${libpy}")"
  export LD_LIBRARY_PATH="${LIBPY_DIR}:${LD_LIBRARY_PATH:-}"
}

show_disk() {
  df -h "${DATA_ROOT}" 2>/dev/null | tail -1 || true
  # JuiceFS 上 du 可能很慢；加超时，避免卡在统计目录大小
  timeout 5 du -sh "${BUILD_ROOT}" "${VENDOR_DIR}" 2>/dev/null || true
}

# ---------- 快速路径：上次已成功 ----------
if [ -f "${STATE_DIR}/99-success.done" ] \
   && [ "$(cat "${STATE_DIR}/99-success.done" 2>/dev/null || true)" = "${SCRIPT_SHA}" ] \
   && [ -f "${ENV_PACK}" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "===== 环境包已存在，且由当前版本脚本验证成功 ====="
  echo "环境包：${ENV_PACK}"
  sha256sum "${ENV_PACK}" 2>/dev/null || true
  echo "如需重建：FORCE=1 bash /code/workspace/bootstrap_env.sh"
  exit 0
fi

if [ "${FORCE:-0}" = "1" ]; then
  echo "===== FORCE=1：清理构建环境与阶段标记 ====="
  rm -rf "${ENV_DIR}" "${ENV_PACK}" "${STATE_DIR}"
  mkdir -p "${STATE_DIR}"
fi
if [ "${FORCE_VENDOR:-0}" = "1" ]; then
  echo "===== FORCE_VENDOR=1：清理 Isaac Gym 与 LeggedGym-Ex 源码 ====="
  rm -rf "${ISAAC_DIR}" "${REPO_DIR}"
fi

# ---------- 并发锁 ----------
if command -v flock >/dev/null 2>&1; then
  exec 9>"${LOCKFILE}"
  if ! flock -n 9; then
    fail "另一个 bootstrap 任务正在使用 ${ENV_ROOT}；先停止它再重跑"
  fi
else
  warn "系统没有 flock，跳过并发锁"
fi

# ---------- 阶段 0：预检 ----------
stage_preflight() {
  CURRENT_STAGE="preflight"
  section "0. 预检"
  info "start=$(date -Is)"
  info "user=$(id -un)"
  command -v nvidia-smi >/dev/null 2>&1 || fail "没有 nvidia-smi"
  nvidia-smi -L
  local gpu_mem
  gpu_mem="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1 || true)"
  info "gpu_memory=${gpu_mem}"
  case "${gpu_mem}" in
    *81920*) ;;
    *) warn "显存不是 80GB：${gpu_mem}；继续，但结果要记录实际规格" ;;
  esac

  command -v git >/dev/null 2>&1 || fail "没有 git"
  command -v conda >/dev/null 2>&1 || fail "没有 conda"
  command -v tar >/dev/null 2>&1 || fail "没有 tar"
  command -v curl >/dev/null 2>&1 || fail "没有 curl"
  command -v sha256sum >/dev/null 2>&1 || fail "没有 sha256sum"
  command -v file >/dev/null 2>&1 || warn "没有 file，跳过文件类型识别"

  mkdir -p "${ENV_ROOT}" "${STATE_DIR}" 2>/dev/null || fail "/data 不可写"
  printf 'write test %s\n' "$(date -Is)" > "${STATE_DIR}/write-test.txt" \
    || fail "/data/proj1/env 不可写"

  local free_gb
  free_gb="$(df -P -B1 "${DATA_ROOT}" | awk 'NR==2 {printf "%.1f", $4/1073741824}')"
  info "data_free_gb=${free_gb}"
  if awk -v g="${free_gb}" 'BEGIN {exit !(g < 18)}'; then
    fail "云盘可用空间不足 18GB（当前 ${free_gb}GB）；构建环境 + 环境包需要余量，先清理或申请扩容"
  fi

  if [ -z "${ISAAC_TGZ}" ] || [ ! -f "${ISAAC_TGZ}" ]; then
    echo "当前 ${ENV_ROOT} 内容："
    ls -lah "${ENV_ROOT}" || true
    fail "缺少 Isaac Gym 安装包；期望 IsaacGym_Preview_4_Package.tar.gz 或 .tar"
  fi
  info "isaac_package=${ISAAC_TGZ}"
  file "${ISAAC_TGZ}" 2>/dev/null || true
  tar -tf "${ISAAC_TGZ}" >/dev/null 2>&1 \
    || fail "Isaac Gym 安装包不可读或不是有效 tar/gzip：${ISAAC_TGZ}"

  local code
  code="$(http_head https://pypi.org/simple/)"
  info "pypi_http=${code}"
  case "${code}" in 200|301|302) ;; *) fail "PyPI 不可访问（${code}）" ;; esac
  code="$(http_head https://conda.anaconda.org/conda-forge/noarch/repodata.json)"
  info "conda_http=${code}"
  case "${code}" in 200|301|302) ;; *) fail "conda-forge 不可访问（${code}）" ;; esac
  code="$(http_head https://download.pytorch.org/whl/cu121/)"
  info "pytorch_http=${code}"
  case "${code}" in 200|301|302) ;; *) fail "PyTorch wheel 源不可访问（${code}）" ;; esac

  if [ ! -d "${REPO_DIR}/.git" ] && [ ! -f "${REPO_DIR}/pyproject.toml" ]; then
    code="$(http_head https://github.com)"
    info "github_http=${code}"
    case "${code}" in 200|301|302) ;; *) fail "GitHub 不可访问（${code}），且本地没有仓库缓存" ;; esac
  fi

  if [ -n "$(find "${ENV_DIR}" -name 'libpython3.8.so.1.0' -print -quit 2>/dev/null || true)" ]; then
    ensure_libpython_path
  fi
  info "preflight ok"
  show_disk
  mark_done preflight
}

# ---------- 阶段 1：系统依赖 ----------
stage_apt() {
  CURRENT_STAGE="apt"
  section "1. 安装系统依赖"
  if ldconfig -p 2>/dev/null | grep -q 'libGL\.so\.1' \
     && command -v xvfb-run >/dev/null 2>&1 \
     && command -v ffmpeg >/dev/null 2>&1; then
    info "libGL / xvfb / ffmpeg 已存在，跳过 apt"
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
      git curl wget build-essential \
      libegl1 libgl1 libglu1-mesa libvulkan1 vulkan-tools \
      libglib2.0-0 libsm6 libxext6 libxrender1 libxi6 libxrandr2 \
      xvfb ffmpeg
  fi
  ldconfig -p 2>/dev/null | grep -q 'libGL\.so\.1' \
    || fail "libGL.so.1 仍缺失；apt 安装可能失败"
  info "系统依赖就绪"
  mark_done apt
}

# ---------- 阶段 2：Python 3.8 ----------
stage_conda() {
  CURRENT_STAGE="conda"
  section "2. 创建 Python 3.8 环境"
  local recreated=0
  if [ -x "${ENV_DIR}/bin/python" ] \
     && "${ENV_DIR}/bin/python" -V 2>&1 | grep -q '3\.8\.' \
     && [ -n "$(find "${ENV_DIR}" -name 'libpython3.8.so.1.0' -print -quit)" ] \
     && "${ENV_DIR}/bin/python" -m pip --version >/dev/null 2>&1; then
    info "已存在可用的 Python 3.8 环境：${ENV_DIR}"
  else
    rm -rf "${ENV_DIR}"
    recreated=1
    if command -v mamba >/dev/null 2>&1; then
      info "使用 mamba 创建环境"
      mamba create -y -q -p "${ENV_DIR}" -c conda-forge --override-channels python=3.8 pip
    else
      info "使用 conda 创建环境"
      conda create -y -q -p "${ENV_DIR}" -c conda-forge --override-channels python=3.8 pip
    fi
  fi
  if [ "${recreated}" = "1" ]; then
    info "环境是新创建的，清理下游阶段的旧标记与环境包"
    invalidate_after_env_change
  fi
  "${ENV_DIR}/bin/python" -V
  ensure_libpython_path
  info "libpython 目录：${LIBPY_DIR}"
  "${ENV_DIR}/bin/python" -m pip install --upgrade pip setuptools wheel
  mark_done conda
}

# ---------- 阶段 3：PyTorch ----------
stage_torch() {
  CURRENT_STAGE="torch"
  section "3. 安装 PyTorch 2.4.1 + cu121"
  local installed=0
  if "${ENV_DIR}/bin/python" - <<'PY' >/dev/null 2>&1
import torch, torchvision
assert torch.__version__.startswith("2.4.1")
assert torchvision.__version__.startswith("0.19.1")
assert torch.cuda.is_available()
PY
  then
    info "PyTorch 已安装且 CUDA 可用，跳过"
  else
    installed=1
    "${ENV_DIR}/bin/python" -m pip install \
      torch==2.4.1+cu121 torchvision==0.19.1+cu121 \
      --index-url https://download.pytorch.org/whl/cu121
  fi
  if [ "${installed}" = "1" ]; then
    info "PyTorch 重装过，清理下游阶段旧标记与环境包"
    invalidate_after_env_change
  fi
  "${ENV_DIR}/bin/python" - <<'PY'
import torch
print("torch", torch.__version__)
print("torch_cuda", torch.version.cuda)
print("cuda_available", torch.cuda.is_available())
print("gpu", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "NA")
if not torch.cuda.is_available():
    raise SystemExit("CUDA 不可用")
PY
  mark_done torch
}

# ---------- 阶段 4：Isaac Gym ----------
stage_isaacgym() {
  CURRENT_STAGE="isaacgym"
  section "4. 安装 Isaac Gym Preview 4"
  ensure_libpython_path
  ISAAC_PY="$(find_isaac_py || true)"
  if [ -z "${ISAAC_PY}" ]; then
    info "解压 ${ISAAC_TGZ}"
    tar -xf "${ISAAC_TGZ}" -C "${VENDOR_DIR}"
    ISAAC_PY="$(find_isaac_py || true)"
  else
    info "已有 Isaac Gym 源码，跳过解压"
  fi
  [ -n "${ISAAC_PY}" ] && [ -f "${ISAAC_PY}/setup.py" ] \
    || fail "找不到 isaacgym/python/setup.py"
  printf '%s\n' "${ISAAC_PY}" > "${STATE_DIR}/isaac_py.path"
  info "Isaac Gym python 目录：${ISAAC_PY}"
  export LD_LIBRARY_PATH="${LIBPY_DIR}:${ISAAC_PY}/isaacgym/_bindings/linux-x86_64:${LD_LIBRARY_PATH:-}"

  grep -rl 'np\.float\b' "${ISAAC_PY}" --include='*.py' 2>/dev/null \
    | xargs -r sed -i 's/np\.float\b/np.float32/g' || true

  local installed=0
  if ! "${ENV_DIR}/bin/python" -m pip show isaacgym 2>/dev/null | grep -q '^Version: 1.0rc4'; then
    installed=1
    "${ENV_DIR}/bin/python" -m pip install numpy==1.24.1
    "${ENV_DIR}/bin/python" -m pip install -e "${ISAAC_PY}"
  else
    info "isaacgym 1.0rc4 已安装，跳过"
  fi
  if [ "${installed}" = "1" ]; then
    info "Isaac Gym 重装过，清理下游阶段旧标记与环境包"
    invalidate_after_env_change
  fi
  ISAAC_VER="$("${ENV_DIR}/bin/python" -m pip show isaacgym | awk '/^Version:/ {print $2}')"
  info "isaacgym version=${ISAAC_VER}"

  # 只打印动态库诊断；libcuda 等由 NVIDIA runtime 提供，ldd 可能误报，最终以 import 为准
  ldd "${ISAAC_PY}/isaacgym/_bindings/linux-x86_64/gym_38.so" 2>/dev/null \
    | grep -E 'libpython|not found' || true
  "${ENV_DIR}/bin/python" - <<'PY'
import isaacgym
print("isaacgym import ok")
PY
  mark_done isaacgym
}

# ---------- 阶段 5：LeggedGym-Ex 源码 ----------
stage_repo() {
  CURRENT_STAGE="repo"
  section "5. 准备 LeggedGym-Ex"
  if [ -d "${REPO_DIR}/.git" ]; then
    local current
    current="$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null || true)"
    if [ "${current}" = "${REPO_REF}" ]; then
      info "仓库已在目标 commit：${REPO_REF}"
    else
      info "切换仓库到 ${REPO_REF}"
      if ! git -C "${REPO_DIR}" fetch --depth 1 origin "${REPO_REF}" \
         || ! git -C "${REPO_DIR}" checkout --force "${REPO_REF}"; then
        warn "切换 commit 失败，改用 GitHub 归档包"
        rm -rf "${REPO_DIR}"
        mkdir -p "${REPO_DIR}"
        curl -sS -L --retry 3 --max-time 600 \
          "https://github.com/lupinjia/LeggedGym-Ex/archive/${REPO_REF}.tar.gz" \
          -o /tmp/LeggedGym-Ex.tar.gz
        tar -xzf /tmp/LeggedGym-Ex.tar.gz -C "${REPO_DIR}" --strip-components=1
      fi
    fi
  elif [ -f "${REPO_DIR}/pyproject.toml" ] \
       && [ "$(cat "${STATE_DIR}/repo.commit" 2>/dev/null || true)" = "${REPO_REF}" ]; then
    info "已有归档源码且 commit 记录匹配，跳过 clone"
  else
    rm -rf "${REPO_DIR}"
    info "浅克隆 ${REPO_URL}"
    if ! git clone --depth 1 "${REPO_URL}" "${REPO_DIR}"; then
      info "git clone 失败，改用 GitHub 归档包"
      rm -rf "${REPO_DIR}"
      mkdir -p "${REPO_DIR}"
      curl -sS -L --retry 3 --max-time 600 \
        "https://github.com/lupinjia/LeggedGym-Ex/archive/${REPO_REF}.tar.gz" \
        -o /tmp/LeggedGym-Ex.tar.gz
      tar -xzf /tmp/LeggedGym-Ex.tar.gz -C "${REPO_DIR}" --strip-components=1
    fi
  fi
  REPO_COMMIT="$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null || echo "${REPO_REF}")"
  if [ -d "${REPO_DIR}/.git" ] && [ "${REPO_COMMIT}" != "${REPO_REF}" ]; then
    fail "LeggedGym-Ex commit 不匹配：${REPO_COMMIT} != ${REPO_REF}"
  fi
  printf '%s\n' "${REPO_COMMIT}" > "${STATE_DIR}/repo.commit"
  info "LeggedGym-Ex commit=${REPO_COMMIT}"
  mark_done repo
}

# ---------- 阶段 6：仓库依赖 ----------
stage_deps() {
  CURRENT_STAGE="deps"
  section "6. 安装 LeggedGym-Ex 依赖"
  REPO_COMMIT="$(cat "${STATE_DIR}/repo.commit" 2>/dev/null || echo "${REPO_REF}")"
  local fingerprint
  fingerprint="$(sha256sum "${REPO_DIR}/pyproject.toml" | awk '{print $1}'):${REPO_COMMIT}:$("${ENV_DIR}/bin/python" -V 2>&1)"
  if done_marker deps \
     && [ "$(cat "${STATE_DIR}/deps.fingerprint" 2>/dev/null || true)" = "${fingerprint}" ] \
     && SIMULATOR=isaacgym PYTHONPATH="${REPO_DIR}:${ISAAC_PY}" \
        "${ENV_DIR}/bin/python" -c "import isaacgym, torch, rsl_rl, legged_gym" >/dev/null 2>&1; then
    info "依赖指纹未变且关键模块可导入，跳过"
  else
    cd "${REPO_DIR}"
    "${ENV_DIR}/bin/python" -m pip install ".[isaacgym]" \
      --extra-index-url https://download.pytorch.org/whl/cu121
    "${ENV_DIR}/bin/python" -m pip install -e .
    "${ENV_DIR}/bin/python" -m pip check
    printf '%s\n' "${fingerprint}" > "${STATE_DIR}/deps.fingerprint"
  fi
  mark_done deps
}

# ---------- 阶段 7：导入验证 ----------
stage_import() {
  CURRENT_STAGE="import"
  section "7. 导入验证"
  ISAAC_PY="$(cat "${STATE_DIR}/isaac_py.path" 2>/dev/null || true)"
  [ -n "${ISAAC_PY}" ] || ISAAC_PY="$(find_isaac_py || true)"
  REPO_COMMIT="$(cat "${STATE_DIR}/repo.commit" 2>/dev/null || echo "${REPO_REF}")"
  ensure_libpython_path
  export SIMULATOR=isaacgym
  export PYTHONPATH="${REPO_DIR}:${ISAAC_PY}:${PYTHONPATH:-}"
  export LD_LIBRARY_PATH="${LIBPY_DIR}:${ISAAC_PY}/isaacgym/_bindings/linux-x86_64:${LD_LIBRARY_PATH:-}"
  export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/nvidia_icd.json}"
  "${ENV_DIR}/bin/python" - <<'PY'
# Isaac Gym 要求先导入 isaacgym，再导入 torch
import isaacgym
import torch
from legged_gym import LEGGED_GYM_ROOT_DIR, SIMULATOR
print("torch", torch.__version__, "cuda", torch.version.cuda)
print("isaacgym ok")
print("legged_gym_root", LEGGED_GYM_ROOT_DIR)
print("simulator", SIMULATOR)
PY
  mark_done import
}

# ---------- 阶段 8：打包 ----------
stage_pack() {
  CURRENT_STAGE="pack"
  section "8. 打包环境"
  TORCH_VER="$("${ENV_DIR}/bin/python" -c 'import torch; print(torch.__version__)')"
  ISAAC_VER="$("${ENV_DIR}/bin/python" -m pip show isaacgym | awk '/^Version:/ {print $2}')"
  REPO_COMMIT="$(cat "${STATE_DIR}/repo.commit" 2>/dev/null || echo "${REPO_REF}")"
  local fingerprint deps_fp
  deps_fp="$(cat "${STATE_DIR}/deps.fingerprint" 2>/dev/null || true)"
  fingerprint="${TORCH_VER}:${ISAAC_VER}:${REPO_COMMIT}:${deps_fp}:$("${ENV_DIR}/bin/python" -V 2>&1)"
  if [ -f "${ENV_PACK}" ] && done_marker pack \
     && [ "$(cat "${STATE_DIR}/pack.fingerprint" 2>/dev/null || true)" = "${fingerprint}" ]; then
    info "环境包已存在且指纹未变，跳过打包"
  else
    python -m pip install conda-pack
    local pack_extra=""
    if conda-pack --help 2>&1 | grep -q -- '--ignore-editable-packages'; then
      pack_extra="--ignore-editable-packages"
    else
      warn "conda-pack 不支持 --ignore-editable-packages"
    fi
    if conda-pack --help 2>&1 | grep -q -- '--quiet'; then
      pack_extra="${pack_extra} --quiet"
    fi
    rm -f "${ENV_PACK}"
    # shellcheck disable=SC2086
    conda-pack -p "${ENV_DIR}" -o "${ENV_PACK}" --ignore-missing-files ${pack_extra}
    printf '%s\n' "${fingerprint}" > "${STATE_DIR}/pack.fingerprint"
  fi
  sha256sum "${ENV_PACK}" | tee "${ENV_PACK}.sha256"
  mark_done pack
}

# ---------- 阶段 9：打包后验证 ----------
stage_pack_verify() {
  CURRENT_STAGE="pack_verify"
  section "9. 验证环境包可移植"
  # 先撤销“已打包”标记；验证失败时下次会自动重新打包，而不是反复复用坏包
  rm -f "${STATE_DIR}/pack.done" "${STATE_DIR}/pack_verify.done"
  local verify="/tmp/py38-verify"
  rm -rf "${verify}"
  mkdir -p "${verify}"
  tar -xzf "${ENV_PACK}" -C "${verify}"
  "${verify}/bin/conda-unpack"
  local verify_lib verify_lib_dir
  verify_lib="$(find "${verify}" -name 'libpython3.8.so.1.0' -print -quit)"
  [ -n "${verify_lib}" ] || fail "打包环境里缺少 libpython3.8.so.1.0"
  verify_lib_dir="$(dirname "${verify_lib}")"
  ISAAC_PY="$(cat "${STATE_DIR}/isaac_py.path" 2>/dev/null || true)"
  [ -n "${ISAAC_PY}" ] || ISAAC_PY="$(find_isaac_py || true)"
  SIMULATOR=isaacgym \
  PYTHONPATH="${REPO_DIR}:${ISAAC_PY}" \
  LD_LIBRARY_PATH="${verify_lib_dir}:${ISAAC_PY}/isaacgym/_bindings/linux-x86_64:${LD_LIBRARY_PATH:-}" \
  "${verify}/bin/python" - <<'PY'
# Isaac Gym 要求先导入 isaacgym，再导入 torch
import isaacgym
import torch
from legged_gym import LEGGED_GYM_ROOT_DIR, SIMULATOR
print("verify torch", torch.__version__, "cuda", torch.version.cuda)
print("verify isaacgym ok")
print("verify legged_gym_root", LEGGED_GYM_ROOT_DIR)
print("verify simulator", SIMULATOR)
PY
  mark_done pack
  mark_done pack_verify
}

# ---------- 阶段 10：环境记录 ----------
stage_env_lock() {
  CURRENT_STAGE="env_lock"
  section "10. 写环境记录"
  TORCH_VER="$("${ENV_DIR}/bin/python" -c 'import torch; print(torch.__version__)')"
  ISAAC_VER="$("${ENV_DIR}/bin/python" -m pip show isaacgym | awk '/^Version:/ {print $2}')"
  REPO_COMMIT="$(cat "${STATE_DIR}/repo.commit" 2>/dev/null || echo "${REPO_REF}")"
  ISAAC_PY="$(cat "${STATE_DIR}/isaac_py.path" 2>/dev/null || true)"
  [ -n "${ISAAC_PY}" ] || ISAAC_PY="$(find_isaac_py || true)"
  local gpu_name gpu_mem gpu_driver sha256
  gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
  gpu_mem="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -1)"
  gpu_driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
  sha256="$(awk '{print $1}' "${ENV_PACK}.sha256")"

  {
    echo "build_time=${TS}"
    echo "gpu_name=${gpu_name}"
    echo "gpu_memory=${gpu_mem}"
    echo "gpu_driver=${gpu_driver}"
    echo "os=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d '\"')"
    echo "python=$("${ENV_DIR}/bin/python" -V 2>&1)"
    echo "torch=${TORCH_VER}"
    echo "isaacgym=${ISAAC_VER}"
    echo "leggedgym_commit=${REPO_COMMIT}"
    echo "leggedgym_ref=${REPO_REF}"
    echo "isaacgym_path=${ISAAC_PY}"
    echo "repo_path=${REPO_DIR}"
    echo "pythonpath=${REPO_DIR}:${ISAAC_PY}"
    echo "ld_library_path=<env>/lib:${ISAAC_PY}/isaacgym/_bindings/linux-x86_64"
    echo "env_pack=${ENV_PACK}"
    echo "env_pack_sha256=${sha256}"
    echo "apt_packages=libegl1,libgl1,libglu1-mesa,libvulkan1,vulkan-tools,libglib2.0-0,libsm6,libxext6,libxrender1,libxi6,libxrandr2,xvfb,ffmpeg"
  } | tee "${ENV_ROOT}/env-lock.txt" > "${DATA_ROOT}/env-lock.txt"

  cat > "${DATA_ROOT}/env-lock.md" <<EOF
# 项目一环境锁定

| 项 | 值 |
|---|---|
| 构建时间 | ${TS} |
| GPU | ${gpu_name} / ${gpu_mem} |
| 驱动 | ${gpu_driver} |
| 系统 | $(grep PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d '\"') |
| Python | $("${ENV_DIR}/bin/python" -V 2>&1) |
| PyTorch | ${TORCH_VER} |
| Isaac Gym | ${ISAAC_VER} |
| LeggedGym-Ex commit | ${REPO_COMMIT} |
| Isaac Gym 源码 | ${ISAAC_PY} |
| LeggedGym-Ex 源码 | ${REPO_DIR} |
| 环境包 | ${ENV_PACK} |
| sha256 | ${sha256} |

启动时设置：\`SIMULATOR=isaacgym\`、\`PYTHONPATH=${REPO_DIR}:${ISAAC_PY}\`、\`LD_LIBRARY_PATH=<env>/lib:${ISAAC_PY}/isaacgym/_bindings/linux-x86_64:$LD_LIBRARY_PATH\`。

导入顺序：先 \`import isaacgym\`，再 \`import torch\`；Isaac Gym 对导入顺序敏感。
EOF
  mark_done env_lock
}

# ---------- 阶段 11：收尾 ----------
stage_finalize() {
  CURRENT_STAGE="finalize"
  section "11. 完成"
  printf '%s\n' "${SCRIPT_SHA}" > "${STATE_DIR}/99-success.done"
  info "环境包：${ENV_PACK}"
  info "sha256：$(awk '{print $1}' "${ENV_PACK}.sha256")"
  info "环境记录：${DATA_ROOT}/env-lock.md"
  info "日志：${LATEST_LOG}"
  info "构建环境占用的 ${BUILD_ROOT} 将在清理后释放；环境包保留"
  "${ENV_DIR}/bin/python" -m pip cache purge >/dev/null 2>&1 || true
  rm -rf "${ENV_DIR}" "${BUILD_ROOT}/pip-cache"
  show_disk
  info "下一步：提交冒烟任务，解包环境并跑 10 次迭代。"
}

section "bootstrap 开始"
info "log=${LOG}"
info "data_root=${DATA_ROOT}"
info "env_dir=${ENV_DIR}"
info "isaac_package=${ISAAC_TGZ:-未找到}"
show_disk

# 每个阶段内部都会检查自己的状态；不要因为 /data 里的旧标记跳过 per-container 的 apt/preflight
stage_preflight
stage_apt
stage_conda
stage_torch
stage_isaacgym
stage_repo
stage_deps
stage_import
stage_pack
stage_pack_verify
stage_env_lock
stage_finalize

echo
echo "===== 全部完成 ====="
echo "环境包：${ENV_PACK}"
echo "下次重跑会直接复用并秒退；需要重建用 FORCE=1。"
