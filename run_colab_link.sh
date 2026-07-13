#!/bin/bash
# Build and run GPU link pass on Colab T4.
# Usage: bash run_colab_link.sh [LOOT_FILE] [STRUCT_LO] [STRUCT_HI] [OUT]
set -euo pipefail

cd "$(dirname "$0")"

# shellcheck source=/dev/null
source ./setup_colab.sh

LOOT="${1:-loot56_hits.txt}"
STRUCT_LO="${2:-20000000000}"
STRUCT_HI="${3:-80000000000}"
OUT="${4:-link56_hits.txt}"

if [ ! -f "$LOOT" ]; then
    echo "ERROR: loot file not found: $LOOT"
    echo "  loot56_hits.txt is bundled in this folder."
    echo "  Or run loot scan first: bash run_colab.sh"
    exit 1
fi

echo ""
echo "=== Building link56_cuda (T4 / sm_75) ==="
make ARCH=sm_75 NVCC="$NVCC" link56_cuda

echo ""
echo "=== Link loot=$LOOT struct=[$STRUCT_LO, $STRUCT_HI) region-grid=100x100 ==="
./link56_cuda \
    --loot-file "$LOOT" \
    --struct-range "$STRUCT_LO" "$STRUCT_HI" \
    --region-grid 100 \
    --out "$OUT" \
    --grid-size 16384 \
    --batch-struct-seeds 50000

echo ""
if [ -f "$OUT" ]; then
    echo "=== Structure matches in $OUT ==="
    grep -v '^#' "$OUT" | head -20 || true
    echo ""
    echo "Download with: from google.colab import files; files.download('$OUT')"
fi
