// XXH3-128 (xxHash 0.8 family, seed 0, default secret) — the checksum Stow and
// ASC-MHL v2 use. Written from the published algorithm and checked against the
// reference implementation (see Tests/xxh3_vectors.txt) byte for byte.

import Foundation

private let P32_1: UInt64 = 0x9E37_79B1
private let P32_2: UInt64 = 0x85EB_CA77
private let P32_3: UInt64 = 0xC2B2_AE3D
private let P64_1: UInt64 = 0x9E37_79B1_85EB_CA87
private let P64_2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
private let P64_3: UInt64 = 0x1656_67B1_9E37_79F9
private let P64_4: UInt64 = 0x85EB_CA77_C2B2_AE63
private let P64_5: UInt64 = 0x27D4_EB2F_1656_67C5
private let PMX1: UInt64 = 0x1656_6791_9E37_79F9
private let PMX2: UInt64 = 0x9FB2_1C65_1E98_DF25

private let kSecret: [UInt8] = [
    0xb8, 0xfe, 0x6c, 0x39, 0x23, 0xa4, 0x4b, 0xbe, 0x7c, 0x01, 0x81, 0x2c, 0xf7, 0x21, 0xad, 0x1c,
    0xde, 0xd4, 0x6d, 0xe9, 0x83, 0x90, 0x97, 0xdb, 0x72, 0x40, 0xa4, 0xa4, 0xb7, 0xb3, 0x67, 0x1f,
    0xcb, 0x79, 0xe6, 0x4e, 0xcc, 0xc0, 0xe5, 0x78, 0x82, 0x5a, 0xd0, 0x7d, 0xcc, 0xff, 0x72, 0x21,
    0xb8, 0x08, 0x46, 0x74, 0xf7, 0x43, 0x24, 0x8e, 0xe0, 0x35, 0x90, 0xe6, 0x81, 0x3a, 0x26, 0x4c,
    0x3c, 0x28, 0x52, 0xbb, 0x91, 0xc3, 0x00, 0xcb, 0x88, 0xd0, 0x65, 0x8b, 0x1b, 0x53, 0x2e, 0xa3,
    0x71, 0x64, 0x48, 0x97, 0xa2, 0x0d, 0xf9, 0x4e, 0x38, 0x19, 0xef, 0x46, 0xa9, 0xde, 0xac, 0xd8,
    0xa8, 0xfa, 0x76, 0x3f, 0xe3, 0x9c, 0x34, 0x3f, 0xf9, 0xdc, 0xbb, 0xc7, 0xc7, 0x0b, 0x4f, 0x1d,
    0x8a, 0x51, 0xe0, 0x4b, 0xcd, 0xb4, 0x59, 0x31, 0xc8, 0x9f, 0x7e, 0xc9, 0xd9, 0x78, 0x73, 0x64,
    0xea, 0xc5, 0xac, 0x83, 0x34, 0xd3, 0xeb, 0xc3, 0xc5, 0x81, 0xa0, 0xff, 0xfa, 0x13, 0x63, 0xeb,
    0x17, 0x0d, 0xdd, 0x51, 0xb7, 0xf0, 0xda, 0x49, 0xd3, 0x16, 0x55, 0x26, 0x29, 0xd4, 0x68, 0x9e,
    0x2b, 0x16, 0xbe, 0x58, 0x7d, 0x47, 0xa1, 0xfc, 0x8f, 0xf8, 0xb8, 0xd1, 0x7a, 0xd0, 0x31, 0xce,
    0x45, 0xcb, 0x3a, 0x8f, 0x95, 0x16, 0x04, 0x28, 0xaf, 0xd7, 0xfb, 0xca, 0xbb, 0x4b, 0x40, 0x7e,
]
private let secretSize = 192
private let stripeLen = 64
private let stripesPerBlock = (secretSize - stripeLen) / 8  // 16
private let blockLen = stripeLen * stripesPerBlock          // 1024
private let midSizeMax = 240

@inline(__always) private func r64(_ p: UnsafeRawPointer, _ o: Int) -> UInt64 {
    UInt64(littleEndian: p.loadUnaligned(fromByteOffset: o, as: UInt64.self))
}
@inline(__always) private func r32(_ p: UnsafeRawPointer, _ o: Int) -> UInt32 {
    UInt32(littleEndian: p.loadUnaligned(fromByteOffset: o, as: UInt32.self))
}
@inline(__always) private func mul128(_ a: UInt64, _ b: UInt64) -> (lo: UInt64, hi: UInt64) {
    let r = a.multipliedFullWidth(by: b)
    return (r.low, r.high)
}
@inline(__always) private func fold64(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let r = mul128(a, b); return r.lo ^ r.hi
}
@inline(__always) private func rotl64(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }
@inline(__always) private func rotl32(_ x: UInt32, _ r: UInt32) -> UInt32 { (x << r) | (x >> (32 - r)) }
@inline(__always) private func xs(_ v: UInt64, _ s: UInt64) -> UInt64 { v ^ (v >> s) }

