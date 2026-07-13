/*
 * Desert pyramid overnight brute (MC 1.17.1).
 *
 * Phase 1: brute structureSeed (~48-bit) — loot filter on all 4 chests
 * Phase 2: sister-seed MITM (upper 16 bits) — biome + loot re-check
 *
 * Default: N×N structure regions from (0,0), N=4 → 16 regions.
 * Mirrors DesertPyramidAllBones.java (structure loop + WorldSeed sisters).
 */

#include "finders.h"
#include "generator.h"
#include "loot/items.h"
#include "loot/loot_tables.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>

#ifdef _WIN32
#include <process.h>
#include <windows.h>
#include <io.h>
#include <direct.h>
#else
#include <pthread.h>
#include <unistd.h>
#include <sys/stat.h>
#endif

static const int MC = MC_1_17_1;
static const int STRUCT = Desert_Pyramid;
static const int DEFAULT_REGION_GRID = 4; /* 4×4 = 16 regions: (0,0)..(3,3) */
static const int DEFAULT_SISTER_TRIES = 4096;
static const uint64_t PROGRESS_INTERVAL = 5000000ULL;

typedef struct {
    int min_bones;
    int max_bones;       /* 0 = no upper limit */
    int bones_only;      /* 1 = all stacks must be bone */
    int exact_bones;     /* if > 0, overrides min/max with exact match */
    int sister_tries;
    int region_grid;     /* search reg_x,rz in [0, region_grid) each */
    uint64_t seed_lo;
    uint64_t seed_hi;
    FILE *hits_fp;
    FILE *progress_fp;
    int thread_id;
    int thread_count;
    volatile uint64_t *checked;
    volatile uint64_t *loot_hits;
    volatile uint64_t *world_hits;
#ifdef _WIN32
    CRITICAL_SECTION *out_lock;
    CRITICAL_SECTION *loot_lock;
#else
    pthread_mutex_t *out_lock;
    pthread_mutex_t *loot_lock;
#endif
} WorkerArg;

static int count_bones(LootTableContext *ctx)
{
    int total = 0;
    for (int i = 0; i < ctx->generated_item_count; i++) {
        ItemStack *stack = &ctx->generated_items[i];
        if (get_global_item_id(ctx, stack->item) == ITEM_BONE)
            total += stack->count;
    }
    return total;
}

static int is_bones_only_chest(LootTableContext *ctx)
{
    for (int i = 0; i < ctx->generated_item_count; i++) {
        ItemStack *stack = &ctx->generated_items[i];
        if (get_global_item_id(ctx, stack->item) != ITEM_BONE)
            return 0;
    }
    return ctx->generated_item_count > 0;
}

static int chest_meets_filter(LootTableContext *ctx, uint64_t loot_seed, WorkerArg *cfg, int *bones_out)
{
#ifdef _WIN32
    EnterCriticalSection(cfg->loot_lock);
#else
    pthread_mutex_lock(cfg->loot_lock);
#endif

    set_loot_seed(ctx, loot_seed);
    generate_loot(ctx);
    int bones = count_bones(ctx);
    int ok;

    if (cfg->exact_bones > 0) {
        ok = cfg->bones_only
            ? (is_bones_only_chest(ctx) && bones == cfg->exact_bones)
            : (bones == cfg->exact_bones);
    } else {
        ok = bones >= cfg->min_bones;
        if (ok && cfg->max_bones > 0)
            ok = bones <= cfg->max_bones;
        if (ok && cfg->bones_only)
            ok = is_bones_only_chest(ctx);
    }

#ifdef _WIN32
    LeaveCriticalSection(cfg->loot_lock);
#else
    pthread_mutex_unlock(cfg->loot_lock);
#endif

    if (bones_out)
        *bones_out = bones;
    return ok;
}

static int pyramid_biome_valid(Generator *g, int block_x, int block_z)
{
    return isViableStructurePos(STRUCT, g, block_x, block_z, 0);
}

