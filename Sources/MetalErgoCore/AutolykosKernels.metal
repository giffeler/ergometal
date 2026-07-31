#include <metal_stdlib>
using namespace metal;

constant ulong B2B_IV[8] = {
    0x6a09e667f3bcc908UL, 0xbb67ae8584caa73bUL,
    0x3c6ef372fe94f82bUL, 0xa54ff53a5f1d36f1UL,
    0x510e527fade682d1UL, 0x9b05688c2b3e6c1fUL,
    0x1f83d9abfb41bd6bUL, 0x5be0cd19137e2179UL
};

inline ulong rotr64(ulong x, uint n) { return (x >> n) | (x << (64 - n)); }
inline uint bswap32(uint x) {
    return ((x & 0xffU) << 24) | ((x & 0xff00U) << 8) |
           ((x >> 8) & 0xff00U) | ((x >> 24) & 0xffU);
}
inline ulong bswap64(ulong x) {
    return (ulong(bswap32(uint(x))) << 32) | ulong(bswap32(uint(x >> 32)));
}

inline void mix(thread ulong v[16], uint a, uint b, uint c, uint d, ulong x, ulong y) {
    v[a] = v[a] + v[b] + x; v[d] = rotr64(v[d] ^ v[a], 32);
    v[c] += v[d]; v[b] = rotr64(v[b] ^ v[c], 24);
    v[a] = v[a] + v[b] + y; v[d] = rotr64(v[d] ^ v[a], 16);
    v[c] += v[d]; v[b] = rotr64(v[b] ^ v[c], 63);
}

#define B2B_ROUND(v, m, s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15) \
    mix(v,0,4,8,12,m[s0],m[s1]); mix(v,1,5,9,13,m[s2],m[s3]); \
    mix(v,2,6,10,14,m[s4],m[s5]); mix(v,3,7,11,15,m[s6],m[s7]); \
    mix(v,0,5,10,15,m[s8],m[s9]); mix(v,1,6,11,12,m[s10],m[s11]); \
    mix(v,2,7,8,13,m[s12],m[s13]); mix(v,3,4,9,14,m[s14],m[s15])

inline void compress(thread ulong h[8], thread const ulong m[16], ulong count, bool finalBlock) {
    ulong v[16];
    for (uint i = 0; i < 8; ++i) { v[i] = h[i]; v[i + 8] = B2B_IV[i]; }
    v[12] ^= count;
    if (finalBlock) v[14] = ~v[14];
    B2B_ROUND(v,m, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15);
    B2B_ROUND(v,m, 14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3);
    B2B_ROUND(v,m, 11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4);
    B2B_ROUND(v,m, 7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8);
    B2B_ROUND(v,m, 9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13);
    B2B_ROUND(v,m, 2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9);
    B2B_ROUND(v,m, 12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11);
    B2B_ROUND(v,m, 13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10);
    B2B_ROUND(v,m, 6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5);
    B2B_ROUND(v,m, 10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0);
    B2B_ROUND(v,m, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15);
    B2B_ROUND(v,m, 14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3);
    for (uint i = 0; i < 8; ++i) h[i] ^= v[i] ^ v[i + 8];
}
#undef B2B_ROUND

inline void initHash(thread ulong h[8]) {
    for (uint i = 0; i < 8; ++i) h[i] = B2B_IV[i];
    h[0] ^= 0x01010020UL;
}

inline uint digestLimb(thread const ulong h[8], uint limb) {
    uint little = uint(h[limb >> 1] >> ((limb & 1) * 32));
    return bswap32(little);
}

inline void datasetHash(
    uint index,
    uint height,
    constant const ulong *autolykosM,
    thread uint out[8])
{
    ulong h[8]; initHash(h);
    ulong m[16];
    // First eight input bytes are big-endian index and height.
    m[0] = ulong(bswap32(index)) | (ulong(bswap32(height)) << 32);
    for (uint i = 1; i < 16; ++i) m[i] = autolykosM[i - 1];
    compress(h, m, 128, false);

    // Remaining full blocks contain consecutive big-endian UInt64 values from M.
    for (uint block = 1; block < 64; ++block) {
        uint first = 15 + (block - 1) * 16;
        for (uint i = 0; i < 16; ++i) m[i] = autolykosM[first + i];
        compress(h, m, ulong((block + 1) * 128), false);
    }
    for (uint i = 0; i < 16; ++i) m[i] = 0;
    m[0] = autolykosM[1023];
    compress(h, m, 8200, true);
    for (uint i = 0; i < 8; ++i) out[i] = digestLimb(h, i);
    out[0] &= 0x00ffffffU; // drop the first digest byte
}