private func avalanche64(_ h0: UInt64) -> UInt64 {
    var h = h0
    h ^= h >> 33; h &*= P64_2; h ^= h >> 29; h &*= P64_3; h ^= h >> 32
    return h
}
private func avalanche3(_ h0: UInt64) -> UInt64 {
    var h = xs(h0, 37); h &*= PMX1; return xs(h, 32)
}
@inline(__always) private func mix16(_ p: UnsafeRawPointer, _ po: Int, _ s: UnsafeRawPointer, _ so: Int) -> UInt64 {
    fold64(r64(p, po) ^ r64(s, so), r64(p, po + 8) ^ r64(s, so + 8))
}
@inline(__always) private func mix32(_ acc: inout (lo: UInt64, hi: UInt64), _ p: UnsafeRawPointer,
                                     _ i1: Int, _ i2: Int, _ s: UnsafeRawPointer, _ so: Int) {
    acc.lo &+= mix16(p, i1, s, so)
    acc.lo ^= r64(p, i2) &+ r64(p, i2 + 8)
    acc.hi &+= mix16(p, i2, s, so + 16)
    acc.hi ^= r64(p, i1) &+ r64(p, i1 + 8)
}

/// Hash of inputs up to 240 bytes.
private func short128(_ p: UnsafeRawPointer, _ len: Int, _ s: UnsafeRawPointer) -> (lo: UInt64, hi: UInt64) {
    let L = UInt64(len)
    if len == 0 {
        return (avalanche64(r64(s, 64) ^ r64(s, 72)), avalanche64(r64(s, 80) ^ r64(s, 88)))
    }
    if len <= 3 {
        let b = p.assumingMemoryBound(to: UInt8.self)
        let c1 = UInt32(b[0]), c2 = UInt32(b[len >> 1]), c3 = UInt32(b[len - 1])
        let cl: UInt32 = (c1 << 16) | (c2 << 24) | c3 | (UInt32(len) << 8)
        let ch = rotl32(cl.byteSwapped, 13)
        let fl = UInt64(r32(s, 0) ^ r32(s, 4))
        let fh = UInt64(r32(s, 8) ^ r32(s, 12))
        return (avalanche64(UInt64(cl) ^ fl), avalanche64(UInt64(ch) ^ fh))
    }
    if len <= 8 {
        let inLo = UInt64(r32(p, 0)), inHi = UInt64(r32(p, len - 4))
        let in64 = inLo &+ (inHi << 32)
        let flip = r64(s, 16) ^ r64(s, 24)
        var m = mul128(in64 ^ flip, P64_1 &+ (L << 2))
        m.hi &+= m.lo << 1
        m.lo ^= m.hi >> 3
        m.lo = xs(m.lo, 35); m.lo &*= PMX2; m.lo = xs(m.lo, 28)
        return (m.lo, avalanche3(m.hi))
    }
    if len <= 16 {
        let fl = r64(s, 32) ^ r64(s, 40)
        let fh = r64(s, 48) ^ r64(s, 56)
        let inLo = r64(p, 0)
        var inHi = r64(p, len - 8)
        var m = mul128(inLo ^ inHi ^ fl, P64_1)
        m.lo &+= (L - 1) << 54
        inHi ^= fh
        m.hi &+= inHi &+ (UInt64(UInt32(truncatingIfNeeded: inHi)) &* (P32_2 - 1))
        m.lo ^= m.hi.byteSwapped
        var h = mul128(m.lo, P64_2)
        h.hi &+= m.hi &* P64_2
        return (avalanche3(h.lo), avalanche3(h.hi))
    }
    var acc: (lo: UInt64, hi: UInt64) = (L &* P64_1, 0)
    if len <= 128 {
        if len > 32 {
            if len > 64 {
                if len > 96 { mix32(&acc, p, 48, len - 64, s, 96) }
                mix32(&acc, p, 32, len - 48, s, 64)
            }
            mix32(&acc, p, 16, len - 32, s, 32)
        }
        mix32(&acc, p, 0, len - 16, s, 0)
    } else {
        let rounds = len / 32
        for i in 0..<4 { mix32(&acc, p, 32 * i, 32 * i + 16, s, 32 * i) }
        acc.lo = avalanche3(acc.lo); acc.hi = avalanche3(acc.hi)
        for i in 4..<rounds { mix32(&acc, p, 32 * i, 32 * i + 16, s, 3 + 32 * (i - 4)) }
        // Last 32 bytes, with the two halves swapped (seed 0 so no seed term).
        mix32(&acc, p, len - 16, len - 32, s, 136 - 17 - 16)
    }
    let lo = acc.lo &+ acc.hi
    let hi = (acc.lo &* P64_1) &+ (acc.hi &* P64_4) &+ (L &* P64_2)
    return (avalanche3(lo), 0 &- avalanche3(hi))
}