static void flush_line(FILE *fp, const char *line)
{
    if (!fp)
        return;
    fputs(line, fp);
    fflush(fp);
#ifdef _WIN32
    _commit(_fileno(fp));
#endif
}

static void append_hit(WorkerArg *cfg, uint64_t world_seed, uint64_t structure_seed,
    int reg_x, int reg_z, int chest, int bones, int block_x, int block_z)
{
    char line[512];
    snprintf(line, sizeof(line),
        "%" PRIu64 " structureSeed=%" PRIu64 " region=(%d,%d) chest=%d bones=%d /tp %d 90 %d\n",
        world_seed, structure_seed, reg_x, reg_z, chest, bones, block_x, block_z);

#ifdef _WIN32
    EnterCriticalSection(cfg->out_lock);
#else
    pthread_mutex_lock(cfg->out_lock);
#endif

    printf("%s", line);
    flush_line(cfg->hits_fp, line);

#ifdef _WIN32
    LeaveCriticalSection(cfg->out_lock);
#else
    pthread_mutex_unlock(cfg->out_lock);
#endif
}

static int resolve_world_seed(
    Generator *g,
    Piece *pieces,
    LootTableContext *ctx,
    StructureSaltConfig *ssconf,
    Pos *pos,
    WorkerArg *cfg,
    uint64_t structure_seed,
    int chest,
    int required_bones,
    uint64_t *world_out)
{
    uint64_t lower48 = structure_seed & MASK48;

    for (int upper = 0; upper < cfg->sister_tries; upper++) {
        uint64_t ws = lower48 | ((uint64_t)upper << 48);
        int bones = 0;

        int n = getStructurePieces(
            pieces, 4, STRUCT, *ssconf, NULL, MC, ws, pos->x, pos->z);
        if (n < 1 || chest >= pieces[0].chestCount)
            continue;

        if (!chest_meets_filter(ctx, pieces[0].lootSeeds[chest], cfg, &bones))
            continue;
        if (bones != required_bones)
            continue;

        applySeed(g, DIM_OVERWORLD, ws);
        if (!pyramid_biome_valid(g, pos->x, pos->z))
            continue;

        *world_out = ws;
        return 1;
    }

    return 0;
}

static void maybe_progress(WorkerArg *arg)
{
    uint64_t c = ++(*arg->checked);
    if (c % PROGRESS_INTERVAL != 0)
        return;

    char line[256];
    snprintf(line, sizeof(line),
        "progress ~%" PRIu64 " structure seeds  loot=%" PRIu64 "  world=%" PRIu64 "\n",
        c, (uint64_t)*arg->loot_hits, (uint64_t)*arg->world_hits);

    fprintf(stderr, "%s", line);

#ifdef _WIN32
    EnterCriticalSection(arg->out_lock);
#else
    pthread_mutex_lock(arg->out_lock);
#endif
    flush_line(arg->progress_fp, line);
#ifdef _WIN32
    LeaveCriticalSection(arg->out_lock);
#else
    pthread_mutex_unlock(arg->out_lock);
#endif
}

