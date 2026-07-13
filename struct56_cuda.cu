/*
 * GPU structure-seed scanner for 56-bone desert pyramid chests (MC 1.17.1).
 *
 * Structure-first brute (like desert_pyramid_brute phase 1) at loot56_cuda speed:
 * for each structureSeed in [LO, HI), place pyramid in region (RX,RZ), compute 4
 * chest loot seeds, apply fast56 filter.
 *
 * Optional --mitm: CPU sister-seed pass (4096 upper bits) re-checks loot at the
 * hit position. Biome validation still needs desert_pyramid_brute on your PC.
 *
 * Build:  make struct56_cuda
 * Run:    ./struct56_cuda --struct-range 160000000000 281474976710656 --region 0 0
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
} StructHit;

static const uint64_t MASK48 = 0xffffffffffffULL;
static const uint64_t SEED48_MAX = 1ULL << 48;
static const int MAX_HITS = 4096;
static const int DEFAULT_SISTER_TRIES = 4096;

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

__global__ void scan_struct56_kernel(
    uint64_t range_lo,
    uint64_t range_hi,
    int reg_x,
    int reg_z,
    int seeds_per_thread,
    unsigned long long *checked,
    int *hit_count,
    StructHit *hits,
    int max_hits)
{
    const uint64_t global_id =
        (uint64_t)blockIdx.x * (uint64_t)blockDim.x + (uint64_t)threadIdx.x;
    const uint64_t thread_base = range_lo + global_id * (uint64_t)seeds_per_thread;

    unsigned long long local_checked = 0;

    for (int i = 0; i < seeds_per_thread; i++) {
        const uint64_t ss = thread_base + (uint64_t)i;
        if (ss >= range_hi)
            break;

        local_checked++;

        int block_x = 0;
        int block_z = 0;
        l56_desert_pyramid_pos(ss, reg_x, reg_z, &block_x, &block_z);

        uint64_t loot_seeds[4];
        l56_desert_loot_seeds(ss, block_x, block_z, loot_seeds);

        for (int chest = 0; chest < 4; chest++) {
            if (!l56_fast_rng_56_bones(loot_seeds[chest]))
                continue;

            const int idx = atomicAdd(hit_count, 1);
            if (idx >= max_hits)
                break;

            hits[idx].structure_seed = ss;
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

/* ---------- host RNG (sister MITM, mirrors link56_rng.cuh) ---------- */

static void host_set_seed(uint64_t *s, uint64_t v)
{
    *s = (v ^ LINK56_K) & LINK56_M;
}

static int host_next(uint64_t *s, int bits)
{
    *s = (*s * LINK56_K + LINK56_B) & LINK56_M;
    return (int)((int64_t)*s >> (48 - bits));
}

static int host_next_int(uint64_t *s, int n)
{
    const int m = n - 1;
    int bits, val;
    if ((m & n) == 0) {
        uint64_t x = (uint64_t)n * (uint64_t)host_next(s, 31);
        return (int)((int64_t)x >> 31);
    }
    do {
        bits = host_next(s, 31);
        val = bits % n;
    } while ((int32_t)((uint32_t)bits - (uint32_t)val + (uint32_t)m) < 0);
    return val;
}

static uint64_t host_next_long(uint64_t *s)
{
    return ((uint64_t)host_next(s, 32) << 32) + (uint64_t)host_next(s, 32);
}

static uint64_t host_population_seed(uint64_t ws, int x, int z)
{
    uint64_t s;
    host_set_seed(&s, ws);
    uint64_t a = host_next_long(&s);
    uint64_t b = host_next_long(&s);
    a |= 1ULL;
    b |= 1ULL;
    return ((uint64_t)x * a + (uint64_t)z * b) ^ ws;
}

static void host_desert_loot_seeds(uint64_t ws, int block_x, int block_z, uint64_t out[4])
{
    int min_x = block_x & ~15;
    int min_z = block_z & ~15;
    uint64_t pop = host_population_seed(ws, min_x, min_z);
    uint64_t s;
    host_set_seed(&s, pop + 40003ULL);
    for (int i = 0; i < 4; i++)
        out[i] = host_next_long(&s);
}

