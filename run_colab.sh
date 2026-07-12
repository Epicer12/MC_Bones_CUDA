#!/bin/bash
# Build and run on Colab T4. Usage: bash run_colab.sh [LO] [HI] [OUT]
set -euo pipefail

cd "$(dirname "$0")"

LO="${1:-0}"
HI="${2:-50000000000}"
OUT="${3:-loot56_hits.txt}"

echo "=== Building loot56_cuda (T4 / sm_75) ==="
make ARCH=sm_75

echo ""
echo "=== GPU ==="
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

echo ""
echo "=== Scan [$LO, $HI) ==="
./loot56_cuda \
    --loot-range "$LO" "$HI" \
    --out "$OUT" \
    --grid-size 16384 \
    --seeds-per-thread 128

echo ""
if [ -f "$OUT" ]; then
    echo "=== Hits in $OUT ==="
    grep -v '^#' "$OUT" | head -20
fi