static void worker_search(WorkerArg *arg)
{
    StructureSaltConfig ssconf;
    if (!getStructureSaltConfig(STRUCT, MC, 0, &ssconf))
        return;

    LootTableContext *ctx = NULL;
    if (!init_desert_pyramid(&ctx, MC))
        return;

    Generator biome_gen;
    setupGenerator(&biome_gen, MC, 0);

    Piece pieces[4];

    for (uint64_t ss = arg->seed_lo + (uint64_t)arg->thread_id;
         ss < arg->seed_hi;
         ss += (uint64_t)arg->thread_count)
    {
        for (int reg_x = 0; reg_x < arg->region_grid; reg_x++) {
            for (int reg_z = 0; reg_z < arg->region_grid; reg_z++) {
                Pos pos;
                if (!getStructurePos(STRUCT, MC, ss, reg_x, reg_z, &pos))
                    continue;

                int n = getStructurePieces(
                    pieces, 4, STRUCT, ssconf, NULL, MC, ss, pos.x, pos.z);
                if (n < 1)
                    continue;

                Piece *pyramid = &pieces[0];
                int match_chest = -1;
                int match_bones = 0;

                for (int c = 0; c < pyramid->chestCount; c++) {
                    int bones = 0;
                    if (chest_meets_filter(ctx, pyramid->lootSeeds[c], arg, &bones)) {
                        match_chest = c;
                        match_bones = bones;
                        break;
                    }
                }

                if (match_chest < 0)
                    continue;

                (*arg->loot_hits)++;

                uint64_t world_seed = 0;
                if (!resolve_world_seed(
                        &biome_gen, pieces, ctx, &ssconf, &pos, arg,
                        ss, match_chest, match_bones, &world_seed))
                    continue;

                (*arg->world_hits)++;
                append_hit(arg, world_seed, ss, reg_x, reg_z,
                    match_chest, match_bones, pos.x, pos.z);
            }
        }

        maybe_progress(arg);
    }
}

#ifdef _WIN32
static unsigned __stdcall worker_thread(void *vp)
{
    worker_search((WorkerArg *)vp);
    return 0;
}
#else
static void *worker_thread(void *vp)
{
    worker_search((WorkerArg *)vp);
    return NULL;
}
#endif

static int thread_count_default(void)
{
#ifdef _WIN32
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return (int)si.dwNumberOfProcessors;
#else
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int)n : 4;
#endif
}

static int mkdir_one(const char *dir)
{
    if (!dir || !*dir)
        return 0;
#ifdef _WIN32
    if (_mkdir(dir) == 0)
        return 0;
#else
    if (mkdir(dir, 0755) == 0)
        return 0;
#endif
    return errno == EEXIST ? 0 : -1;
}

static int ensure_parent_dir(const char *file_path)
{
    char buf[4096];
    size_t n = strlen(file_path);

    if (n == 0 || n >= sizeof(buf))
        return -1;
    memcpy(buf, file_path, n + 1);

    char *last_sep = NULL;
    for (char *p = buf; *p; p++) {
        if (*p == '/' || *p == '\\')
            last_sep = p;
    }
    if (!last_sep)
        return 0;
    *last_sep = '\0';
    if (buf[0] == '\0')
        return 0;

    char build[4096];
    build[0] = '\0';

    const char *p = buf;
    if (p[0] && p[1] == ':' && (p[2] == '/' || p[2] == '\\')) {
        build[0] = p[0];
        build[1] = ':';
        build[2] = p[2];
        build[3] = '\0';
        p += 3;
    } else if (*p == '/' || *p == '\\') {
        build[0] = *p;
        build[1] = '\0';
        p++;
    }

    while (*p) {
        const char *start = p;
        while (*p && *p != '/' && *p != '\\')
            p++;
        size_t len = (size_t)(p - start);
        if (len > 0) {
            size_t blen = strlen(build);
            if (blen > 0 && build[blen - 1] != '/' && build[blen - 1] != '\\') {
#ifdef _WIN32
                strcat(build, "\\");
#else
                strcat(build, "/");
#endif
            }
            strncat(build, start, len);
            if (mkdir_one(build) != 0)
                return -1;
        }
        if (*p)
            p++;
    }

    return 0;
}

