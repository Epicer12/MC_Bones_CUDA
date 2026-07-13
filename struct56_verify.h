#ifndef STRUCT56_VERIFY_H
#define STRUCT56_VERIFY_H

#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
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

/* Returns 1 if cubiomes confirms 56 bones-only at getStructurePos + getStructurePieces. */
int struct56_cubiomes_verify(const StructHit *hit, int *bones_out);

/*
 * Re-check GPU hits with cubiomes (placement + full loot table).
 * Writes passing hits to verified_out. Returns count passed.
 */
int struct56_filter_verified(
    const StructHit *hits, int hit_count, StructHit *verified_out, int max_out);

/*
 * Sister-seed + biome search using cubiomes (like desert_pyramid_brute).
 * Returns number of world seeds written to fp.
 */
int struct56_mitm_cubiomes(
    const StructHit *hits, int hit_count, int sister_tries, FILE *fp, int append);

#ifdef __cplusplus
}
#endif

#endif
