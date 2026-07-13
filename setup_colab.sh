#!/bin/bash
# Colab setup: ensure GPU runtime + nvcc on PATH.
# Usage: source setup_colab.sh   OR   bash setup_colab.sh
set -euo pipefail

find_nvcc() {
    local candidates=(
        nvcc
        /usr/local/cuda/bin/nvcc
        /usr/lib/nvidia-cuda-toolkit/bin/nvcc
        /usr/bin/nvcc
    )
    for p in "${candidates[@]}"; do
        if command -v "$p" >/dev/null 2>&1; then
            command -v "$p"
            return 0
        fi
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
    echo ""
    echo "ERROR: No NVIDIA GPU detected."
    echo "  Colab: Runtime → Change runtime type → T4 GPU → Save"
    echo "  Then restart this cell."
    echo ""
    exit 1
fi

NVCC_PATH="$(find_nvcc || true)"

if [ -z "${NVCC_PATH:-}" ]; then
    echo "nvcc not found — installing nvidia-cuda-toolkit (~2 min, one-time per session)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq nvidia-cuda-toolkit
    NVCC_PATH="$(find_nvcc || true)"
fi

if [ -z "${NVCC_PATH:-}" ]; then
    echo "ERROR: nvcc still not found after install."
    exit 1
fi

export NVCC="$NVCC_PATH"
export PATH="$(dirname "$NVCC"):$PATH"

# cubiomes for struct56_cuda CPU verify (from parent repo or ./cubiomes symlink)
if [ -d "../native/cubiomes" ]; then
    export CUBIOMES="../native/cubiomes"
elif [ -d "cubiomes" ]; then
    export CUBIOMES="cubiomes"
else
    echo "WARNING: cubiomes not found — struct56_cuda needs ../native/cubiomes"
    echo "  Clone full Seed_Finding repo, or: ln -s /path/to/native/cubiomes cubiomes"
fi

echo "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
echo "NVCC: $NVCC ($($NVCC --version | tail -1))"
