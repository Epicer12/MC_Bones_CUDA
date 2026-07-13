/*
 * GPU structure-seed linker for 56-bone desert pyramid loot hits (MC 1.17.1).
 *
 * For each loot table seed in a hit file, searches structure seeds across a
 * region grid (default 100x100: regions 0..99 in X and Z) and matches the four
 * desert pyramid chest loot seeds from cubiomes placement math.
 *
 * This finds structureSeed + region + chest matches only. Run
 * desert_pyramid_56.exe --link on hits for sister-seed + biome validation.
 *
 * Build:
 *   make link56_cuda
 *
 * Run:
 *   ./link56_cuda --loot-file loot56_hits.txt --struct-range 20000000000 80000000000
 */

#include <cuda_runtime.h>

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "link56_rng.cuh"

#ifdef _WIN32
#include <windows.h>
static double now_seconds(void)
{
    FILETIME ft;
    ULARGE_INTEGER uli;
    GetSystemTimeAsFileTime(&ft);
    uli.LowPart = ft.dwLowDateTime;
    uli.HighPart = ft.dwHighDateTime;
    return (uli.QuadPart / 10000000.0) - 11644473600.0;
}
#else
#include <sys/time.h>
static double now_seconds(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}
#endif

typedef struct {
    uint64_t structure_seed;
    uint64_t loot_seed;
    int reg_x;
    int reg_z;
    int chest;
    int block_x;
    int block_z;
} LinkHit;

static const int MAX_HITS = 4096;
static const int MAX_LOOT_TARGETS = 128;

static const int DEFAULT_BLOCK_SIZE = 256;
static const int DEFAULT_GRID_SIZE = 8192;
static const int DEFAULT_REGION_GRID = 100;
static const uint64_t DEFAULT_BATCH_STRUCT_SEEDS = 10000ULL;

#define CUDA_CHECK(call)                                                       \
    do {                                                                       \
        cudaError_t err__ = (call);                                            \
        if (err__ != cudaSuccess) {                                            \
            fprintf(stderr, "CUDA error %s:%d: %s\n", __FILE__, __LINE__,      \
                cudaGetErrorString(err__));                                    \
            exit(1);                                                           \
        }                                                                      \
    } while (0)

__device__ __forceinline__ int dev_match_loot(
    uint64_t loot, const uint64_t *targets, int n_targets)
{
    for (int i = 0; i < n_targets; i++) {
        if (targets[i] == loot)
            return i;
    }
    return -1;
}

__global__ void link56_kernel(
    uint64_t struct_lo,
    uint64_t struct_hi,
    int reg_grid,
    const uint64_t *loot_targets,
    int n_loot_targets,
    unsigned long long *checked,
    int *hit_count,
    LinkHit *hits,
    int max_hits)
{
    const uint64_t regions_per_seed = (uint64_t)reg_grid * (uint64_t)reg_grid;
    const uint64_t struct_count = struct_hi - struct_lo;
    const uint64_t total_pairs = struct_count * regions_per_seed;

    const uint64_t global_id =
        (uint64_t)blockIdx.x * (uint64_t)blockDim.x + (uint64_t)threadIdx.x;
    const uint64_t stride =
        (uint64_t)blockDim.x * (uint64_t)gridDim.x;

    unsigned long long local_checked = 0;

    for (uint64_t pair_id = global_id; pair_id < total_pairs; pair_id += stride) {
        local_checked++;

        const uint64_t struct_idx = pair_id / regions_per_seed;
        const uint64_t region_idx = pair_id % regions_per_seed;
        const uint64_t structure_seed = struct_lo + struct_idx;
        const int reg_x = (int)(region_idx % (uint64_t)reg_grid);
        const int reg_z = (int)(region_idx / (uint64_t)reg_grid);

        int block_x = 0;
        int block_z = 0;
        l56_desert_pyramid_pos(structure_seed, reg_x, reg_z, &block_x, &block_z);

        uint64_t loot_seeds[4];
        l56_desert_loot_seeds(structure_seed, block_x, block_z, loot_seeds);

        for (int chest = 0; chest < 4; chest++) {
            if (dev_match_loot(loot_seeds[chest], loot_targets, n_loot_targets) < 0)
                continue;

            const int idx = atomicAdd(hit_count, 1);
            if (idx >= max_hits)
                break;

            hits[idx].structure_seed = structure_seed;
            hits[idx].loot_seed = loot_seeds[chest];
            hits[idx].reg_x = reg_x;
            hits[idx].reg_z = reg_z;
            hits[idx].chest = chest;
            hits[idx].block_x = block_x;
            hits[idx].block_z = block_z;
        }
    }

    if (local_checked > 0)
        atomicAdd(checked, local_checked);
}