kernel void buildDataset(
    device uint *dataset [[buffer(0)]],
    constant uint &height [[buffer(1)]],
    constant uint &tableSize [[buffer(2)]],
    constant uint &startIndex [[buffer(3)]],
    constant const ulong *autolykosM [[buffer(4)]],
    uint localID [[thread_position_in_grid]])
{
    uint id = startIndex + localID;
    if (id >= tableSize) return;
    uint value[8]; datasetHash(id, height, autolykosM, value);
    for (uint i = 0; i < 8; ++i) dataset[id * 8 + i] = value[i];
}

// Exact BLAKE2b arithmetic represented as two 32-bit halves. Apple GPUs are
// substantially faster on these operations than on native 64-bit integer
// arithmetic; the explicit carry and cross-word rotates preserve consensus.
constant uint2 B2B_IV32[8] = {
    uint2(0xf3bcc908U, 0x6a09e667U), uint2(0x84caa73bU, 0xbb67ae85U),
    uint2(0xfe94f82bU, 0x3c6ef372U), uint2(0x5f1d36f1U, 0xa54ff53aU),
    uint2(0xade682d1U, 0x510e527fU), uint2(0x2b3e6c1fU, 0x9b05688cU),
    uint2(0xfb41bd6bU, 0x1f83d9abU), uint2(0x137e2179U, 0x5be0cd19U)
};

inline uint2 add64x32(uint2 a, uint2 b) {
    uint low = a.x + b.x;
    return uint2(low, a.y + b.y + uint(low < a.x));
}
inline uint2 add64x32(uint2 a, uint2 b, uint2 c) {
    return add64x32(add64x32(a, b), c);
}
inline uint2 rotr32x32(uint2 x) { return x.yx; }
inline uint2 rotr24x32(uint2 x) {
    return uint2((x.x >> 24) | (x.y << 8), (x.y >> 24) | (x.x << 8));
}
inline uint2 rotr16x32(uint2 x) {
    return uint2((x.x >> 16) | (x.y << 16), (x.y >> 16) | (x.x << 16));
}
inline uint2 rotr63x32(uint2 x) {
    return uint2((x.x << 1) | (x.y >> 31), (x.y << 1) | (x.x >> 31));
}
inline uint2 split64(ulong value) { return uint2(uint(value), uint(value >> 32)); }

inline void mix32x32(
    thread uint2 v[16], uint a, uint b, uint c, uint d, uint2 x, uint2 y)
{
    v[a] = add64x32(v[a], v[b], x); v[d] = rotr32x32(v[d] ^ v[a]);
    v[c] = add64x32(v[c], v[d]); v[b] = rotr24x32(v[b] ^ v[c]);
    v[a] = add64x32(v[a], v[b], y); v[d] = rotr16x32(v[d] ^ v[a]);
    v[c] = add64x32(v[c], v[d]); v[b] = rotr63x32(v[b] ^ v[c]);
}

#define B2B32_ROUND(v, m, s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15) \
    mix32x32(v,0,4,8,12,m[s0],m[s1]); mix32x32(v,1,5,9,13,m[s2],m[s3]); \
    mix32x32(v,2,6,10,14,m[s4],m[s5]); mix32x32(v,3,7,11,15,m[s6],m[s7]); \
    mix32x32(v,0,5,10,15,m[s8],m[s9]); mix32x32(v,1,6,11,12,m[s10],m[s11]); \
    mix32x32(v,2,7,8,13,m[s12],m[s13]); mix32x32(v,3,4,9,14,m[s14],m[s15])

inline void compress32x32(
    thread uint2 h[8], thread const uint2 m[16], uint count, bool finalBlock)
{
    uint2 v[16];
    for (uint i = 0; i < 8; ++i) { v[i] = h[i]; v[i + 8] = B2B_IV32[i]; }
    v[12].x ^= count;
    if (finalBlock) v[14] = ~v[14];
    B2B32_ROUND(v,m, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15);
    B2B32_ROUND(v,m, 14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3);
    B2B32_ROUND(v,m, 11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4);
    B2B32_ROUND(v,m, 7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8);
    B2B32_ROUND(v,m, 9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13);
    B2B32_ROUND(v,m, 2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9);
    B2B32_ROUND(v,m, 12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11);
    B2B32_ROUND(v,m, 13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10);
    B2B32_ROUND(v,m, 6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5);
    B2B32_ROUND(v,m, 10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0);
    B2B32_ROUND(v,m, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15);
    B2B32_ROUND(v,m, 14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3);
    for (uint i = 0; i < 8; ++i) h[i] ^= v[i] ^ v[i + 8];
}

