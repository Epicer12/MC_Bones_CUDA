# Paste into Colab cells (T4 GPU runtime required)

# --- Cell 1: clone standalone repo ---
"""
!git clone https://github.com/YOUR_USER/loot56-cuda.git
%cd loot56-cuda
!nvidia-smi
"""

# --- Cell 2: build + scan one chunk ---
"""
!make ARCH=sm_75
!./loot56_cuda --loot-range 0 50000000000 --out loot56_hits.txt \
    --grid-size 16384 --seeds-per-thread 128
"""

# --- Cell 3: download hits ---
"""
from google.colab import files
files.download('loot56_hits.txt')
"""

# Full 2^48 in four Colab sessions (use --append on sessions 2-4):
#   0 .. 70368744177664
#   70368744177664 .. 140737488355328
#   140737488355328 .. 211106232532992
#   211106232532992 .. 281474976710656