static void print_usage(const char *prog)
{
    fprintf(stderr,
        "GPU desert pyramid loot linker (MC 1.17.1)\n"
        "\n"
        "Usage: %s --loot-file PATH --struct-range LO HI [options]\n"
        "\n"
        "Options:\n"
        "  --out PATH              output file (default: link56_hits.txt)\n"
        "  --region-grid N         regions 0..N-1 in X and Z (default: %d => %dx%d)\n"
        "  --batch-struct-seeds N  structure seeds per GPU launch (default: %llu)\n"
        "  --block-size N          CUDA block size (default: %d)\n"
        "  --grid-size N           CUDA grid size (default: %d)\n"
        "  --append                append hits instead of overwriting output\n"
        "  --device N              CUDA device index (default: 0)\n"
        "\n"
        "Colab T4 example:\n"
        "  make link56_cuda && ./link56_cuda --loot-file loot56_hits.txt \\\n"
        "    --struct-range 20000000000 80000000000 --region-grid 100 \\\n"
        "    --grid-size 16384\n",
        prog,
        DEFAULT_REGION_GRID,
        DEFAULT_REGION_GRID,
        DEFAULT_REGION_GRID,
        (unsigned long long)DEFAULT_BATCH_STRUCT_SEEDS,
        DEFAULT_BLOCK_SIZE,
        DEFAULT_GRID_SIZE);
}

static int load_loot_file(const char *path, uint64_t *out, int max_out, int *count_out)
{
    FILE *fp = fopen(path, "r");
    if (!fp) {
        perror(path);
        return 0;
    }

    int count = 0;
    char line[256];
    while (fgets(line, sizeof(line), fp)) {
        char *p = line;
        while (*p == ' ' || *p == '\t')
            p++;
        if (*p == '#' || *p == '\n' || *p == '\0')
            continue;

        char *end = NULL;
        uint64_t seed = strtoull(p, &end, 0);
        if (end == p)
            continue;

        if (count >= max_out) {
            fprintf(stderr, "Warning: loot file has more than %d entries; truncating\n", max_out);
            break;
        }
        out[count++] = seed;
    }

    fclose(fp);
    *count_out = count;
    return count > 0;
}

static int write_hits_file(
    const char *path, const LinkHit *hits, int count, int append_mode,
    uint64_t struct_lo, uint64_t struct_hi, int reg_grid, int n_loot)
{
    FILE *fp = fopen(path, append_mode ? "a" : "w");
    if (!fp) {
        perror(path);
        return 0;
    }

    if (!append_mode) {
        time_t t0 = time(NULL);
        fprintf(fp,
            "# link56_cuda GPU structure matches (MC 1.17.1)\n"
            "# started %s"
            "# struct-range=[%" PRIu64 ", %" PRIu64 ") region-grid=0..%d loot-targets=%d\n"
            "# Next: desert_pyramid_56.exe --link this_file for world seed + biome\n",
            ctime(&t0), struct_lo, struct_hi, reg_grid - 1, n_loot);
    }

    for (int i = 0; i < count; i++) {
        fprintf(fp,
            "structureSeed=%" PRIu64 " lootTableSeed=%" PRIu64
            " chest=%d region=(%d,%d) pos=(%d,%d) /tp %d 90 %d\n",
            hits[i].structure_seed, hits[i].loot_seed,
            hits[i].chest, hits[i].reg_x, hits[i].reg_z,
            hits[i].block_x, hits[i].block_z,
            hits[i].block_x, hits[i].block_z);
    }

    fclose(fp);
    return 1;
}

static void query_device(int device)
{
    cudaDeviceProp prop;
    CUDA_CHECK(cudaGetDeviceProperties(&prop, device));
    fprintf(stderr,
        "[cuda] device %d: %s (compute %d.%d, %.1f GB)\n",
        device, prop.name, prop.major, prop.minor,
        prop.totalGlobalMem / (1024.0 * 1024.0 * 1024.0));
}