inline void datasetHashU32Pair(
    uint index,
    uint height,
    constant const ulong *autolykosM,
    thread uint out[8])
{
    uint2 h[8];
    for (uint i = 0; i < 8; ++i) h[i] = B2B_IV32[i];
    h[0].x ^= 0x01010020U;
    uint2 m[16];
    m[0] = uint2(bswap32(index), bswap32(height));
    for (uint i = 1; i < 16; ++i) m[i] = split64(autolykosM[i - 1]);
    compress32x32(h, m, 128U, false);
    for (uint block = 1; block < 64; ++block) {
        uint first = 15 + (block - 1) * 16;
        for (uint i = 0; i < 16; ++i) m[i] = split64(autolykosM[first + i]);
        compress32x32(h, m, (block + 1) * 128, false);
    }
    for (uint i = 0; i < 16; ++i) m[i] = uint2(0U);
    m[0] = split64(autolykosM[1023]);
    compress32x32(h, m, 8200U, true);
    for (uint i = 0; i < 8; ++i) {
        uint2 word = h[i >> 1];
        out[i] = bswap32((i & 1) == 0 ? word.x : word.y);
    }
    out[0] &= 0x00ffffffU;
}

kernel void buildDatasetU32Pair(
    device uint *dataset [[buffer(0)]],
    constant uint &height [[buffer(1)]],
    constant uint &tableSize [[buffer(2)]],
    constant uint &startIndex [[buffer(3)]],
    constant const ulong *autolykosM [[buffer(4)]],
    uint localID [[thread_position_in_grid]])
{
    uint id = startIndex + localID;
    if (id >= tableSize) return;
    uint value[8]; datasetHashU32Pair(id, height, autolykosM, value);
    for (uint i = 0; i < 8; ++i) dataset[id * 8 + i] = value[i];
}

#undef B2B32_ROUND

// The search path hashes three fixed, single-block messages for every nonce.
// Keep their BLAKE2b state in named scalars so the compiler does not have to
// materialize the generic message/state arrays used by datasetHash.
struct SearchDigest {
    ulong h0;
    ulong h1;
    ulong h2;
    ulong h3;
};

#define SEARCH_MIX(a, b, c, d, x, y) \
    do { \
        a = a + b + (x); d = rotr64(d ^ a, 32); \
        c += d; b = rotr64(b ^ c, 24); \
        a = a + b + (y); d = rotr64(d ^ a, 16); \
        c += d; b = rotr64(b ^ c, 63); \
    } while (false)

#define SEARCH_ROUND(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15) \
    SEARCH_MIX(v0,v4,v8,v12,x0,x1); SEARCH_MIX(v1,v5,v9,v13,x2,x3); \
    SEARCH_MIX(v2,v6,v10,v14,x4,x5); SEARCH_MIX(v3,v7,v11,v15,x6,x7); \
    SEARCH_MIX(v0,v5,v10,v15,x8,x9); SEARCH_MIX(v1,v6,v11,v12,x10,x11); \
    SEARCH_MIX(v2,v7,v8,v13,x12,x13); SEARCH_MIX(v3,v4,v9,v14,x14,x15)