static FILE *open_output_file(const char *path)
{
    if (ensure_parent_dir(path) != 0) {
        fprintf(stderr, "could not create directory for %s: %s\n",
            path, strerror(errno));
        return NULL;
    }
    FILE *fp = fopen(path, "w");
    if (!fp) {
        perror(path);
        return NULL;
    }
    setvbuf(fp, NULL, _IONBF, 0);
    return fp;
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "Desert pyramid brute finder (MC 1.17.1)\n"
        "  structureSeed loop + sister-seed biome MITM\n\n"
        "Usage: %s [options]\n\n"
        "Options:\n"
        "  --regions N            N×N grid from (0,0), e.g. 4 = 16 regions [default: 4]\n"
        "  --struct-range LO HI   structure seeds [default: 0 100000000]\n"
        "  --min-bones N          minimum bones [default: 40]\n"
        "  --max-bones N          maximum bones, 0=none [default: 56]\n"
        "  --exact N              exact bone count (overrides min/max)\n"
        "  --any-loot             count total bones, allow non-bone items\n"
        "  --sisters N            upper-16 search limit [default: 4096]\n"
        "  --threads N            worker threads [default: CPU count]\n"
        "  --out FILE             hit log [default: seeds/brute_out.txt]\n"
        "  --progress-out FILE    progress log [default: seeds/brute_progress.txt]\n"
        "  (each hit is flushed to disk immediately)\n",
        prog);
}

int main(int argc, char **argv)
{
    uint64_t seed_lo = 0;
    uint64_t seed_hi = 100000000ULL;
    int min_bones = 40;
    int max_bones = 56;
    int exact_bones = 0;
    int bones_only = 1;
    int sister_tries = DEFAULT_SISTER_TRIES;
    int region_grid = DEFAULT_REGION_GRID;
    int threads = thread_count_default();
    const char *out_path = "seeds/brute_out.txt";
    const char *progress_path = "seeds/brute_progress.txt";

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else if (!strcmp(argv[i], "--regions") && i + 1 < argc) {
            region_grid = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--struct-range") && i + 2 < argc) {
            seed_lo = strtoull(argv[++i], NULL, 10);
            seed_hi = strtoull(argv[++i], NULL, 10);
        } else if (!strcmp(argv[i], "--min-bones") && i + 1 < argc) {
            min_bones = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--max-bones") && i + 1 < argc) {
            max_bones = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--exact") && i + 1 < argc) {
            exact_bones = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--any-loot")) {
            bones_only = 0;
        } else if (!strcmp(argv[i], "--sisters") && i + 1 < argc) {
            sister_tries = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--threads") && i + 1 < argc) {
            threads = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--out") && i + 1 < argc) {
            out_path = argv[++i];
        } else if (!strcmp(argv[i], "--progress-out") && i + 1 < argc) {
            progress_path = argv[++i];
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            usage(argv[0]);
            return 1;
        }
    }

    if (seed_hi <= seed_lo) {
        fprintf(stderr, "struct-range: HI must be greater than LO\n");
        return 1;
    }
    if (threads < 1)
        threads = 1;
    if (region_grid < 1)
        region_grid = 1;

    FILE *hits_fp = open_output_file(out_path);
    if (!hits_fp)
        return 1;

    FILE *progress_fp = open_output_file(progress_path);
    if (!progress_fp) {
        fclose(hits_fp);
        return 1;
    }

    time_t t0 = time(NULL);
    fprintf(hits_fp,
        "# desert_pyramid_brute started %s"
        "# structureSeed=[%" PRIu64 ", %" PRIu64 ") regions=%dx%d (0..%d,0..%d)\n",
        ctime(&t0), seed_lo, seed_hi, region_grid, region_grid,
        region_grid - 1, region_grid - 1);
    fflush(hits_fp);

    fprintf(progress_fp,
        "# progress log started %s", ctime(&t0));
    fflush(progress_fp);

    fprintf(stderr,
        "desert_pyramid_brute (MC 1.17.1)\n"
        "  structureSeed=[%" PRIu64 ", %" PRIu64 ")  regions=%dx%d (%d total)\n"
        "  sisters=%d  threads=%d  progress every %" PRIu64 "M seeds\n"
        "  hits file:     %s\n"
        "  progress file: %s\n",
        seed_lo, seed_hi, region_grid, region_grid, region_grid * region_grid,
        sister_tries, threads, PROGRESS_INTERVAL / 1000000ULL,
        out_path, progress_path);

    if (exact_bones > 0) {
        fprintf(stderr, "  filter: %s exact %d bones\n",
            bones_only ? "bones-only," : "any-loot,", exact_bones);
    } else {
        fprintf(stderr, "  filter: %s bones %d .. %d\n",
            bones_only ? "bones-only," : "any-loot,",
            min_bones, max_bones > 0 ? max_bones : 999);
    }

    volatile uint64_t checked = 0;
    volatile uint64_t loot_hits = 0;
    volatile uint64_t world_hits = 0;