static int host_fast_rng_56_bones(uint64_t loot_table_seed)
{
    const int POOL1_TOTAL = 232;
    const int POOL1_BONE_MIN = 50;
    const int POOL1_BONE_MAX = 74;
    const int POOL2_TOTAL = 50;
    const int POOL2_BONE_MIN = 0;
    const int POOL2_BONE_MAX = 9;

    uint64_t s;
    host_set_seed(&s, loot_table_seed);

    if (host_next_int(&s, 3) != 2)
        return 0;

    for (int i = 0; i < 4; i++) {
        int w = host_next_int(&s, POOL1_TOTAL);
        if (w < POOL1_BONE_MIN || w > POOL1_BONE_MAX)
            return 0;
        if (host_next_int(&s, 3) != 2)
            return 0;
    }

    for (int i = 0; i < 4; i++) {
        int w = host_next_int(&s, POOL2_TOTAL);
        if (w < POOL2_BONE_MIN || w > POOL2_BONE_MAX)
            return 0;
        if (host_next_int(&s, 8) != 7)
            return 0;
    }

    return 1;
}

static int run_sister_mitm(
    const StructHit *hits, int hit_count, int sister_tries,
    const char *mitm_out, int append_mode)
{
    FILE *fp = fopen(mitm_out, append_mode ? "a" : "w");
    if (!fp) {
        perror(mitm_out);
        return 0;
    }

    if (!append_mode) {
        fprintf(fp,
            "# struct56_cuda sister-seed MITM (loot re-check only, no biome)\n"
            "# Run desert_pyramid_brute on PC for biome-valid world seeds\n");
    }

    int world_hits = 0;

    for (int h = 0; h < hit_count; h++) {
        const StructHit *hit = &hits[h];
        const uint64_t lower48 = hit->structure_seed & MASK48;
        int found = 0;

        fprintf(stderr,
            "[mitm] hit %d/%d structureSeed=%" PRIu64 " chest=%d pos=(%d,%d)\n",
            h + 1, hit_count, hit->structure_seed, hit->chest,
            hit->block_x, hit->block_z);

        for (int upper = 0; upper < sister_tries; upper++) {
            const uint64_t ws = lower48 | ((uint64_t)upper << 48);
            uint64_t loot[4];
            host_desert_loot_seeds(ws, hit->block_x, hit->block_z, loot);

            if (loot[hit->chest] != hit->loot_seed)
                continue;
            if (!host_fast_rng_56_bones(loot[hit->chest]))
                continue;

            fprintf(fp,
                "worldSeed=%" PRIu64 " structureSeed=%" PRIu64
                " lootTableSeed=%" PRIu64 " chest=%d region=(%d,%d)"
                " pos=(%d,%d) /tp %d 90 %d\n",
                ws, hit->structure_seed, hit->loot_seed,
                hit->chest, hit->reg_x, hit->reg_z,
                hit->block_x, hit->block_z,
                hit->block_x, hit->block_z);
            fprintf(stderr, "[mitm]   worldSeed=%" PRIu64 "\n", ws);
            world_hits++;
            found = 1;
        }

        if (!found)
            fprintf(stderr, "[mitm]   no sister match in %d tries\n", sister_tries);
    }

    fclose(fp);
    fprintf(stderr, "[mitm] %d loot-valid world candidates -> %s\n", world_hits, mitm_out);
    return 1;
}