#define SEARCH_COMPRESS(out, count, M0, M1, M2, M3, M4, M5, M6, M7, M8, M9, M10, M11, M12, M13, M14, M15) \
    do { \
        ulong v0 = B2B_IV[0] ^ 0x01010020UL; \
        ulong v1 = B2B_IV[1]; ulong v2 = B2B_IV[2]; ulong v3 = B2B_IV[3]; \
        ulong v4 = B2B_IV[4]; ulong v5 = B2B_IV[5]; ulong v6 = B2B_IV[6]; ulong v7 = B2B_IV[7]; \
        ulong v8 = B2B_IV[0]; ulong v9 = B2B_IV[1]; ulong v10 = B2B_IV[2]; ulong v11 = B2B_IV[3]; \
        ulong v12 = B2B_IV[4] ^ ulong(count); ulong v13 = B2B_IV[5]; \
        ulong v14 = ~B2B_IV[6]; ulong v15 = B2B_IV[7]; \
        SEARCH_ROUND(M0,M1,M2,M3,M4,M5,M6,M7,M8,M9,M10,M11,M12,M13,M14,M15); \
        SEARCH_ROUND(M14,M10,M4,M8,M9,M15,M13,M6,M1,M12,M0,M2,M11,M7,M5,M3); \
        SEARCH_ROUND(M11,M8,M12,M0,M5,M2,M15,M13,M10,M14,M3,M6,M7,M1,M9,M4); \
        SEARCH_ROUND(M7,M9,M3,M1,M13,M12,M11,M14,M2,M6,M5,M10,M4,M0,M15,M8); \
        SEARCH_ROUND(M9,M0,M5,M7,M2,M4,M10,M15,M14,M1,M11,M12,M6,M8,M3,M13); \
        SEARCH_ROUND(M2,M12,M6,M10,M0,M11,M8,M3,M4,M13,M7,M5,M15,M14,M1,M9); \
        SEARCH_ROUND(M12,M5,M1,M15,M14,M13,M4,M10,M0,M7,M6,M3,M9,M2,M8,M11); \
        SEARCH_ROUND(M13,M11,M7,M14,M12,M1,M3,M9,M5,M0,M15,M4,M8,M6,M2,M10); \
        SEARCH_ROUND(M6,M15,M14,M9,M11,M3,M0,M8,M12,M2,M13,M7,M1,M4,M10,M5); \
        SEARCH_ROUND(M10,M2,M8,M4,M7,M6,M1,M5,M15,M11,M9,M14,M3,M12,M13,M0); \
        SEARCH_ROUND(M0,M1,M2,M3,M4,M5,M6,M7,M8,M9,M10,M11,M12,M13,M14,M15); \
        SEARCH_ROUND(M14,M10,M4,M8,M9,M15,M13,M6,M1,M12,M0,M2,M11,M7,M5,M3); \
        (out).h0 = (B2B_IV[0] ^ 0x01010020UL) ^ v0 ^ v8; \
        (out).h1 = B2B_IV[1] ^ v1 ^ v9; \
        (out).h2 = B2B_IV[2] ^ v2 ^ v10; \
        (out).h3 = B2B_IV[3] ^ v3 ^ v11; \
    } while (false)

inline ulong packBigEndianWords(uint first, uint second) {
    return ulong(bswap32(first)) | (ulong(bswap32(second)) << 32);
}

inline SearchDigest searchMessageNonce(
    constant const uint *message,
    ulong nonce)
{
    SearchDigest digest;
    SEARCH_COMPRESS(
        digest, 40UL,
        packBigEndianWords(message[0], message[1]),
        packBigEndianWords(message[2], message[3]),
        packBigEndianWords(message[4], message[5]),
        packBigEndianWords(message[6], message[7]),
        bswap64(nonce),
        0UL, 0UL, 0UL, 0UL, 0UL, 0UL, 0UL, 0UL, 0UL, 0UL, 0UL);
    return digest;
}

inline SearchDigest searchIndexSeed(
    device const uint *dataset,
    uint firstIndex,
    constant const uint *message,
    ulong nonce)
{
    // seed = dataset[firstIndex].dropFirst() || message || nonce (71 bytes).
    device const uint *element = dataset + firstIndex * 8;
    SearchDigest digest;
    SEARCH_COMPRESS(
        digest, 71UL,
        packBigEndianWords(
            (element[0] << 8) | (element[1] >> 24),
            (element[1] << 8) | (element[2] >> 24)),
        packBigEndianWords(
            (element[2] << 8) | (element[3] >> 24),
            (element[3] << 8) | (element[4] >> 24)),
        packBigEndianWords(
            (element[4] << 8) | (element[5] >> 24),
            (element[5] << 8) | (element[6] >> 24)),
        packBigEndianWords(
            (element[6] << 8) | (element[7] >> 24),
            (element[7] << 8) | (message[0] >> 24)),
        packBigEndianWords(
            (message[0] << 8) | (message[1] >> 24),
            (message[1] << 8) | (message[2] >> 24)),
        packBigEndianWords(
            (message[2] << 8) | (message[3] >> 24),
            (message[3] << 8) | (message[4] >> 24)),
        packBigEndianWords(
            (message[4] << 8) | (message[5] >> 24),
            (message[5] << 8) | (message[6] >> 24)),
        packBigEndianWords(
            (message[6] << 8) | (message[7] >> 24),
            (message[7] << 8) | uint(nonce >> 56)),
        packBigEndianWords(uint(nonce >> 24), uint(nonce) << 8),
        0UL, 0UL, 0UL, 0UL, 0UL, 0UL, 0UL);
    return digest;
}

