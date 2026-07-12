# loot56-cuda

Standalone GPU scanner for **exact 56-bone, bones-only** desert pyramid chest loot table seeds (Minecraft Java **1.17.1**).

No cubiomes, no Java, no parent repo required — clone **this folder only** and run on Colab or any Linux machine with NVIDIA CUDA.

## Quick start (Colab T4)

1. **Runtime → Change runtime type → T4 GPU**
2. Clone or upload this folder
3. Run:

```bash
!git clone <your-repo-url> loot56-cuda   # or upload zip
%cd loot56-cuda
!bash run_colab.sh
```

Or in one cell:

```python
!make ARCH=sm_75 run-t4
```

Download `loot56_hits.txt` when done.

## Build

```bash
make              # T4 default (sm_75)
make ARCH=sm_86   # e.g. A100 / RTX 30xx
```

## Run

```bash
./loot56_cuda --loot-range LO HI --out hits.txt
```

T4-tuned (faster):

```bash
./loot56_cuda --loot-range 0 50000000000 --out hits.txt \
    --grid-size 16384 --seeds-per-thread 128
```

Use `--append` when continuing a range across Colab sessions.

## Chunk full 2^48 across sessions

| Session | `--loot-range LO HI` |
|---------|----------------------|
| 1 | `0 70368744177664` |
| 2 | `70368744177664 140737488355328` |
| 3 | `140737488355328 211106232532992` |
| 4 | `211106232532992 281474976710656` |

Session 2–4: add `--append`.

## After GPU finds loot seeds

On your PC (main Seed_Finding repo):

```powershell
cd native
.\build\desert_pyramid_56.exe --link hits.txt --world-range 0 1000000000
```

That links loot table seeds → biome-valid world seeds you can `/tp` to.

## Standalone git repo

To publish this folder as its own repo:

```bash
cd loot56-cuda
git init
git add .
git commit -m "Initial loot56-cuda scanner"
git remote add origin <your-github-url>
git push -u origin main
```

Then on Colab: `!git clone <your-github-url> && %cd loot56-cuda`

## Files

| File | Purpose |
|------|---------|
| `loot56_cuda.cu` | CUDA kernel + CLI |
| `Makefile` | Build targets |
| `run_colab.sh` | One-shot Colab script |
| `colab_cells.py` | Copy-paste Colab snippets |
