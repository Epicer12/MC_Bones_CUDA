/*
 * GPU loot-table-seed scanner for exact 56-bone desert pyramid chests (MC 1.17.1).
 *
 * Standalone — no cubiomes/Java dependency. Clone this folder alone for Colab.
 *
 * Checks only the max-56 bones-only RNG path. Passing this filter is sufficient
 * for exact 56 bones-only on the 1.17.1 desert_pyramid table.
 *
 * Tuned for Colab NVIDIA T4 (sm_75).
 *
 * Build:
 *   make
 *   # or: nvcc -O3 -arch=sm_75 -o loot56_cuda loot56_cuda.cu
 *
 * Run:
 *   ./loot56_cuda --loot-range 0 281474976710656 --out hits.txt
 */

#include <cuda_runtime.h>

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

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

static const int POOL1_TOTAL = 232;
static const int POOL1_BONE_MIN = 50;
static const int POOL1_BONE_MAX = 74;
static const int POOL2_TOTAL = 50;
static const int POOL2_BONE_MIN = 0;
static const int POOL2_BONE_MAX = 9;

static const int MAX_HITS = 4096;

static const int DEFAULT_BLOCK_SIZE = 256;
static const int DEFAULT_GRID_SIZE = 8192;
static const int DEFAULT_SEEDS_PER_THREAD = 64;
static const uint64_t DEFAULT_BATCH_SEEDS = 256ULL * 8192ULL * 64ULL;

#define CUDA_CHECK(call)                                                       \
    do {                                                                       \
        cudaError_t err__ = (call);                                            \
        if (err__ != cudaSuccess) {                                            \
            fprintf(stderr, "CUDA error %s:%d: %s\n", __FILE__, __LINE__,      \
                cudaGetErrorString(err__));                                    \
            exit(1);                                                           \
        }                                                                      \
    } while (0)

__device__ __forceinline__ void dev_set_seed(uint64_t *seed, uint64_t value)
{
    *seed = (value ^ 0x5deece66dULL) & 0xffffffffffffULL;
}

__device__ __forceinline__ int dev_next(uint64_t *seed, int bits)
{
    *seed = (*seed * 0x5deece66dULL + 0xbULL) & 0xffffffffffffULL;
    return (int)((int64_t)*seed >> (48 - bits));
}

__device__ __forceinline__ int dev_next_int(uint64_t *seed, int n)
{
    const int m = n - 1;
    int bits, val;

    if ((m & n) == 0) {
        uint64_t x = (uint64_t)n * (uint64_t)dev_next(seed, 31);
        return (int)((int64_t)x >> 31);
    }

    do {
        bits = dev_next(seed, 31);
        val = bits % n;
    } while ((int32_t)((uint32_t)bits - (uint32_t)val + (uint32_t)m) < 0);

    return val;
}

__device__ __forceinline__ int dev_fast_rng_56_bones(uint64_t loot_table_seed)
{
    uint64_t s;
    dev_set_seed(&s, loot_table_seed);

    if (dev_next_int(&s, 3) != 2)
        return 0;

    for (int i = 0; i < 4; i++) {
        int w = dev_next_int(&s, POOL1_TOTAL);
        if (w < POOL1_BONE_MIN || w > POOL1_BONE_MAX)
            return 0;
        if (dev_next_int(&s, 3) != 2)
            return 0;
    }

    for (int i = 0; i < 4; i++) {
        int w = dev_next_int(&s, POOL2_TOTAL);
        if (w < POOL2_BONE_MIN || w > POOL2_BONE_MAX)
            return 0;
        if (dev_next_int(&s, 8) != 7)
            return 0;
    }

    return 1;
}

__global__ void scan_loot56_kernel(
    uint64_t range_lo,
    uint64_t range_hi,
    int seeds_per_thread,
    unsigned long long *checked,
    int *hit_count,
    uint64_t *hit_seeds,
    int max_hits)
{
    const uint64_t global_id =
        (uint64_t)blockIdx.x * (uint64_t)blockDim.x + (uint64_t)threadIdx.x;
    const uint64_t thread_base = range_lo + global_id * (uint64_t)seeds_per_thread;

    unsigned long long local_checked = 0;

    for (int i = 0; i < seeds_per_thread; i++) {
        uint64_t seed = thread_base + (uint64_t)i;
        if (seed >= range_hi)
            break;

        local_checked++;

        if (!dev_fast_rng_56_bones(seed))
            continue;

        int idx = atomicAdd(hit_count, 1);
        if (idx < max_hits)
            hit_seeds[idx] = seed;
    }

    if (local_checked > 0)
        atomicAdd(checked, local_checked);
}

