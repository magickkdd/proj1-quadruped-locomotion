#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/data/proj1}"
ENV_PACK="${ENV_PACK:-${DATA_ROOT}/env/isaacgym-py38.tar.gz}"
RUNTIME_ROOT="${RUNTIME_ROOT:-/tmp/proj1-runtime}"
ENV_DIR="${RUNTIME_ROOT}/py38"
ISAAC_PY="${DATA_ROOT}/vendor/isaacgym/python"
REPO_DIR="${DATA_ROOT}/vendor/LeggedGym-Ex"

mkdir -p "${RUNTIME_ROOT}"
[ -f "${ENV_PACK}" ] || { printf '%s\n' "缺少环境包：${ENV_PACK}" >&2; exit 1; }
[ -d "${ISAAC_PY}" ] || { printf '%s\n' "缺少 Isaac Gym：${ISAAC_PY}" >&2; exit 1; }
[ -d "${REPO_DIR}" ] || { printf '%s\n' "缺少 LeggedGym-Ex：${REPO_DIR}" >&2; exit 1; }

if ! ldconfig -p 2>/dev/null | grep -q 'libX11.so.6'; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/tmp/proj1-train-apt.log 2>&1
  apt-get install -y -qq --no-install-recommends libx11-6 libxext6 libxrender1 libgl1 libglu1-mesa >>/tmp/proj1-train-apt.log 2>&1
fi

if [ ! -x "${ENV_DIR}/bin/python" ]; then
  rm -rf "${ENV_DIR}"
  mkdir -p "${ENV_DIR}"
  tar -xzf "${ENV_PACK}" -C "${ENV_DIR}"
  "${ENV_DIR}/bin/conda-unpack"
fi

export ENV_DIR
export DATA_ROOT
export REPO_DIR
export ISAAC_PY
export SIMULATOR=isaacgym
export PYTHONPATH="${REPO_DIR}:${ISAAC_PY}:${PYTHONPATH:-}"
export LD_LIBRARY_PATH="${ENV_DIR}/lib:${ISAAC_PY}/isaacgym/_bindings/linux-x86_64:${LD_LIBRARY_PATH:-}"

exec bash "$(dirname "$0")/train.sh" "$@"
