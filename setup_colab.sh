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

# cubiomes: auto-fetch xpple fork (has desert pyramid loot; Cubitect does not)
ensure_cubiomes() {
    if [ -f "../native/cubiomes/loot/items.h" ]; then
        export CUBIOMES="../native/cubiomes"
    elif [ -f "cubiomes/loot/items.h" ]; then
        export CUBIOMES="cubiomes"
    else
        # Drop wrong Cubitect clone if present (no loot/)
        if [ -d "cubiomes" ] && [ ! -f "cubiomes/loot/items.h" ]; then
            echo "Removing Cubitect cubiomes (no loot)..."
            rm -rf cubiomes
        fi
        echo "Fetching xpple/cubiomes (loot tables; one-time per Colab session)..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq cmake build-essential git
        git clone --depth 1 https://github.com/xpple/cubiomes.git cubiomes
        export CUBIOMES="cubiomes"
    fi
    if [ ! -f "$CUBIOMES/loot/items.h" ]; then
        echo "ERROR: $CUBIOMES has no loot/ — need https://github.com/xpple/cubiomes"
        exit 1
    fi
    echo "CUBIOMES: $CUBIOMES"
}
ensure_cubiomes

echo "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
echo "NVCC: $NVCC ($($NVCC --version | tail -1))"
