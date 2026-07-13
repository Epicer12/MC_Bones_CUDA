#!/bin/bash
# Build and run GPU structure-first 56-bone scan on Colab T4.
# Usage: bash run_colab_struct.sh [STRUCT_LO] [STRUCT_HI] [RX] [RZ]
set -euo pipefail

cd "$(dirname "$0")"

# shellcheck source=/dev/null
source ./setup_colab.sh

STRUCT_LO="${1:-160000000000}"
STRUCT_HI="${2:-281474976710656}"
REG_X="${3:-0}"
REG_Z="${4:-0}"

echo ""
echo "=== Building struct56_cuda (T4 / sm_75) ==="
make ARCH=sm_75 NVCC="$NVCC" struct56_cuda

echo ""
echo "=== Structure scan [$STRUCT_LO, $STRUCT_HI) region=($REG_X,$REG_Z) + MITM ==="
./struct56_cuda \
    --struct-range "$STRUCT_LO" "$STRUCT_HI" \
    --region "$REG_X" "$REG_Z" \
    --mitm \
    --out struct56_hits.txt \
    --mitm-out struct56_mitm.txt \
    --grid-size 16384 \
    --seeds-per-thread 128

echo ""
for f in struct56_hits.txt struct56_mitm.txt; do
    if [ -f "$f" ]; then
        echo "=== $f ==="
        grep -v '^#' "$f" | head -20 || true
    fi
done
