#ifndef LINK56_RNG_CUH
#define LINK56_RNG_CUH

#include <stdint.h>

/* MC 1.17.1 Java Random + desert pyramid placement (matches cubiomes finders.h). */

#define LINK56_K 0x5deece66dULL
#define LINK56_M 0xffffffffffffULL
#define LINK56_B 0xbULL

static __device__ __forceinline__ void l56_set_seed(uint64_t *s, uint64_t v)
{
    *s = (v ^ LINK56_K) & LINK56_M;
}

static __device__ __forceinline__ int l56_next(uint64_t *s, int bits)
{
    *s = (*s * LINK56_K + LINK56_B) & LINK56_M;
    return (int)((int64_t)*s >> (48 - bits));
}

static __device__ __forceinline__ int l56_next_int(uint64_t *s, int n)
{
    const int m = n - 1;
    int bits, val;
    if ((m & n) == 0) {
        uint64_t x = (uint64_t)n * (uint64_t)l56_next(s, 31);
        return (int)((int64_t)x >> 31);
    }
    do {
        bits = l56_next(s, 31);
        val = bits % n;
    } while ((int32_t)((uint32_t)bits - (uint32_t)val + (uint32_t)m) < 0);
    return val;
}

static __device__ __forceinline__ uint64_t l56_next_long(uint64_t *s)
{
    return ((uint64_t)l56_next(s, 32) << 32) + (uint64_t)l56_next(s, 32);
}

static __device__ __forceinline__ uint64_t l56_population_seed(uint64_t ws, int x, int z)
{
    uint64_t s;
    l56_set_seed(&s, ws);
    uint64_t a = l56_next_long(&s);
    uint64_t b = l56_next_long(&s);
    a |= 1ULL;
    b |= 1ULL;
    return ((uint64_t)x * a + (uint64_t)z * b) ^ ws;
}

/* Desert pyramid: salt=14357617, regionSize=32, chunkRange=24 (power of 2). */
static __device__ __forceinline__ void l56_desert_pyramid_pos(
    uint64_t seed, int reg_x, int reg_z, int *block_x, int *block_z)
{
    const uint64_t salt = 14357617ULL;
    const int region_size = 32;
    const int chunk_range = 24;

    uint64_t s = seed + (uint64_t)reg_x * 341873128712ULL
        + (uint64_t)reg_z * 132897987541ULL + salt;
    s = (s ^ LINK56_K) & LINK56_M;
    s = (s * LINK56_K + LINK56_B) & LINK56_M;

    int cx = (int)((chunk_range * (s >> 17)) >> 31);
    s = (s * LINK56_K + LINK56_B) & LINK56_M;
    int cz = (int)((chunk_range * (s >> 17)) >> 31);

    *block_x = (reg_x * region_size + cx) << 4;
    *block_z = (reg_z * region_size + cz) << 4;
}

/* Returns 4 loot table seeds (decorator salt 40003 for MC 1.17.1 desert pyramid). */
static __device__ __forceinline__ void l56_desert_loot_seeds(
    uint64_t structure_seed, int block_x, int block_z, uint64_t out[4])
{
    int min_x = block_x & ~15;
    int min_z = block_z & ~15;
    uint64_t pop = l56_population_seed(structure_seed, min_x, min_z);
    uint64_t s;
    l56_set_seed(&s, pop + 40003ULL);
    for (int i = 0; i < 4; i++)
        out[i] = l56_next_long(&s);
}

#endif
