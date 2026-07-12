# Colab cells — run in order (T4 GPU runtime required)

# --- Cell 0: confirm GPU (must show Tesla T4, not "No devices") ---
"""
!nvidia-smi
"""

# --- Cell 1: clone + setup nvcc + build + scan ---
"""
!git clone https://github.com/YOUR_USER/loot56-cuda.git
%cd loot56-cuda
!bash run_colab.sh
"""

# --- Cell 2: download hits ---
"""
from google.colab import files
files.download('loot56_hits.txt')
"""

# If you already cloned and only need to fix nvcc:
"""
%cd loot56-cuda
!bash setup_colab.sh
!make ARCH=sm_75 run-t4
"""

# Full 2^48 in four sessions (use --append on sessions 2-4):
#   0 .. 70368744177664
#   70368744177664 .. 140737488355328
#   140737488355328 .. 211106232532992
#   211106232532992 .. 281474976710656
