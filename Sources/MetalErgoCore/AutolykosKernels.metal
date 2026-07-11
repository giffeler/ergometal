#include <metal_stdlib>
using namespace metal;

constant ulong B2B_IV[8] = {
    0x6a09e667f3bcc908UL, 0xbb67ae8584caa73bUL,
    0x3c6ef372fe94f82bUL, 0xa54ff53a5f1d36f1UL,
    0x510e527fade682d1UL, 0x9b05688c2b3e6c1fUL,
    0x1f83d9abfb41bd6bUL, 0x5be0cd19137e2179UL
};

constant uchar B2B_SIGMA[12][16] = {
    {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},
    {14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3},
    {11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4},
    {7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8},
    {9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13},
    {2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9},
    {12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11},
    {13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10},
    {6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5},
    {10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0},
    {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},
    {14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3}
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

inline void compress(thread ulong h[8], thread const ulong m[16], ulong count, bool finalBlock) {
    ulong v[16];
    for (uint i = 0; i < 8; ++i) { v[i] = h[i]; v[i + 8] = B2B_IV[i]; }
    v[12] ^= count;
    if (finalBlock) v[14] = ~v[14];
    for (uint r = 0; r < 12; ++r) {
        constant const uchar *s = B2B_SIGMA[r];
        mix(v,0,4,8,12,m[s[0]],m[s[1]]); mix(v,1,5,9,13,m[s[2]],m[s[3]]);
        mix(v,2,6,10,14,m[s[4]],m[s[5]]); mix(v,3,7,11,15,m[s[6]],m[s[7]]);
        mix(v,0,5,10,15,m[s[8]],m[s[9]]); mix(v,1,6,11,12,m[s[10]],m[s[11]]);
        mix(v,2,7,8,13,m[s[12]],m[s[13]]); mix(v,3,4,9,14,m[s[14]],m[s[15]]);
    }
    for (uint i = 0; i < 8; ++i) h[i] ^= v[i] ^ v[i + 8];
}

inline void initHash(thread ulong h[8]) {
    for (uint i = 0; i < 8; ++i) h[i] = B2B_IV[i];
    h[0] ^= 0x01010020UL;
}

inline void hashBytes(thread const uchar *bytes, uint length, thread ulong h[8]) {
    initHash(h);
    ulong m[16];
    for (uint i = 0; i < 16; ++i) m[i] = 0;
    for (uint i = 0; i < length; ++i) m[i >> 3] |= ulong(bytes[i]) << ((i & 7) * 8);
    compress(h, m, length, true);
}

inline uint digestLimb(thread const ulong h[8], uint limb) {
    uint little = uint(h[limb >> 1] >> ((limb & 1) * 32));
    return bswap32(little);
}

inline uchar limbByte(uint limb, uint offset) {
    return uchar(limb >> ((3 - offset) * 8));
}

inline void datasetHash(uint index, uint height, thread uint out[8]) {
    ulong h[8]; initHash(h);
    ulong m[16];
    // First eight input bytes are big-endian index and height.
    m[0] = ulong(bswap32(index)) | (ulong(bswap32(height)) << 32);
    for (uint i = 1; i < 16; ++i) m[i] = bswap64(ulong(i - 1));
    compress(h, m, 128, false);

    // Remaining full blocks contain consecutive big-endian UInt64 values from M.
    for (uint block = 1; block < 64; ++block) {
        uint first = 15 + (block - 1) * 16;
        for (uint i = 0; i < 16; ++i) m[i] = bswap64(ulong(first + i));
        compress(h, m, ulong((block + 1) * 128), false);
    }
    for (uint i = 0; i < 16; ++i) m[i] = 0;
    m[0] = bswap64(1023UL);
    compress(h, m, 8200, true);
    for (uint i = 0; i < 8; ++i) out[i] = digestLimb(h, i);
    out[0] &= 0x00ffffffU; // drop the first digest byte
}

kernel void buildDataset(
    device uint *dataset [[buffer(0)]],
    constant uint &height [[buffer(1)]],
    constant uint &tableSize [[buffer(2)]],
    uint id [[thread_position_in_grid]])
{
    if (id >= tableSize) return;
    uint value[8]; datasetHash(id, height, value);
    for (uint i = 0; i < 8; ++i) dataset[id * 8 + i] = value[i];
}

inline bool belowTarget(thread const uint hit[8], constant const uint *target) {
    for (uint i = 0; i < 8; ++i) {
        if (hit[i] != target[i]) return hit[i] < target[i];
    }
    return false;
}

kernel void searchNonces(
    device const uint *dataset [[buffer(0)]],
    constant const uint *message [[buffer(1)]],
    constant const uint *target [[buffer(2)]],
    device ulong *results [[buffer(3)]],
    device atomic_uint *resultCount [[buffer(4)]],
    constant ulong &baseNonce [[buffer(5)]],
    constant uint &height [[buffer(6)]],
    constant uint &tableSize [[buffer(7)]],
    uint id [[thread_position_in_grid]])
{
    ulong nonce = baseNonce + ulong(id);
    uchar input[128];
    for (uint i = 0; i < 32; ++i) input[i] = limbByte(message[i >> 2], i & 3);
    for (uint i = 0; i < 8; ++i) input[32 + i] = uchar(nonce >> ((7 - i) * 8));

    ulong firstHash[8]; hashBytes(input, 40, firstHash);
    ulong tail = 0;
    for (uint i = 24; i < 32; ++i) {
        uint limb = digestLimb(firstHash, i >> 2);
        tail = (tail << 8) | ulong(limbByte(limb, i & 3));
    }
    uint firstIndex = uint(tail % ulong(tableSize));

    // seed = dataset[firstIndex].dropFirst() || message || nonce (71 bytes)
    for (uint i = 1; i < 32; ++i) {
        uint limb = dataset[firstIndex * 8 + (i >> 2)];
        input[i - 1] = limbByte(limb, i & 3);
    }
    for (uint i = 0; i < 32; ++i) input[31 + i] = limbByte(message[i >> 2], i & 3);
    for (uint i = 0; i < 8; ++i) input[63 + i] = uchar(nonce >> ((7 - i) * 8));
    ulong indexHash[8]; hashBytes(input, 71, indexHash);

    uchar indexBytes[35];
    for (uint i = 0; i < 32; ++i) {
        uint limb = digestLimb(indexHash, i >> 2);
        indexBytes[i] = limbByte(limb, i & 3);
    }
    indexBytes[32] = indexBytes[0]; indexBytes[33] = indexBytes[1]; indexBytes[34] = indexBytes[2];

    uint sum[8]; for (uint i = 0; i < 8; ++i) sum[i] = 0;
    for (uint k = 0; k < 32; ++k) {
        uint raw = (uint(indexBytes[k]) << 24) | (uint(indexBytes[k + 1]) << 16) |
                   (uint(indexBytes[k + 2]) << 8) | uint(indexBytes[k + 3]);
        uint j = uint(ulong(raw) % ulong(tableSize));
        ulong carry = 0;
        for (int limb = 7; limb >= 0; --limb) {
            ulong total = ulong(sum[limb]) + ulong(dataset[j * 8 + uint(limb)]) + carry;
            sum[limb] = uint(total); carry = total >> 32;
        }
    }

    for (uint i = 0; i < 32; ++i) input[i] = limbByte(sum[i >> 2], i & 3);
    ulong hitHash[8]; hashBytes(input, 32, hitHash);
    uint hit[8]; for (uint i = 0; i < 8; ++i) hit[i] = digestLimb(hitHash, i);
    if (belowTarget(hit, target)) {
        uint slot = atomic_fetch_add_explicit(resultCount, 1U, memory_order_relaxed);
        if (slot < 256) results[slot] = nonce;
    }
}
