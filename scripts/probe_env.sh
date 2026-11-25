#!/usr/bin/env bash
# 项目一平台探测脚本：确认 A100 资源、Python/conda、外网、存储与 Isaac Gym 依赖
# 用法：bash /code/workspace/probe_env.sh
# 输出：/data/proj1/probe/<timestamp>/probe.log 与 summary.txt

set -u

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="/data/proj1/probe/${TS}"
if ! mkdir -p "${OUT_DIR}" 2>/dev/null || [ ! -w "${OUT_DIR}" ]; then
  OUT_DIR="/tmp/proj1-probe-${TS}"
  mkdir -p "${OUT_DIR}"
  echo "[WARN] /data 不可写，结果改写到 ${OUT_DIR}"
fi
LOG="${OUT_DIR}/probe.log"
SUMMARY="${OUT_DIR}/summary.txt"
exec > >(tee -a "${LOG}") 2>&1

GPU_NAME="NA"
GPU_MEM="NA"
GPU_DRIVER="NA"
GPU_CC="NA"
PYPI_CODE="NA"
PT_CODE="NA"
CONDA_CODE="NA"
GITHUB_CODE="NA"
NV_CODE="NA"
DATA_AVAIL_GB="NA"
TMP_AVAIL_GB="NA"

section() { printf '\n===== %s =====\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }

http_head() {
  local url="$1"
  curl -sS -I -L -o /dev/null -w '%{http_code}' --max-time 20 "${url}" 2>/dev/null || echo "ERR"
}

bytes_to_gb() {
  awk -v b="$1" 'BEGIN { if (b ~ /^[0-9]+$/) printf "%.1f", b/1024/1024/1024; else print "NA" }'
}

echo "probe_start=$(date -Is 2>/dev/null || date)"
echo "out_dir=${OUT_DIR}"

section "1. 基础信息"
info "user=$(id -un 2>/dev/null || whoami)"
info "host=$(hostname 2>/dev/null || uname -n)"
info "kernel=$(uname -a)"
echo "--- /etc/os-release ---"
cat /etc/os-release 2>/dev/null || warn "读不到 /etc/os-release"
getconf GNU_LIBC_VERSION 2>/dev/null || warn "读不到 glibc 版本"
info "cpu_cores=$(nproc 2>/dev/null || echo NA)"
echo "--- memory ---"
free -h 2>/dev/null || warn "free 不可用"
echo "--- current dir ---"
pwd
echo "--- /code/workspace ---"
ls -la /code/workspace 2>/dev/null | head -50 || warn "/code/workspace 不存在或不可读"

section "2. GPU 与驱动"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi -L || true
  nvidia-smi --query-gpu=index,name,memory.total,memory.used,driver_version --format=csv,noheader || true
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
  GPU_MEM="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1 || true)"
  GPU_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
  GPU_CC="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 || true)"
  info "gpu_name=${GPU_NAME}"
  info "gpu_memory=${GPU_MEM}"
  info "gpu_driver=${GPU_DRIVER}"
  info "gpu_compute_cap=${GPU_CC:-NA}"
  case "${GPU_NAME}" in
    *A100*) pass "检测到 A100" ;;
    *) warn "未检测到 A100，实际为 ${GPU_NAME}" ;;
  esac
  case "${GPU_MEM}" in
    *81920*) pass "显存约 80GB" ;;
    *) warn "显存不是 80GB：${GPU_MEM}" ;;
  esac
else
  fail "找不到 nvidia-smi"
fi

section "3. Python 与包管理器"
for c in python python3 python3.8 python3.9 python3.10 python3.11 pip pip3 conda micromamba mamba; do
  if command -v "$c" >/dev/null 2>&1; then
    printf '%-12s %s\n' "$c" "$(command -v "$c")"
    "$c" --version 2>&1 | head -1 || true
  fi
done
PY_VER="$(python3 --version 2>&1 || echo NA)"
if command -v python3.8 >/dev/null 2>&1; then
  pass "系统已有 python3.8"
else
  warn "系统没有 python3.8，需要 conda/micromamba 创建"
fi
if command -v conda >/dev/null 2>&1; then
  pass "conda 可用"
else
  warn "conda 不可用"
fi
if command -v micromamba >/dev/null 2>&1; then
  pass "micromamba 可用"
else
  warn "micromamba 不可用"
fi

section "4. 外网连通性"
if command -v curl >/dev/null 2>&1; then
  PYPI_CODE="$(http_head https://pypi.org/simple/)"
  PT_CODE="$(http_head https://download.pytorch.org/whl/cu117/)"
  CONDA_CODE="$(http_head https://conda.anaconda.org/conda-forge/noarch/repodata.json)"
  GITHUB_CODE="$(http_head https://github.com)"
  NV_CODE="$(http_head https://developer.nvidia.com/isaac-gym)"
  echo "pypi=${PYPI_CODE}"
  echo "pytorch=${PT_CODE}"
  echo "conda=${CONDA_CODE}"
  echo "github=${GITHUB_CODE}"
  echo "nvidia=${NV_CODE}"
  case "${PYPI_CODE}" in
    200|301|302) pass "PyPI 可访问" ;;
    *) fail "PyPI 不可访问" ;;
  esac
  case "${PT_CODE}" in
    200|301|302) pass "PyTorch wheel 源可访问" ;;
    *) warn "PyTorch wheel 源不可访问" ;;
  esac
  case "${CONDA_CODE}" in
    200|301|302) pass "conda-forge 可访问" ;;
    *) warn "conda-forge 不可访问" ;;
  esac
  case "${GITHUB_CODE}" in
    200|301|302) pass "GitHub 可访问" ;;
    *) warn "GitHub 不可访问" ;;
  esac
