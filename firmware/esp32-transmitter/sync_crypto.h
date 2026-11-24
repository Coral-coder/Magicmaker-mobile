// MagicMaker SYNC v1 primitives: CRC-32/ISO-HDLC, FNV-1a 64, SHA-256, HMAC-SHA256 and a
// constant-time compare (docs/SYNC_PROTOCOL.md §2).
//
// Portable C++11, no Arduino / NimBLE / mbedtls: the hub firmware and the host tests
// (test/host, `make test`) compile exactly this code, so the shared vectors in
// tools/sync/vectors.json cover what runs on the chip. SHA-256 is only used for groupIds and the
// 40-byte HMAC challenge once per handshake, so the small software version is plenty fast on the
// ESP32 and there is no second (hardware) code path to keep in step.
//
// Header-only; every function is `inline`, so a translation unit that includes this file and
// uses nothing from it compiles to nothing (no unused-function warnings).
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace mmsync {

// ---- CRC-32/ISO-HDLC (zlib crc32): reflected poly 0x04C11DB7, init/xorout 0xFFFFFFFF ----------
// Bitwise (no 1 KB table): bodies are at most 360 bytes and a CRC is computed once per stored or
// received record.
inline uint32_t crc32Update(uint32_t crc, const uint8_t* p, size_t n) {
  crc = ~crc;
  for (size_t i = 0; i < n; i++) {
    crc ^= p[i];
    for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
  }
  return ~crc;
}

inline uint32_t crc32(const uint8_t* p, size_t n) { return crc32Update(0, p, n); }

// ---- FNV-1a 64 (the hub's key hash over the encoded key bytes, §3) ----------------------------
static const uint64_t FNV64_OFFSET = 0xCBF29CE484222325ull;
static const uint64_t FNV64_PRIME = 0x00000100000001B3ull;

inline uint64_t fnv1a64(const uint8_t* p, size_t n) {
  uint64_t h = FNV64_OFFSET;
  for (size_t i = 0; i < n; i++) {
    h ^= p[i];
    h *= FNV64_PRIME;
  }
  return h;
}

// ---- SHA-256 (FIPS 180-4) -------------------------------------------------------------------
class Sha256 {
 public:
  static const size_t DIGEST_LEN = 32;
  static const size_t BLOCK_LEN = 64;

  Sha256() { reset(); }

  void reset() {
    static const uint32_t init[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                                     0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
    memcpy(h_, init, sizeof(h_));
    bits_ = 0;
    fill_ = 0;
  }

  void update(const uint8_t* p, size_t n) {
    bits_ += (uint64_t)n * 8u;
    while (n > 0) {
      size_t take = BLOCK_LEN - fill_;
      if (take > n) take = n;
      memcpy(buf_ + fill_, p, take);
      fill_ += take;
      p += take;
      n -= take;
      if (fill_ == BLOCK_LEN) {
        block(buf_);
        fill_ = 0;
      }
    }
  }

  void finish(uint8_t out[32]) {
    const uint64_t bits = bits_;
    uint8_t pad = 0x80;
    update(&pad, 1);
    pad = 0;
    while (fill_ != 56) update(&pad, 1);
    uint8_t len[8];
    for (int i = 0; i < 8; i++) len[i] = (uint8_t)(bits >> (56 - 8 * i));
    update(len, 8);
    for (int i = 0; i < 8; i++) {
      out[4 * i] = (uint8_t)(h_[i] >> 24);
      out[4 * i + 1] = (uint8_t)(h_[i] >> 16);
      out[4 * i + 2] = (uint8_t)(h_[i] >> 8);
      out[4 * i + 3] = (uint8_t)h_[i];
    }
    reset();
  }

  static void digest(const uint8_t* p, size_t n, uint8_t out[32]) {
    Sha256 s;
    s.update(p, n);
    s.finish(out);
  }

 private:
  static uint32_t rotr(uint32_t x, int k) { return (x >> k) | (x << (32 - k)); }

  void block(const uint8_t* b) {
    static const uint32_t K[64] = {
        0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u, 0x923f82a4u,
        0xab1c5ed5u, 0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu,
        0x9bdc06a7u, 0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu,
        0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
        0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
        0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u, 0xa2bfe8a1u, 0xa81a664bu,
        0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u,
        0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
        0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u, 0x90befffau, 0xa4506cebu, 0xbef9a3f7u,
        0xc67178f2u};
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
      w[i] = ((uint32_t)b[4 * i] << 24) | ((uint32_t)b[4 * i + 1] << 16) |
             ((uint32_t)b[4 * i + 2] << 8) | (uint32_t)b[4 * i + 3];
    for (int i = 16; i < 64; i++) {
      const uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      const uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h_[0], bb = h_[1], c = h_[2], d = h_[3], e = h_[4], f = h_[5], g = h_[6],
             h = h_[7];
    for (int i = 0; i < 64; i++) {
      const uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const uint32_t ch = (e & f) ^ (~e & g);
      const uint32_t t1 = h + S1 + ch + K[i] + w[i];
      const uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const uint32_t mj = (a & bb) ^ (a & c) ^ (bb & c);
      const uint32_t t2 = S0 + mj;
      h = g;
      g = f;
      f = e;
      e = d + t1;
      d = c;
      c = bb;
      bb = a;
      a = t1 + t2;
    }
    h_[0] += a;
    h_[1] += bb;
    h_[2] += c;
    h_[3] += d;
    h_[4] += e;
    h_[5] += f;
    h_[6] += g;
    h_[7] += h;
  }

  uint32_t h_[8];
  uint64_t bits_;
  uint8_t buf_[64];
  size_t fill_;
};

// ---- HMAC-SHA256 (RFC 2104) -------------------------------------------------------------------
// The message may come in two parts (prefix ‖ data) so the 40-byte proof input needs no copy.
inline void hmacSha256(const uint8_t* key, size_t keyLen, const uint8_t* a, size_t aLen,
                       const uint8_t* b, size_t bLen, uint8_t out[32]) {
  uint8_t k[64];
  memset(k, 0, sizeof(k));
  if (keyLen > 64) {
    Sha256::digest(key, keyLen, k);
  } else if (keyLen > 0) {
    memcpy(k, key, keyLen);
  }
  uint8_t pad[64];
  for (int i = 0; i < 64; i++) pad[i] = (uint8_t)(k[i] ^ 0x36);
  Sha256 s;
  s.update(pad, 64);
  if (aLen) s.update(a, aLen);
  if (bLen) s.update(b, bLen);
  uint8_t inner[32];
  s.finish(inner);
  for (int i = 0; i < 64; i++) pad[i] = (uint8_t)(k[i] ^ 0x5c);
  s.update(pad, 64);
  s.update(inner, 32);
  s.finish(out);
  memset(k, 0, sizeof(k));
  memset(pad, 0, sizeof(pad));
}

inline void hmacSha256(const uint8_t* key, size_t keyLen, const uint8_t* data, size_t dataLen,
                       uint8_t out[32]) {
  hmacSha256(key, keyLen, data, dataLen, NULL, 0, out);
}

// Constant-time equality (proofs, §13.2): the time does not depend on where the bytes differ.
inline bool ctEqual(const uint8_t* a, const uint8_t* b, size_t n) {
  uint8_t d = 0;
  for (size_t i = 0; i < n; i++) d = (uint8_t)(d | (a[i] ^ b[i]));
  return d == 0;
}

}  // namespace mmsync