inline SearchDigest searchSum(thread const uint sum[8]) {
    SearchDigest digest;
    SEARCH_COMPRESS(
        digest, 32UL,
        packBigEndianWords(sum[0], sum[1]),
        packBigEndianWords(sum[2], sum[3]),
        packBigEndianWords(sum[4], sum[5]),
        packBigEndianWords(sum[6], sum[7]),
        0UL, 0UL, 0UL, 0UL, 0UL, 0UL, 0UL, 0UL, 0UL, 0UL, 0UL, 0UL);
    return digest;
}

inline void searchDigestWords(SearchDigest digest, thread uint words[8]) {
    words[0] = bswap32(uint(digest.h0));
    words[1] = bswap32(uint(digest.h0 >> 32));
    words[2] = bswap32(uint(digest.h1));
    words[3] = bswap32(uint(digest.h1 >> 32));
    words[4] = bswap32(uint(digest.h2));
    words[5] = bswap32(uint(digest.h2 >> 32));
    words[6] = bswap32(uint(digest.h3));
    words[7] = bswap32(uint(digest.h3 >> 32));
}

inline bool searchDigestBelowTarget(SearchDigest digest, constant const uint *target) {
    uint word = bswap32(uint(digest.h0));
    if (word != target[0]) return word < target[0];
    word = bswap32(uint(digest.h0 >> 32));
    if (word != target[1]) return word < target[1];
    word = bswap32(uint(digest.h1));
    if (word != target[2]) return word < target[2];
    word = bswap32(uint(digest.h1 >> 32));
    if (word != target[3]) return word < target[3];
    word = bswap32(uint(digest.h2));
    if (word != target[4]) return word < target[4];
    word = bswap32(uint(digest.h2 >> 32));
    if (word != target[5]) return word < target[5];
    word = bswap32(uint(digest.h3));
    if (word != target[6]) return word < target[6];
    return bswap32(uint(digest.h3 >> 32)) < target[7];
}

#undef SEARCH_COMPRESS
#undef SEARCH_ROUND
#undef SEARCH_MIX

kernel void searchNonces(
    device const uint *dataset [[buffer(0)]],
    constant const uint *message [[buffer(1)]],
    constant const uint *target [[buffer(2)]],
    device ulong *results [[buffer(3)]],
    device atomic_uint *resultCount [[buffer(4)]],
    constant ulong &baseNonce [[buffer(5)]],
    constant uint &tableSize [[buffer(6)]],
    uint id [[thread_position_in_grid]])
{
    ulong nonce = baseNonce + ulong(id);
    SearchDigest firstHash = searchMessageNonce(message, nonce);
    ulong tail = bswap64(firstHash.h3);
    uint firstIndex = uint(tail % ulong(tableSize));

    SearchDigest indexHash = searchIndexSeed(dataset, firstIndex, message, nonce);
    uint indexWords[8];
    searchDigestWords(indexHash, indexWords);

    uint sum[8]; for (uint i = 0; i < 8; ++i) sum[i] = 0;
    for (uint k = 0; k < 32; ++k) {
        uint wordIndex = k >> 2;
        uint shift = (k & 3) * 8;
        uint raw = shift == 0
            ? indexWords[wordIndex]
            : (indexWords[wordIndex] << shift) |
              (indexWords[(wordIndex + 1) & 7] >> (32 - shift));
        uint j = raw % tableSize;
        ulong carry = 0;
        for (int limb = 7; limb >= 0; --limb) {
            ulong total = ulong(sum[limb]) + ulong(dataset[j * 8 + uint(limb)]) + carry;
            sum[limb] = uint(total); carry = total >> 32;
        }
    }

    SearchDigest hitHash = searchSum(sum);
    if (searchDigestBelowTarget(hitHash, target)) {
        uint slot = atomic_fetch_add_explicit(resultCount, 1U, memory_order_relaxed);
        if (slot < 256) results[slot] = nonce;
    }
}