else
  fail "找不到 curl，无法测试外网"
fi
echo "--- DNS ---"
getent hosts pypi.org 2>/dev/null | head -3 || warn "DNS 解析 pypi.org 失败"

section "5. Git 访问"
if command -v git >/dev/null 2>&1; then
  git --version
  if command -v timeout >/dev/null 2>&1; then
    if timeout 30 git ls-remote https://github.com/lupinjia/LeggedGym-Ex.git HEAD >/dev/null 2>&1; then
      pass "git ls-remote LeggedGym-Ex 成功"
    else
      fail "git ls-remote LeggedGym-Ex 失败"
    fi
  else
    warn "没有 timeout，跳过 git ls-remote 超时测试"
  fi
else
  fail "找不到 git"
fi

section "6. 存储与写入"
df -h / /tmp /data 2>/dev/null || true
if df -P -B1 /data >/dev/null 2>&1; then
  DATA_AVAIL_GB="$(bytes_to_gb "$(df -P -B1 /data | awk 'NR==2 {print $4}')")"
fi
if df -P -B1 /tmp >/dev/null 2>&1; then
  TMP_AVAIL_GB="$(bytes_to_gb "$(df -P -B1 /tmp | awk 'NR==2 {print $4}')")"
fi
info "data_avail_gb=${DATA_AVAIL_GB}"
info "tmp_avail_gb=${TMP_AVAIL_GB}"
mkdir -p /data/proj1/env /data/proj1/runs /data/proj1/probe 2>/dev/null || true
if echo "write test $(date -Is 2>/dev/null || date)" > /data/proj1/probe/write-test.txt 2>/dev/null; then
  pass "/data 可写"
else
  fail "/data 不可写"
fi
if echo "write test" > "${OUT_DIR}/write-test.txt" 2>/dev/null; then
  pass "结果目录可写：${OUT_DIR}"
else
  fail "结果目录不可写：${OUT_DIR}"
fi

section "7. Isaac Gym 运行依赖"
LIBS="$(ldconfig -p 2>/dev/null | grep -Ei 'libGL\.so|libGLU\.so|libX11\.so|libXi\.so|libXrandr\.so' | head -20 || true)"
if [ -n "${LIBS}" ]; then
  echo "${LIBS}"
  pass "找到基础图形库"
else
  warn "未找到 libGL/libGLU/libX11，import isaacgym 可能报错"
fi
for c in gcc g++ make cmake tar unzip xvfb-run ffmpeg; do
  if command -v "$c" >/dev/null 2>&1; then
    printf '%-10s %s\n' "$c" "$(command -v "$c")"
  else
    printf '%-10s missing\n' "$c"
  fi
done

section "8. 关键环境变量"
for v in CUDA_VISIBLE_DEVICES TENSORBOARD_LOGDIR HTTP_PROXY HTTPS_PROXY NO_PROXY; do
  printf '%s=%s\n' "$v" "$(printenv "$v" 2>/dev/null || echo '<unset>')"
done

section "9. 系统权限"
info "uid=$(id -u)"
if command -v apt-get >/dev/null 2>&1; then
  pass "apt-get 存在"
else
  warn "apt-get 不存在"
fi

section "10. 结论"
{
  echo "probe_time=${TS}"
  echo "out_dir=${OUT_DIR}"
  echo "gpu_name=${GPU_NAME}"
  echo "gpu_memory=${GPU_MEM}"
  echo "gpu_driver=${GPU_DRIVER}"
  echo "gpu_compute_cap=${GPU_CC:-NA}"
  echo "python3=${PY_VER}"
  echo "conda=$(command -v conda 2>/dev/null || echo NA)"
  echo "micromamba=$(command -v micromamba 2>/dev/null || echo NA)"
  echo "pypi_http=${PYPI_CODE}"
  echo "pytorch_http=${PT_CODE}"
  echo "conda_http=${CONDA_CODE}"
  echo "github_http=${GITHUB_CODE}"
  echo "nvidia_http=${NV_CODE}"
  echo "data_avail_gb=${DATA_AVAIL_GB}"
  echo "tmp_avail_gb=${TMP_AVAIL_GB}"
  echo "has_python38=$(command -v python3.8 >/dev/null 2>&1 && echo yes || echo no)"
  echo "has_conda=$(command -v conda >/dev/null 2>&1 && echo yes || echo no)"
  echo "has_micromamba=$(command -v micromamba >/dev/null 2>&1 && echo yes || echo no)"
  echo "has_xvfb=$(command -v xvfb-run >/dev/null 2>&1 && echo yes || echo no)"
  echo "probe_end=$(date -Is 2>/dev/null || date)"
} | tee "${SUMMARY}"

echo
echo "探测完成。完整日志：${LOG}"
echo "摘要文件：${SUMMARY}"
