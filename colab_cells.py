# Colab cells — run in order (T4 GPU runtime required)

# --- Cell 0: confirm GPU (must show Tesla T4, not "No devices") ---
"""
!nvidia-smi
"""

# --- Cell 1: structure-first scan (region 0,0, 160B..2^48) + MITM ---
"""
%cd loot56-cuda
!bash setup_colab.sh
!bash run_colab_struct.sh
"""

# --- Cell 2: download struct + mitm hits ---
"""
from google.colab import files
files.download('struct56_hits.txt')
files.download('struct56_mitm.txt')
"""

# --- Optional: link bundled loot hits (loot-first path) ---

# --- Cell 2: download link hits ---
"""
from google.colab import files
files.download('link56_hits.txt')
"""

# --- Optional: loot scan first, then link ---
"""
%cd loot56-cuda
!bash run_colab.sh
!bash run_colab_link.sh loot56_hits.txt 20000000000 80000000000 link56_hits.txt
"""

# --- Chunk link across sessions (add --append on session 2+) ---
# Session 1: bash run_colab_link.sh loot56_hits.txt 20000000000 40000000000 link56_hits.txt
# Session 2: ./link56_cuda --loot-file loot56_hits.txt --struct-range 40000000000 60000000000 --region-grid 100 --out link56_hits.txt --append --grid-size 16384
# Session 3: ./link56_cuda --loot-file loot56_hits.txt --struct-range 60000000000 80000000000 --region-grid 100 --out link56_hits.txt --append --grid-size 16384

# If you already cloned and only need to fix nvcc:
"""
%cd loot56-cuda
!bash setup_colab.sh
!make ARCH=sm_75 link56_cuda
"""

# Full 2^48 loot scan in four sessions (use --append on sessions 2-4):
#   0 .. 70368744177664
#   70368744177664 .. 140737488355328
#   140737488355328 .. 211106232532992
#   211106232532992 .. 281474976710656
