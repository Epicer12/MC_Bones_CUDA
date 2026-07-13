#!/bin/bash
# Colab setup for desert_pyramid_brute (CPU only — no GPU required).
# Usage: source setup_colab.sh   OR   bash setup_colab.sh
set -euo pipefail

ensure_cubiomes() {
    if [ -f "../native/cubiomes/loot/items.h" ]; then
        export CUBIOMES="../native/cubiomes"
    elif [ -f "cubiomes/loot/items.h" ]; then
        export CUBIOMES="cubiomes"
    else
        if [ -d "cubiomes" ] && [ ! -f "cubiomes/loot/items.h" ]; then
            echo "Removing Cubitect cubiomes (no loot)..."
            rm -rf cubiomes
        fi
        echo "Fetching xpple/cubiomes..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq cmake build-essential git
        git clone --depth 1 https://github.com/xpple/cubiomes.git cubiomes
        export CUBIOMES="cubiomes"
    fi
    if [ ! -f "$CUBIOMES/loot/items.h" ]; then
        echo "ERROR: need https://github.com/xpple/cubiomes"
        exit 1
    fi
    echo "CUBIOMES: $CUBIOMES"
}

ensure_cubiomes
echo "CPU threads: $(nproc)"
