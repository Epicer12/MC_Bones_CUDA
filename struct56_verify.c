/*
 * Cubiomes verification for struct56_cuda GPU hits (MC 1.17.1).
 */

#include "struct56_verify.h"

#include "finders.h"
#include "generator.h"
#include "loot/items.h"
#include "loot/loot_tables.h"

#include <inttypes.h>
#include <string.h>

static const int MC = MC_1_17_1;
static const int STRUCT = Desert_Pyramid;

static int is_bones_only(LootTableContext *ctx, int target_bones)
{
    int bones = 0;
    for (int i = 0; i < ctx->generated_item_count; i++) {
        ItemStack *stack = &ctx->generated_items[i];
        if (get_global_item_id(ctx, stack->item) == ITEM_BONE)
            bones += stack->count;
        else
            return 0;
    }
    return bones == target_bones;
}

static int chest_bones(LootTableContext *ctx, uint64_t loot_seed, int *bones_only)
{
    set_loot_seed(ctx, loot_seed);
    generate_loot(ctx);
    int bones = 0;
    *bones_only = 1;
    for (int i = 0; i < ctx->generated_item_count; i++) {
        ItemStack *stack = &ctx->generated_items[i];
        if (get_global_item_id(ctx, stack->item) == ITEM_BONE)
            bones += stack->count;
        else
            *bones_only = 0;
    }
    return bones;
}

static int find_56_bone_chest(
    uint64_t ws, const Pos *pos, StructureSaltConfig *ssconf,
    LootTableContext *ctx, int *chest_out, uint64_t *loot_out, int *bones_out)
{
    Piece pieces[4];
    int n = getStructurePieces(
        pieces, 4, STRUCT, *ssconf, NULL, MC, ws, pos->x, pos->z);
    if (n < 1)
        return 0;

    Piece *p = &pieces[0];
    for (int c = 0; c < p->chestCount; c++) {
        int bones_only = 0;
        int bones = chest_bones(ctx, p->lootSeeds[c], &bones_only);
        if (bones == 56 && bones_only) {
            *chest_out = c;
            *loot_out = p->lootSeeds[c];
            *bones_out = bones;
            return 1;
        }
    }
    return 0;
}

int struct56_cubiomes_verify(const StructHit *hit, int *bones_out)
{
    Pos pos;
    if (!getStructurePos(STRUCT, MC, hit->structure_seed, hit->reg_x, hit->reg_z, &pos))
        return 0;

    if (pos.x != hit->block_x || pos.z != hit->block_z)
        return 0;

    StructureSaltConfig ssconf;
    if (!getStructureSaltConfig(STRUCT, MC, 0, &ssconf))
        return 0;

    LootTableContext *ctx = NULL;
    if (!init_desert_pyramid(&ctx, MC))
        return 0;

    int chest = -1;
    uint64_t loot = 0;
    int bones = 0;
    int ok = find_56_bone_chest(
        hit->structure_seed, &pos, &ssconf, ctx, &chest, &loot, &bones);

    if (ok && bones_out)
        *bones_out = bones;

    return ok;
}

int struct56_filter_verified(
    const StructHit *hits, int hit_count, StructHit *verified_out, int max_out)
{
    int passed = 0;
    int rejected_pos = 0;
    int rejected_loot = 0;

    for (int i = 0; i < hit_count; i++) {
        Pos pos;
        getStructurePos(STRUCT, MC, hits[i].structure_seed, hits[i].reg_x, hits[i].reg_z, &pos);

        if (pos.x != hits[i].block_x || pos.z != hits[i].block_z) {
            rejected_pos++;
            fprintf(stderr,
                "[verify] REJECT placement GPU=(%d,%d) cubiomes=(%d,%d) ss=%" PRIu64 "\n",
                hits[i].block_x, hits[i].block_z, pos.x, pos.z, hits[i].structure_seed);
            continue;
        }

        int bones = 0;
        if (!struct56_cubiomes_verify(&hits[i], &bones)) {
            rejected_loot++;
            fprintf(stderr,
                "[verify] REJECT loot ss=%" PRIu64 " pos=(%d,%d) gpu_loot=%" PRIu64 "\n",
                hits[i].structure_seed, pos.x, pos.z, hits[i].loot_seed);
            continue;
        }

        if (passed < max_out)
            verified_out[passed] = hits[i];

        fprintf(stderr,
            "[verify] PASS ss=%" PRIu64 " chest=%d bones=%d pos=(%d,%d)\n",
            hits[i].structure_seed, hits[i].chest, bones, pos.x, pos.z);
        passed++;
    }

    fprintf(stderr,
        "[verify] %d/%d passed (%d bad placement, %d bad loot)\n",
        passed, hit_count, rejected_pos, rejected_loot);

    return passed;
}

int struct56_mitm_cubiomes(
    const StructHit *hits, int hit_count, int sister_tries, FILE *fp, int append)
{
    if (!append) {
        fprintf(fp,
            "# struct56_cuda cubiomes MITM (placement + loot + desert biome)\n");
    }

    StructureSaltConfig ssconf;
    if (!getStructureSaltConfig(STRUCT, MC, 0, &ssconf))
        return 0;

    LootTableContext *ctx = NULL;
    if (!init_desert_pyramid(&ctx, MC))
        return 0;

    Generator g;
    setupGenerator(&g, MC, 0);

    int world_hits = 0;

    for (int h = 0; h < hit_count; h++) {
        const StructHit *hit = &hits[h];
        const uint64_t lower48 = hit->structure_seed & MASK48;

        fprintf(stderr, "[mitm] hit %d/%d ss=%" PRIu64 " region=(%d,%d)\n",
            h + 1, hit_count, hit->structure_seed, hit->reg_x, hit->reg_z);

        int found = 0;
        for (int upper = 0; upper < sister_tries; upper++) {
            const uint64_t ws = lower48 | ((uint64_t)upper << 48);
            Pos pos;
            if (!getStructurePos(STRUCT, MC, ws, hit->reg_x, hit->reg_z, &pos))
                continue;

            int chest = -1;
            uint64_t loot = 0;
            int bones = 0;
            if (!find_56_bone_chest(ws, &pos, &ssconf, ctx, &chest, &loot, &bones))
                continue;

            applySeed(&g, DIM_OVERWORLD, ws);
            if (!isViableStructurePos(STRUCT, &g, pos.x, pos.z, 0))
                continue;

            fprintf(fp,
                "worldSeed=%" PRIu64 " structureSeed=%" PRIu64
                " lootTableSeed=%" PRIu64 " chest=%d region=(%d,%d)"
                " pos=(%d,%d) /tp %d 90 %d\n",
                ws, hit->structure_seed, loot, chest,
                hit->reg_x, hit->reg_z, pos.x, pos.z, pos.x, pos.z);
            fprintf(stderr,
                "[mitm]   worldSeed=%" PRIu64 " pos=(%d,%d) chest=%d\n",
                ws, pos.x, pos.z, chest);
            world_hits++;
            found = 1;
        }

        if (!found)
            fprintf(stderr, "[mitm]   no biome-valid sister in %d tries\n", sister_tries);
    }

    fprintf(stderr, "[mitm] %d world candidates (cubiomes)\n", world_hits);
    return world_hits;
}