#ifdef _WIN32
    CRITICAL_SECTION out_lock, loot_lock;
    InitializeCriticalSection(&out_lock);
    InitializeCriticalSection(&loot_lock);
#else
    pthread_mutex_t out_lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_t loot_lock = PTHREAD_MUTEX_INITIALIZER;
#endif

    time_t t0_run = t0;

#ifdef _WIN32
    HANDLE *handles = calloc((size_t)threads, sizeof(HANDLE));
    WorkerArg *args = calloc((size_t)threads, sizeof(WorkerArg));
    for (int i = 0; i < threads; i++) {
        args[i] = (WorkerArg){
            .min_bones = min_bones, .max_bones = max_bones,
            .bones_only = bones_only, .exact_bones = exact_bones,
            .sister_tries = sister_tries,
            .region_grid = region_grid,
            .seed_lo = seed_lo, .seed_hi = seed_hi,
            .hits_fp = hits_fp, .progress_fp = progress_fp,
            .thread_id = i, .thread_count = threads,
            .checked = &checked, .loot_hits = &loot_hits, .world_hits = &world_hits,
            .out_lock = &out_lock, .loot_lock = &loot_lock
        };
        handles[i] = (HANDLE)_beginthreadex(NULL, 0, worker_thread, &args[i], 0, NULL);
    }
    WaitForMultipleObjects((DWORD)threads, handles, TRUE, INFINITE);
    for (int i = 0; i < threads; i++)
        CloseHandle(handles[i]);
    free(handles);
    free(args);
#else
    pthread_t *tid = calloc((size_t)threads, sizeof(pthread_t));
    WorkerArg *args = calloc((size_t)threads, sizeof(WorkerArg));
    for (int i = 0; i < threads; i++) {
        args[i] = (WorkerArg){
            .min_bones = min_bones, .max_bones = max_bones,
            .bones_only = bones_only, .exact_bones = exact_bones,
            .sister_tries = sister_tries,
            .region_grid = region_grid,
            .seed_lo = seed_lo, .seed_hi = seed_hi,
            .hits_fp = hits_fp, .progress_fp = progress_fp,
            .thread_id = i, .thread_count = threads,
            .checked = &checked, .loot_hits = &loot_hits, .world_hits = &world_hits,
            .out_lock = &out_lock, .loot_lock = &loot_lock
        };
        pthread_create(&tid[i], NULL, worker_thread, &args[i]);
    }
    for (int i = 0; i < threads; i++)
        pthread_join(tid[i], NULL);
    free(tid);
    free(args);
#endif

    time_t elapsed = time(NULL) - t0_run;
    fprintf(stderr,
        "done in %llds — structure checked ~%" PRIu64
        " (striped), loot hits=%" PRIu64 ", world hits=%" PRIu64 "\n",
        (long long)elapsed, (uint64_t)checked, (uint64_t)loot_hits, (uint64_t)world_hits);

    fprintf(hits_fp,
        "# finished in %llds  loot=%" PRIu64 "  world=%" PRIu64 "\n",
        (long long)elapsed, (uint64_t)loot_hits, (uint64_t)world_hits);
    fprintf(progress_fp,
        "# finished in %llds  checked~%" PRIu64 "  loot=%" PRIu64 "  world=%" PRIu64 "\n",
        (long long)elapsed, (uint64_t)checked, (uint64_t)loot_hits, (uint64_t)world_hits);
    fflush(hits_fp);
    fflush(progress_fp);
    fclose(hits_fp);
    fclose(progress_fp);

    return 0;
}
