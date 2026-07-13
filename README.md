# loot56-cuda

Colab-friendly bundle of **`desert_pyramid_brute`** — finds **exact 56-bone, bones-only** desert pyramid chests on Minecraft Java **1.17.1** and outputs **playable world seeds** with `/tp` coords.

Uses full **cubiomes**: structure placement, loot tables, sister-seed search, and desert biome check. No GPU required.

`setup_colab.sh` auto-downloads [xpple/cubiomes](https://github.com/xpple/cubiomes) on first run (Cubitect's repo has no loot tables).

## Quick start (Colab)

CPU runtime is fine — no T4 needed.

```python
%cd loot56-cuda
!bash run_colab.sh
```

Default chunk: structure seeds **100M → 10B**, regions **4×4**, exact **56 bones**.

Custom range (`STRUCT_LO STRUCT_HI REGIONS`):

```python
!bash run_colab.sh 0 5000000000 4
!bash run_colab.sh 5000000000 10000000000 4
```

Download results before the session ends:

```python
from google.colab import files
files.download('brute_out.txt')
files.download('brute_progress.txt')
```

Each session overwrites `brute_out.txt`. Use a different `--out` path if you run `./desert_pyramid_brute` manually across sessions.

## Chunk across sessions

| Session | Command |
|---------|---------|
| 1 | `bash run_colab.sh 0 5000000000 4` |
| 2 | `bash run_colab.sh 5000000000 10000000000 4` |
| 3 | `bash run_colab.sh 10000000000 50000000000 4` |

Download `brute_out.txt` after each session.

## Manual build

```bash
bash setup_colab.sh
make
./desert_pyramid_brute --struct-range LO HI --exact 56 --regions 4 --sisters 65536 --threads $(nproc)
```

Or `make run` for the default range.

## Output format

Hit lines look like:

```text
worldSeed=... structureSeed=... region=(x,z) chest=... bones=56 /tp ...
```

These are real world seeds — ready to test in-game.

Known **55-bone** playable seed from this tool: `worldSeed=1902153293`, region `(0,3)`, `/tp 160 90 1680`.

## Standalone git repo

```bash
cd loot56-cuda
git init
git add .
git commit -m "Colab desert pyramid brute finder"
git remote add origin <your-github-url>
git push -u origin main
```

Then on Colab: `!git clone <your-github-url> && %cd loot56-cuda`

## Files

| File | Purpose |
|------|---------|
| `desert_pyramid_brute.c` | Trusted CPU world-seed finder (same as `native/`) |
| `setup_colab.sh` | Fetch cubiomes + build deps (CPU only) |
| `run_colab.sh` | Build + run brute on Colab |
| `Makefile` | Build `desert_pyramid_brute` |
| `colab_cells.py` | Copy-paste Colab snippets |
