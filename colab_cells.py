# Colab cells — copy-paste into notebook cells

# --- Run brute (CPU runtime OK) ---
"""
%cd loot56-cuda
!bash run_colab.sh
# Or chunk: !bash run_colab.sh 0 5000000000 4
"""

# --- Download hits ---
"""
from google.colab import files
files.download('brute_out.txt')
files.download('brute_progress.txt')
"""

# --- Manual build + custom range ---
"""
%cd loot56-cuda
!bash setup_colab.sh
!make
!./desert_pyramid_brute --struct-range 0 5000000000 --exact 56 --regions 4 --sisters 65536 --threads $(nproc) --out brute_out.txt --progress-out brute_progress.txt
"""