static void print_usage(const char *prog)
{
    fprintf(stderr,
        "GPU structure-seed 56-bone scanner (MC 1.17.1)\n"
        "\n"
        "Usage: %s --struct-range LO HI [options]\n"
        "\n"
        "Options:\n"
        "  --region RX RZ         structure region (default: 0 0)\n"
        "  --out PATH             structure hits (default: struct56_hits.txt)\n"
        "  --mitm                 sister-seed MITM on CPU after GPU scan\n"
        "  --mitm-out PATH        world candidates (default: struct56_mitm.txt)\n"
        "  --sister-tries N       upper-16-bit tries (default: %d)\n"
        "  --batch-size N         seeds per GPU launch (default: %llu)\n"
        "  --block-size N         CUDA block size (default: %d)\n"
        "  --grid-size N          CUDA grid size (default: %d)\n"
        "  --seeds-per-thread N   inner loop per thread (default: %d)\n"
        "  --append               append hits instead of overwrite\n"
        "  --device N             CUDA device index (default: 0)\n"
        "\n"
        "Colab T4 example (region 0,0 from 160B to 2^48):\n"
        "  ./struct56_cuda --struct-range 160000000000 281474976710656 \\\n"
        "    --region 0 0 --mitm --grid-size 16384 --seeds-per-thread 128\n",
        prog,
        DEFAULT_SISTER_TRIES,
        (unsigned long long)DEFAULT_BATCH_SEEDS,
        DEFAULT_BLOCK_SIZE,
        DEFAULT_GRID_SIZE,
        DEFAULT_SEEDS_PER_THREAD);
}