@inline(__always) private func accumulate512(_ acc: UnsafeMutablePointer<UInt64>, _ p: UnsafeRawPointer, _ po: Int,
                                             _ s: UnsafeRawPointer, _ so: Int) {
    for i in 0..<8 {
        let v = r64(p, po + 8 * i)
        let k = v ^ r64(s, so + 8 * i)
        acc[i ^ 1] &+= v
        acc[i] &+= (k & 0xFFFF_FFFF) &* (k >> 32)
    }
}

private func scramble(_ acc: UnsafeMutablePointer<UInt64>, _ s: UnsafeRawPointer) {
    let so = secretSize - stripeLen
    for i in 0..<8 {
        var a = acc[i]
        a = xs(a, 47); a ^= r64(s, so + 8 * i); a &*= P32_1
        acc[i] = a
    }
}

/// Streaming XXH3-128. Feed bytes with `update`, then read `hexDigest`.
struct XXH3_128 {
    private var acc: [UInt64] = [P32_3, P64_1, P64_2, P64_3, P64_4, P32_2, P64_5, P32_1]
    private var pending: [UInt8] = []       // bytes not yet folded into the accumulators
    private var lastConsumed: [UInt8] = []  // the 64 bytes just before `pending`
    private var stripesInBlock = 0
    private var total = 0
    private var long = false                // switched to the >240-byte path

    init() { pending.reserveCapacity(1 << 20) }

    mutating func update(_ data: UnsafeRawBufferPointer) {
        total += data.count
        pending.append(contentsOf: data)
        if !long {
            guard pending.count > midSizeMax else { return }
            long = true
        }
        consume()
    }

    mutating func update(_ data: Data) { data.withUnsafeBytes { update($0) } }
    mutating func update(_ bytes: [UInt8]) { bytes.withUnsafeBytes { update($0) } }

    /// Fold every stripe that still has at least one byte after it.
    private mutating func consume() {
        let n = pending.count
        guard n > stripeLen else { return }
        let stripes = (n - 1) / stripeLen
        kSecret.withUnsafeBytes { s in
            pending.withUnsafeBytes { pb in
                acc.withUnsafeMutableBufferPointer { a in
                    let p = pb.baseAddress!, sp = s.baseAddress!, ap = a.baseAddress!
                    for k in 0..<stripes {
                        accumulate512(ap, p, k * stripeLen, sp, stripesInBlock * 8)
                        stripesInBlock += 1
                        if stripesInBlock == stripesPerBlock {
                            scramble(ap, sp)
                            stripesInBlock = 0
                        }
                    }
                }
            }
        }
        let used = stripes * stripeLen
        lastConsumed = Array(pending[(used - stripeLen)..<used])
        pending.removeSubrange(0..<used)
    }

    var digest: (hi: UInt64, lo: UInt64) {
        kSecret.withUnsafeBytes { s -> (hi: UInt64, lo: UInt64) in
            let sp = s.baseAddress!
            if !long {
                let r = pending.withUnsafeBytes { short128($0.baseAddress ?? UnsafeRawPointer(sp), total, sp) }
                return (r.hi, r.lo)
            }
            var a = acc
            let lastStripe = Array((lastConsumed + pending).suffix(stripeLen))
            a.withUnsafeMutableBufferPointer { ab in
                lastStripe.withUnsafeBytes { lb in
                    accumulate512(ab.baseAddress!, lb.baseAddress!, 0, sp, secretSize - stripeLen - 7)
                }
            }
            func merge(_ so: Int, _ start: UInt64) -> UInt64 {
                var r = start
                for i in 0..<4 { r &+= fold64(a[2 * i] ^ r64(sp, so + 16 * i), a[2 * i + 1] ^ r64(sp, so + 16 * i + 8)) }
                return avalanche3(r)
            }
            let L = UInt64(total)
            let lo = merge(11, L &* P64_1)
            let hi = merge(secretSize - 64 - 11, ~(L &* P64_2))
            return (hi, lo)
        }
    }

    /// Canonical form, as Stow, ASC-MHL and `xxhsum -H2` print it.
    var hexDigest: String {
        let d = digest
        return String(format: "%016llx%016llx", d.hi, d.lo)
    }
}
