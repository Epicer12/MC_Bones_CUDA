#!/bin/bash
# CPU brute on Colab — real world seeds (cubiomes placement + loot + biome).
# Usage: bash run_colab.sh [STRUCT_LO] [STRUCT_HI] [REGIONS]
#
# Example chunks (change LO each session):
#   bash run_colab.sh 0 5000000000 4
#   bash run_colab.sh 5000000000 10000000000 4
set -euo pipefail

cd "$(dirname "$0")"

# shellcheck source=/dev/null
source ./setup_colab.sh

STRUCT_LO="${1:-100000000}"
STRUCT_HI="${2:-10000000000}"
REGIONS="${3:-4}"
THREADS="$(nproc)"
OUT="brute_out.txt"
PROGRESS="brute_progress.txt"

echo ""
echo "=== Building desert_pyramid_brute ==="
make desert_pyramid_brute CUBIOMES="$CUBIOMES"

echo ""
echo "=== Brute [${STRUCT_LO}, ${STRUCT_HI}) regions=${REGIONS}x${REGIONS} exact 56 bones ==="
echo "    threads=$THREADS  out=$OUT"
./desert_pyramid_brute \
    --struct-range "$STRUCT_LO" "$STRUCT_HI" \
    --exact 56 \
    --regions "$REGIONS" \
    --sisters 65536 \
    --threads "$THREADS" \
    --out "$OUT" \
    --progress-out "$PROGRESS"

echo ""
if [ -f "$OUT" ]; then
    echo "=== Hits (world seeds — playable candidates) ==="
    grep -v '^#' "$OUT" | head -30 || true
    HITS=$(grep -vc '^#' "$OUT" || echo 0)
    echo "Total hit lines: $HITS"
fi