int main(int argc, char **argv)
{
    const char *loot_file = NULL;
    uint64_t struct_lo = 0;
    uint64_t struct_hi = 0;
    int have_struct_range = 0;
    const char *out_path = "link56_hits.txt";
    int reg_grid = DEFAULT_REGION_GRID;
    uint64_t batch_struct_seeds = DEFAULT_BATCH_STRUCT_SEEDS;
    int block_size = DEFAULT_BLOCK_SIZE;
    int grid_size = DEFAULT_GRID_SIZE;
    int append_mode = 0;
    int device = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--loot-file") && i + 1 < argc) {
            loot_file = argv[++i];
        } else if (!strcmp(argv[i], "--struct-range") && i + 2 < argc) {
            struct_lo = strtoull(argv[++i], NULL, 0);
            struct_hi = strtoull(argv[++i], NULL, 0);
            have_struct_range = 1;
        } else if (!strcmp(argv[i], "--out") && i + 1 < argc) {
            out_path = argv[++i];
        } else if (!strcmp(argv[i], "--region-grid") && i + 1 < argc) {
            reg_grid = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--batch-struct-seeds") && i + 1 < argc) {
            batch_struct_seeds = strtoull(argv[++i], NULL, 0);
        } else if (!strcmp(argv[i], "--block-size") && i + 1 < argc) {
            block_size = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--grid-size") && i + 1 < argc) {
            grid_size = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--append")) {
            append_mode = 1;
        } else if (!strcmp(argv[i], "--device") && i + 1 < argc) {
            device = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            print_usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            print_usage(argv[0]);
            return 1;
        }
    }

    if (!loot_file || !have_struct_range || struct_hi <= struct_lo) {
        fprintf(stderr, "Error: --loot-file PATH and --struct-range LO HI required (HI > LO)\n");
        print_usage(argv[0]);
        return 1;
    }

    if (reg_grid <= 0 || reg_grid > 512) {
        fprintf(stderr, "Error: --region-grid must be in 1..512\n");
        return 1;
    }

    if (block_size <= 0 || grid_size <= 0 || batch_struct_seeds == 0) {
        fprintf(stderr, "Error: batch/block/grid must be positive\n");
        return 1;
    }

    uint64_t loot_targets[MAX_LOOT_TARGETS];
    int n_loot_targets = 0;
    if (!load_loot_file(loot_file, loot_targets, MAX_LOOT_TARGETS, &n_loot_targets)) {
        fprintf(stderr, "Error: no loot seeds loaded from %s\n", loot_file);
        return 1;
    }

    const uint64_t regions_per_seed = (uint64_t)reg_grid * (uint64_t)reg_grid;
    const uint64_t launch_threads = (uint64_t)block_size * (uint64_t)grid_size;

    CUDA_CHECK(cudaSetDevice(device));
    query_device(device);

    uint64_t *d_loot_targets = NULL;
    unsigned long long *d_checked = NULL;
    int *d_hit_count = NULL;
    LinkHit *d_hits = NULL;

    CUDA_CHECK(cudaMalloc(&d_loot_targets, (size_t)n_loot_targets * sizeof(uint64_t)));
    CUDA_CHECK(cudaMalloc(&d_checked, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc(&d_hit_count, sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_hits, (size_t)MAX_HITS * sizeof(LinkHit)));

    CUDA_CHECK(cudaMemcpy(
        d_loot_targets, loot_targets, (size_t)n_loot_targets * sizeof(uint64_t),
        cudaMemcpyHostToDevice));

    LinkHit *h_hits = (LinkHit *)calloc((size_t)MAX_HITS, sizeof(LinkHit));
    if (!h_hits) {
        fprintf(stderr, "calloc failed\n");
        return 1;
    }

    const uint64_t struct_span = struct_hi - struct_lo;
    const uint64_t total_pairs = struct_span * regions_per_seed;
    unsigned long long checked_total = 0;
    int hits_written = 0;
    int first_write = !append_mode;
    double start = now_seconds();
    double last_report = start;

    fprintf(stderr,
        "[link] loot targets=%d from %s\n"
        "[link] structureSeed=[%" PRIu64 ", %" PRIu64 ") = %" PRIu64 " seeds\n"
        "[link] region grid 0..%d x 0..%d => %" PRIu64 " regions/seed\n"
        "[link] total (seed,region) pairs = %" PRIu64 "\n"
        "[link] batch=%" PRIu64 " struct seeds (%" PRIu64 " pairs/launch)\n"
        "[link] launch block=%d grid=%d threads=%" PRIu64 " (grid-stride)\n",
        n_loot_targets, loot_file,
        struct_lo, struct_hi, struct_span,
        reg_grid - 1, reg_grid - 1, regions_per_seed,
        total_pairs,
        batch_struct_seeds, batch_struct_seeds * regions_per_seed,
        block_size, grid_size, launch_threads);

    for (uint64_t batch_lo = struct_lo; batch_lo < struct_hi; ) {
        uint64_t batch_hi = batch_lo + batch_struct_seeds;
        if (batch_hi > struct_hi)
            batch_hi = struct_hi;

        CUDA_CHECK(cudaMemset(d_checked, 0, sizeof(unsigned long long)));
        CUDA_CHECK(cudaMemset(d_hit_count, 0, sizeof(int)));

        link56_kernel<<<grid_size, block_size>>>(
            batch_lo, batch_hi, reg_grid,
            d_loot_targets, n_loot_targets,
            d_checked, d_hit_count, d_hits, MAX_HITS);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());

        unsigned long long batch_checked = 0;
        int batch_hits = 0;
        CUDA_CHECK(cudaMemcpy(&batch_checked, d_checked, sizeof(unsigned long long),
            cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(&batch_hits, d_hit_count, sizeof(int), cudaMemcpyDeviceToHost));

        if (batch_hits > MAX_HITS) {
            fprintf(stderr,
                "Warning: batch produced %d hits; truncating to %d\n",
                batch_hits, MAX_HITS);
            batch_hits = MAX_HITS;
        }

        if (batch_hits > 0) {
            CUDA_CHECK(cudaMemcpy(
                h_hits, d_hits, (size_t)batch_hits * sizeof(LinkHit),
                cudaMemcpyDeviceToHost));

            if (!write_hits_file(
                    out_path, h_hits, batch_hits, !first_write,
                    struct_lo, struct_hi, reg_grid, n_loot_targets)) {
                free(h_hits);
                return 1;
            }

            first_write = 0;
            hits_written += batch_hits;

            for (int i = 0; i < batch_hits; i++) {
                fprintf(stderr,
                    "[HIT] structureSeed=%" PRIu64 " lootTableSeed=%" PRIu64
                    " chest=%d region=(%d,%d) pos=(%d,%d)\n",
                    h_hits[i].structure_seed, h_hits[i].loot_seed,
                    h_hits[i].chest, h_hits[i].reg_x, h_hits[i].reg_z,
                    h_hits[i].block_x, h_hits[i].block_z);
            }
        }

        checked_total += batch_checked;

        const double now = now_seconds();
        if (now - last_report >= 2.0 || batch_hi >= struct_hi) {
            const double elapsed = now - start;
            const double rate = elapsed > 0 ? (double)checked_total / elapsed : 0.0;
            const double pct = total_pairs > 0
                ? 100.0 * (double)checked_total / (double)total_pairs
                : 100.0;

            fprintf(stderr,
                "[link] checked %" PRIu64 " / %" PRIu64 " pairs (%.2f%%)"
                "  hits=%d  %.2f M pairs/s  elapsed=%.1fs\n",
                checked_total, total_pairs, pct,
                hits_written, rate / 1e6, elapsed);
            last_report = now;
        }

        batch_lo = batch_hi;
    }

    const double elapsed = now_seconds() - start;
    fprintf(stderr,
        "[link] done: %" PRIu64 " pairs in %.1fs (%.2f M pairs/s), %d hits -> %s\n",
        checked_total, elapsed,
        elapsed > 0 ? (double)checked_total / elapsed / 1e6 : 0.0,
        hits_written, out_path);

    free(h_hits);
    cudaFree(d_loot_targets);
    cudaFree(d_checked);
    cudaFree(d_hit_count);
    cudaFree(d_hits);

    if (hits_written == 0)
        fprintf(stderr, "[link] finished with 0 structure matches in this range\n");

    return 0;
}