static int write_struct_hits(
    const char *path, const StructHit *hits, int count, int append_mode,
    uint64_t lo, uint64_t hi, int reg_x, int reg_z)
{
    FILE *fp = fopen(path, append_mode ? "a" : "w");
    if (!fp) {
        perror(path);
        return 0;
    }

    if (!append_mode) {
        time_t t0 = time(NULL);
        fprintf(fp,
            "# struct56_cuda structure hits (MC 1.17.1, fast56)\n"
            "# started %s"
            "# struct-range=[%" PRIu64 ", %" PRIu64 ") region=(%d,%d)\n",
            ctime(&t0), lo, hi, reg_x, reg_z);
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
    uint64_t range_lo = 160000000000ULL;
    uint64_t range_hi = SEED48_MAX;
    int have_range = 0;
    int reg_x = 0;
    int reg_z = 0;
    const char *out_path = "struct56_hits.txt";
    const char *mitm_out_path = "struct56_mitm.txt";
    int do_mitm = 0;
    int sister_tries = DEFAULT_SISTER_TRIES;
    uint64_t batch_size = DEFAULT_BATCH_SEEDS;
    int block_size = DEFAULT_BLOCK_SIZE;
    int grid_size = DEFAULT_GRID_SIZE;
    int seeds_per_thread = DEFAULT_SEEDS_PER_THREAD;
    int append_mode = 0;
    int device = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--struct-range") && i + 2 < argc) {
            range_lo = strtoull(argv[++i], NULL, 0);
            range_hi = strtoull(argv[++i], NULL, 0);
            have_range = 1;
        } else if (!strcmp(argv[i], "--region") && i + 2 < argc) {
            reg_x = atoi(argv[++i]);
            reg_z = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--out") && i + 1 < argc) {
            out_path = argv[++i];
        } else if (!strcmp(argv[i], "--mitm")) {
            do_mitm = 1;
        } else if (!strcmp(argv[i], "--mitm-out") && i + 1 < argc) {
            mitm_out_path = argv[++i];
        } else if (!strcmp(argv[i], "--sister-tries") && i + 1 < argc) {
            sister_tries = atoi(argv[++i]);
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

    if (!have_range && argc > 1) {
        /* defaults already set for 160B..2^48 */
    }

    if (range_hi <= range_lo || range_hi > SEED48_MAX) {
        fprintf(stderr, "Error: struct-range [LO, HI) with 0 <= LO < HI <= 2^48\n");
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
    StructHit *d_hits = NULL;

    CUDA_CHECK(cudaMalloc(&d_checked, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc(&d_hit_count, sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_hits, (size_t)MAX_HITS * sizeof(StructHit)));

    StructHit *all_hits = (StructHit *)calloc((size_t)MAX_HITS, sizeof(StructHit));
    if (!all_hits) {
        fprintf(stderr, "calloc failed\n");
        return 1;
    }

    unsigned long long checked_total = 0;
    int total_hits = 0;
    int first_write = !append_mode;
    double start = now_seconds();
    double last_report = start;
    const uint64_t total_span = range_hi - range_lo;

    fprintf(stderr,
        "[struct] region=(%d,%d) struct-range=[%" PRIu64 ", %" PRIu64 ") = %" PRIu64 "\n"
        "[struct] batch=%" PRIu64 " launch=%" PRIu64 " block=%d grid=%d spt=%d\n",
        reg_x, reg_z, range_lo, range_hi, total_span,
        batch_size, launch_seeds, block_size, grid_size, seeds_per_thread);

    for (uint64_t batch_lo = range_lo; batch_lo < range_hi; ) {
        uint64_t batch_hi = batch_lo + batch_size;
        if (batch_hi > range_hi)
            batch_hi = range_hi;

        CUDA_CHECK(cudaMemset(d_checked, 0, sizeof(unsigned long long)));
        CUDA_CHECK(cudaMemset(d_hit_count, 0, sizeof(int)));

        scan_struct56_kernel<<<grid_size, block_size>>>(
            batch_lo, batch_hi, reg_x, reg_z, seeds_per_thread,
            d_checked, d_hit_count, d_hits, MAX_HITS);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());

        unsigned long long batch_checked = 0;
        int batch_hits = 0;
        CUDA_CHECK(cudaMemcpy(&batch_checked, d_checked, sizeof(unsigned long long),
            cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(&batch_hits, d_hit_count, sizeof(int), cudaMemcpyDeviceToHost));

        checked_total += batch_checked;

        int copy_n = batch_hits;
        if (copy_n > MAX_HITS - total_hits)
            copy_n = MAX_HITS - total_hits;

        if (copy_n > 0) {
            CUDA_CHECK(cudaMemcpy(
                all_hits + total_hits, d_hits, (size_t)copy_n * sizeof(StructHit),
                cudaMemcpyDeviceToHost));

            if (!write_struct_hits(
                    out_path, all_hits + total_hits, copy_n, !first_write,
                    range_lo, range_hi, reg_x, reg_z)) {
                free(all_hits);
                return 1;
            }
            first_write = 0;

            for (int i = 0; i < copy_n; i++) {
                const StructHit *hit = &all_hits[total_hits + i];
                fprintf(stderr,
                    "[HIT] structureSeed=%" PRIu64 " lootTableSeed=%" PRIu64
                    " chest=%d pos=(%d,%d)\n",
                    hit->structure_seed, hit->loot_seed,
                    hit->chest, hit->block_x, hit->block_z);
            }

            total_hits += copy_n;
        }

        if (batch_hits > copy_n) {
            fprintf(stderr,
                "[struct] warning: batch had %d hits, only %d saved (max %d)\n",
                batch_hits, copy_n, MAX_HITS);
        }

        batch_lo = batch_hi;

        const double now = now_seconds();
        if (now - last_report >= 2.0 || batch_lo >= range_hi) {
            const double elapsed = now - start;
            const double rate = elapsed > 0 ? (double)checked_total / elapsed : 0.0;
            const double pct = 100.0 * (double)(batch_lo - range_lo) / (double)total_span;

            fprintf(stderr,
                "[struct] %.2f%%  checked=%" PRIu64 "  rate=%.0f/s  hits=%d  elapsed=%.1fs\n",
                pct, checked_total, rate, total_hits, elapsed);
            last_report = now;
        }
    }

    const double elapsed = now_seconds() - start;
    fprintf(stderr,
        "[struct] done: %" PRIu64 " seeds in %.1fs (%.0f/s), %d hits -> %s\n",
        checked_total, elapsed,
        elapsed > 0 ? (double)checked_total / elapsed : 0.0,
        total_hits, out_path);

    if (total_hits == 0)
        fprintf(stderr, "[struct] no 56-bone structure hits in this range\n");

    if (do_mitm && total_hits > 0) {
        if (!run_sister_mitm(all_hits, total_hits, sister_tries, mitm_out_path, append_mode))
            fprintf(stderr, "[mitm] failed\n");
    } else if (do_mitm) {
        fprintf(stderr, "[mitm] skipped (no structure hits)\n");
    }

    free(all_hits);
    cudaFree(d_checked);
    cudaFree(d_hit_count);
    cudaFree(d_hits);

    return 0;
}
