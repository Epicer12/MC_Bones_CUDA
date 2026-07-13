# loot56-cuda

Standalone GPU scanner for **exact 56-bone, bones-only** desert pyramid chest loot table seeds (Minecraft Java **1.17.1**).

No cubiomes, no Java, no parent repo required — clone **this folder only** and run on Colab or any Linux machine with NVIDIA CUDA.

`setup_colab.sh` **auto-downloads xpple/cubiomes** on first run (loot tables; Cubitect's repo is not enough).

## Quick start (Colab T4)

**Step 0 — enable GPU** (required): **Runtime → Change runtime type → T4 GPU → Save**

### Option C — structure-first brute (recommended)

**`struct56_cuda`** GPU-scans structure seeds with **fast56**, then **cubiomes CPU verify** (placement + full loot table). Optional **`--mitm`** runs cubiomes sister-seed + desert biome pass.

**Requires cubiomes** — fetched automatically by `setup_colab.sh` on Colab.

```python
%cd loot56-cuda
!bash setup_colab.sh
!bash run_colab_struct.sh
```

Default range: **160B → 2⁴⁸** (`281474976710656`), region `(0,0)`.

Custom range:

```python
!bash run_colab_struct.sh 160000000000 281474976710656 0 0
```

Outputs:
- `struct56_hits.txt` — **cubiomes-verified** structure hits only
- `struct56_mitm.txt` — biome-valid **world seeds** (playable candidates)

Chunk across Colab sessions (`--append` on session 2+):

| Session | `--struct-range LO HI` |
|---------|------------------------|
| 1 | `160000000000 200000000000` |
| 2 | `200000000000 240000000000` |
| 3 | `240000000000 281474976710656` |

```bash
./struct56_cuda --struct-range 200000000000 240000000000 --region 0 0 --mitm --append
```

### Option A — link bundled loot hits (loot-first, usually slower path)

`loot56_hits.txt` (13 seeds) is included. One cell:

```python
# Upload loot56-cuda folder, or clone repo and cd into it:
# %cd Seed_Finding/loot56-cuda

!bash setup_colab.sh
!bash run_colab_link.sh
```

That builds `link56_cuda`, searches structure seeds **20B–80B** across regions **(0,0)–(99,99)**, and writes `link56_hits.txt`.

Download results:

```python
from google.colab import files
files.download('link56_hits.txt')
```

### Option B — loot scan first, then link

```python
%cd loot56-cuda
!bash run_colab.sh
!bash run_colab_link.sh loot56_hits.txt 20000000000 80000000000 link56_hits.txt
```

`run_colab.sh` / `run_colab_link.sh` install `nvcc` automatically if Colab does not have it on PATH (~2 min, once per session).

### Chunk link across Colab sessions

Add `--append` on sessions 2+ when continuing structure-seed ranges:

| Session | Command |
|---------|---------|
| 1 | `bash run_colab_link.sh loot56_hits.txt 20000000000 40000000000 link56_hits.txt` |
| 2 | `./link56_cuda --loot-file loot56_hits.txt --struct-range 40000000000 60000000000 --region-grid 100 --out link56_hits.txt --append --grid-size 16384` |
| 3 | `./link56_cuda --loot-file loot56_hits.txt --struct-range 60000000000 80000000000 --region-grid 100 --out link56_hits.txt --append --grid-size 16384` |

Manual build:

```python
!bash setup_colab.sh
!make ARCH=sm_75 link56_cuda
```

### Troubleshooting `nvcc: No such file or directory`

1. **Switch to GPU runtime** — CPU runtime has no CUDA at all.
2. Run `!bash setup_colab.sh` before `make` (installs `nvidia-cuda-toolkit`).
3. Or pass nvcc explicitly: `!make NVCC=/usr/lib/nvidia-cuda-toolkit/bin/nvcc`

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

### Phase 2 — GPU link (100×100 regions, Colab)

Searches **structure seeds** across regions **(0,0) through (99,99)** — a 100×100 region area, not 100 total regions.

```bash
make link56_cuda
./link56_cuda --loot-file loot56_hits.txt \
    --struct-range 20000000000 80000000000 \
    --region-grid 100 \
    --out link56_hits.txt \
    --grid-size 16384 --batch-struct-seeds 50000
```

Or one command on Colab:

```bash
bash run_colab_link.sh loot56_hits.txt 20000000000 80000000000 link56_hits.txt
```

Work per run: `(struct_hi - struct_lo) × 100 × 100` (seed, region) pairs.  
Example: 60B structure seeds × 10,000 regions = **600 trillion** checks — fast on GPU, may take hours on T4.

Output lines look like:

```text
structureSeed=... lootTableSeed=... chest=2 region=(12,34) pos=(...)/tp ...
```

These are **structure matches only** (no biome / playable world seed yet).

### Phase 3 — CPU biome + world seed (your PC)

On your PC (main Seed_Finding repo), run sister-seed + biome pass on GPU link hits:

```powershell
cd native
.\build\desert_pyramid_56.exe --link link56_hits.txt --ws-range 0 1000000000 --region 0 0
```

For each GPU hit region, re-run `--link` with matching `--region RX RZ`, or extend hits to include per-region filtering.

The older single-region CPU link still works for one region at a time:

```powershell
.\build\desert_pyramid_56.exe --link hits.txt --ws-range 20000000000 80000000000 --region 0 0
```

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
| `loot56_cuda.cu` | CUDA loot-table seed scanner |
| `link56_cuda.cu` | CUDA structure-seed linker (100×100 regions) |
| `struct56_cuda.cu` | Structure-first 56-bone scanner + MITM |
| `link56_rng.cuh` | Shared placement + loot RNG + fast56 (device) |
| `setup_colab.sh` | Find/install nvcc on Colab |
| `Makefile` | Build targets (`loot56_cuda`, `link56_cuda`, `struct56_cuda`) |
| `run_colab.sh` | Setup + loot scan |
| `run_colab_link.sh` | Setup + link pass |
| `run_colab_struct.sh` | Setup + structure-first scan + MITM |
| `loot56_hits.txt` | Bundled 13 GPU loot hits (ready for link on Colab) |
| `colab_cells.py` | Copy-paste Colab snippets |