static void print_usage(const char *prog)
{
    fprintf(stderr,
        "GPU 56-bone desert pyramid loot seed scanner (MC 1.17.1)\n"
        "\n"
        "Usage: %s --loot-range LO HI [options]\n"
        "\n"
        "Options:\n"
        "  --out PATH            output file (default: loot56_cuda_hits.txt)\n"
        "  --batch-size N        seeds per GPU launch (default: %llu)\n"
        "  --block-size N        CUDA block size (default: %d)\n"
        "  --grid-size N         CUDA grid size (default: %d)\n"
        "  --seeds-per-thread N  inner loop per thread (default: %d)\n"
        "  --append              append hits instead of overwriting output\n"
        "  --device N            CUDA device index (default: 0)\n"
        "\n"
        "Colab T4 example:\n"
        "  make && make run-t4\n",
        prog,
        (unsigned long long)DEFAULT_BATCH_SEEDS,
        DEFAULT_BLOCK_SIZE,
        DEFAULT_GRID_SIZE,
        DEFAULT_SEEDS_PER_THREAD);
}

static int append_hit_file(const char *path, const uint64_t *seeds, int count, int append_mode)
{
    FILE *fp = fopen(path, append_mode ? "a" : "w");
    if (!fp) {
        perror(path);
        return 0;
    }

    if (!append_mode)
        fprintf(fp, "# 56-bone desert pyramid loot table seeds (MC 1.17.1, GPU scan)\n");

    for (int i = 0; i < count; i++)
        fprintf(fp, "%" PRIu64 "\n", seeds[i]);

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
    uint64_t range_lo = 0;
    uint64_t range_hi = 0;
    int have_range = 0;
    const char *out_path = "loot56_cuda_hits.txt";
    uint64_t batch_size = DEFAULT_BATCH_SEEDS;
    int block_size = DEFAULT_BLOCK_SIZE;
    int grid_size = DEFAULT_GRID_SIZE;
    int seeds_per_thread = DEFAULT_SEEDS_PER_THREAD;
    int append_mode = 0;
    int device = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--loot-range") && i + 2 < argc) {
            range_lo = strtoull(argv[++i], NULL, 0);
            range_hi = strtoull(argv[++i], NULL, 0);
            have_range = 1;
        } else if (!strcmp(argv[i], "--out") && i + 1 < argc) {
            out_path = argv[++i];
        } else if (!strcmp(argv[i], "--batch-size") && i + 1 < argc) {
            batch_size = strtoull(argv[++i], NULL, 0);
        } else if (!strcmp(argv[i], "--block-size") && i + 1 < argc) {
            block_size = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--grid-size") && i + 1 < argc) {
            grid_size = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--seeds-per-thread") && i + 1 < argc) {
            seeds_per_thread = atoi(argv[++i]);
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

    if (!have_range || range_hi <= range_lo) {
        fprintf(stderr, "Error: --loot-range LO HI required (HI > LO)\n");
        print_usage(argv[0]);
        return 1;
    }

    if (block_size <= 0 || grid_size <= 0 || seeds_per_thread <= 0 || batch_size == 0) {
        fprintf(stderr, "Error: batch/block/grid/seeds-per-thread must be positive\n");
        return 1;
    }

    const uint64_t launch_seeds =
        (uint64_t)block_size * (uint64_t)grid_size * (uint64_t)seeds_per_thread;
    if (batch_size < launch_seeds)
        batch_size = launch_seeds;

    CUDA_CHECK(cudaSetDevice(device));
    query_device(device);

    unsigned long long *d_checked = NULL;
    int *d_hit_count = NULL;
    uint64_t *d_hit_seeds = NULL;

    CUDA_CHECK(cudaMalloc(&d_checked, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc(&d_hit_count, sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_hit_seeds, (size_t)MAX_HITS * sizeof(uint64_t)));

    unsigned long long h_checked_total = 0;
    int total_hits_written = 0;
    int first_write = !append_mode;
    double start = now_seconds();
    double last_report = start;

    const uint64_t total_span = range_hi - range_lo;

    fprintf(stderr,
        "[cuda] scanning [%" PRIu64 ", %" PRIu64 ") = %" PRIu64 " seeds"
        "  batch=%" PRIu64 "  launch=%" PRIu64 "  block=%d grid=%d spt=%d\n",
        range_lo, range_hi, total_span, batch_size, launch_seeds,
        block_size, grid_size, seeds_per_thread);

    for (uint64_t batch_lo = range_lo; batch_lo < range_hi; ) {
        uint64_t batch_hi = batch_lo + batch_size;
        if (batch_hi > range_hi)
            batch_hi = range_hi;

        const uint64_t batch_span = batch_hi - batch_lo;

        CUDA_CHECK(cudaMemset(d_checked, 0, sizeof(unsigned long long)));
        CUDA_CHECK(cudaMemset(d_hit_count, 0, sizeof(int)));

        scan_loot56_kernel<<<grid_size, block_size>>>(
            batch_lo, batch_hi, seeds_per_thread,
            d_checked, d_hit_count, d_hit_seeds, MAX_HITS);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());

        unsigned long long batch_checked = 0;
        int batch_hits = 0;
        CUDA_CHECK(cudaMemcpy(&batch_checked, d_checked, sizeof(unsigned long long),
            cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(&batch_hits, d_hit_count, sizeof(int), cudaMemcpyDeviceToHost));

        h_checked_total += batch_checked;

        if (batch_checked != batch_span) {
            fprintf(stderr,
                "[cuda] warning: batch checked %llu != expected %" PRIu64 "\n",
                batch_checked, batch_span);
        }

        int hits_to_copy = batch_hits;
        if (hits_to_copy > MAX_HITS)
            hits_to_copy = MAX_HITS;

        if (hits_to_copy > 0) {
            uint64_t *h_hits = (uint64_t *)malloc((size_t)hits_to_copy * sizeof(uint64_t));
            if (!h_hits) {
                fprintf(stderr, "Out of memory\n");
                return 1;
            }
            CUDA_CHECK(cudaMemcpy(h_hits, d_hit_seeds, (size_t)hits_to_copy * sizeof(uint64_t),
                cudaMemcpyDeviceToHost));

            for (int i = 0; i < hits_to_copy; i++) {
                fprintf(stderr, "[cuda] HIT lootTableSeed=%" PRIu64 "\n", h_hits[i]);
            }

            if (!append_hit_file(out_path, h_hits, hits_to_copy, first_write ? 0 : 1)) {
                free(h_hits);
                return 1;
            }
            first_write = 0;
            total_hits_written += hits_to_copy;
            free(h_hits);

            if (batch_hits > MAX_HITS) {
                fprintf(stderr,
                    "[cuda] warning: %d hits in batch, only first %d saved\n",
                    batch_hits, MAX_HITS);
            }
        }

        batch_lo = batch_hi;

        double now = now_seconds();
        if (now - last_report >= 30.0 || batch_lo >= range_hi) {
            double elapsed = now - start;
            double rate = elapsed > 0 ? (double)h_checked_total / elapsed : 0.0;
            double pct = 100.0 * (double)(batch_lo - range_lo) / (double)total_span;
            fprintf(stderr,
                "[cuda] progress %.2f%%  checked=%llu  rate=%.0f/s  hits=%d  elapsed=%.1fs\n",
                pct,
                h_checked_total,
                rate,
                total_hits_written,
                elapsed);
            last_report = now;
        }
    }

    double end = now_seconds();
    double elapsed = end - start;
    double rate = elapsed > 0 ? (double)h_checked_total / elapsed : 0.0;

    fprintf(stderr,
        "[cuda] done  checked=%llu / %" PRIu64 "  hits=%d  rate=%.0f/s  elapsed=%.1fs  out=%s\n",
        h_checked_total,
        total_span,
        total_hits_written,
        rate,
        elapsed,
        out_path);

    CUDA_CHECK(cudaFree(d_checked));
    CUDA_CHECK(cudaFree(d_hit_count));
    CUDA_CHECK(cudaFree(d_hit_seeds));

    return 0;
}
