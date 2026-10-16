// flac.cpp: FLAC decoder and encoder for signal formats 508, 516, and 524
// (C++ port of python/src/wfdbx/_flac.py)
//
// The C library uses libFLAC for these formats; wfdb-x implements, without
// external libraries, a complete FLAC decoder (all subframe types, fixed and
// LPC predictors, Rice and Rice2 partitions with escape codes, wasted bits,
// stereo decorrelation, variable block sizes, CRC verification) and a
// lossless encoder (fixed predictors and Rice coding).  The encoder writes
// exactly the bytes written by the Python implementation of wfdb-x.
//
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

#include "flac.hpp"

#include <cstring>

#include "wfdbx/wfdb.hpp"

namespace wfdbx {
namespace detail {
namespace flac {

namespace {

const char *const VENDOR = "wfdb-x";

// Constants of the FLAC format (RFC 9639)
constexpr char STREAM_MARKER[] = "fLaC";
constexpr size_t MARKER_LEN = 4;
constexpr size_t META_HEADER_LEN = 4;   // metadata block header (flag, type, length)
constexpr unsigned META_LAST = 0x80;    // flag: last metadata block
constexpr unsigned META_TYPE = 0x7F;    // mask for the block type
constexpr unsigned META_STREAMINFO = 0;
constexpr unsigned META_VORBIS_COMMENT = 4;
constexpr size_t STREAMINFO_LEN = 34;
constexpr size_t STREAMINFO_MD5 = 18;   // offset of the MD5 signature
constexpr size_t MD5_LEN = 16;
constexpr unsigned FRAME_SYNC = 0xFFF8; // 14-bit sync code, reserved bit, and
                                        // blocking strategy bit (fixed: 0)
constexpr unsigned SYNC_MASK = 0xFFFE;  // (the blocking strategy may be 1)
constexpr int SAMPLE_RATE_96K = 11;     // sample rate code for 96 kHz
constexpr unsigned STREAMINFO_RATE = 96000;
// Block size codes 6 and 7: an 8-bit or 16-bit (blocksize - 1) follows the
// frame number; code 12 is 4096 (BLOCKSIZE).  Sample rate codes 12 to 14:
// an 8-bit or 16-bit sample rate follows; 15 is invalid.
constexpr int BS_8BIT = 6, BS_16BIT = 7, BS_4096 = 12;
constexpr int SR_8BIT = 12, SR_16BIT_HZ = 13, SR_16BIT_DAHZ = 14, SR_INVALID = 15;
// Channel assignments: 0-7 are independent channels (number - 1); then
constexpr int CH_LEFT_SIDE = 8, CH_SIDE_RIGHT = 9, CH_MID_SIDE = 10;
// Subframe types
constexpr int SUB_CONSTANT = 0, SUB_VERBATIM = 1;
constexpr int SUB_FIXED = 8;            // 8 + order (order 0 to 4)
constexpr int SUB_LPC = 32;             // 31 + order (order 1 to 32)
constexpr int MAX_FIXED_ORDER = 4;
constexpr int MAX_LPC_ORDER = 32;
constexpr int LPC_PREC_INVALID = 16;    // (4-bit precision field + 1) == 16
// Residual coding methods: Rice (4-bit parameters, escape code 15) and Rice2
// (5-bit parameters, escape code 31)
constexpr int RICE_PARAM_BITS = 4, RICE2_PARAM_BITS = 5;
constexpr int RICE_ESCAPE = 15, RICE2_ESCAPE = 31;
constexpr int MAX_RICE_PARAM = 30;      // largest parameter used by the encoder
constexpr int MAX_PARTITION_ORDER = 6;  // largest partition order used by the encoder

// ---------------------------------------------------------------------------
// CRC tables

struct CrcTables {
    uint8_t crc8[256];
    uint16_t crc16[256];
    CrcTables() {
        for (int i = 0; i < 256; i++) {
            unsigned c = static_cast<unsigned>(i);
            for (int k = 0; k < 8; k++)
                c = (c & 0x80) ? ((c << 1) ^ 0x07) & 0xFF : (c << 1) & 0xFF;
            crc8[i] = static_cast<uint8_t>(c);
            c = static_cast<unsigned>(i) << 8;
            for (int k = 0; k < 8; k++)
                c = (c & 0x8000) ? ((c << 1) ^ 0x8005) & 0xFFFF
                                 : (c << 1) & 0xFFFF;
            crc16[i] = static_cast<uint16_t>(c);
        }
    }
};

const CrcTables &crc_tables()
{
    static const CrcTables t;
    return t;
}

unsigned crc8(const unsigned char *p, size_t n)
{
    const CrcTables &t = crc_tables();
    unsigned c = 0;
    for (size_t i = 0; i < n; i++) c = t.crc8[c ^ p[i]];
    return c;
}

unsigned crc16(const unsigned char *p, size_t n)
{
    const CrcTables &t = crc_tables();
    unsigned c = 0;
    for (size_t i = 0; i < n; i++)
        c = ((c << 8) & 0xFFFF) ^ t.crc16[(c >> 8) ^ p[i]];
    return c;
}

int clz64(uint64_t x)   // x != 0
{
#if defined(__GNUC__) || defined(__clang__)
    return __builtin_clzll(x);
#else
    int n = 0;
    while (!(x & (uint64_t(1) << 63))) {
        x <<= 1;
        n++;
    }
    return n;
#endif
}

int bit_length(uint64_t x)
{
    return x ? 64 - clz64(x) : 0;
}

// 8 bytes, big-endian
inline uint64_t load8(const unsigned char *p)
{
    uint64_t w;
    std::memcpy(&w, p, 8);
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    return w;
#elif defined(__GNUC__) || defined(__clang__)
    return __builtin_bswap64(w);
#else
    return (uint64_t(p[0]) << 56) | (uint64_t(p[1]) << 48) |
           (uint64_t(p[2]) << 40) | (uint64_t(p[3]) << 32) |
           (uint64_t(p[4]) << 24) | (uint64_t(p[5]) << 16) |
           (uint64_t(p[6]) << 8) | uint64_t(p[7]);
#endif
}

// ---------------------------------------------------------------------------
// Decoder

struct FlacError {
    Status status;
};

[[noreturn]] void fail(Status s) { throw FlacError{s}; }

// MSB-first bit reader over a byte array.
class Bits {
public:
    Bits(const unsigned char *data, size_t n, size_t bytepos)
        : d_(data), n_(n), pos_(static_cast<uint64_t>(bytepos) * 8),
          end_(static_cast<uint64_t>(n) * 8) {}

    // Read n bits (0 <= n <= 57) as an unsigned value.
    uint64_t read(int n) {
        if (n <= 0) {
            if (n < 0) fail(Status::unparseable);
            return 0;
        }
        if (pos_ + static_cast<uint64_t>(n) > end_) fail(Status::eof);
        size_t b = static_cast<size_t>(pos_ >> 3);
        unsigned off = static_cast<unsigned>(pos_ & 7);
        uint64_t w = load(b) << off;
        pos_ += static_cast<uint64_t>(n);
        return w >> (64 - n);
    }

    // Read n bits (0 <= n <= 64) as an unsigned value.
    uint64_t read_long(int n) {
        if (n <= 32) return read(n);
        uint64_t hi = read(n - 32);
        return (hi << 32) | read(32);
    }

    int64_t read_signed(int n) {
        if (n > 57) {
            uint64_t v = read_long(n);
            if (n < 64 && (v >> (n - 1)) & 1) v -= uint64_t(1) << n;
            return static_cast<int64_t>(v);
        }
        uint64_t v = read(n);
        if (n > 0 && ((v >> (n - 1)) & 1))
            return static_cast<int64_t>(v) - (int64_t(1) << n);
        return static_cast<int64_t>(v);
    }

    // Count zero bits up to (and consume) the next one bit.
    uint64_t unary() {
        size_t b = static_cast<size_t>(pos_ >> 3);
        unsigned off = static_cast<unsigned>(pos_ & 7);
        uint64_t count = 0;
        for (;;) {
            if (b >= n_) fail(Status::eof);
            uint64_t w = load(b) << off;
            if (w) {
                int z = clz64(w);
                pos_ = (static_cast<uint64_t>(b) << 3) + off + z + 1;
                return count + static_cast<uint64_t>(z);
            }
            count += 64 - off;
            b += 8;
            off = 0;
        }
    }

    // A Rice-coded value with parameter k (0 <= k <= 30): unary quotient,
    // then k bits.
    uint64_t rice(int k) {
        size_t b = static_cast<size_t>(pos_ >> 3);
        if (b + 8 <= n_) {
            unsigned off = static_cast<unsigned>(pos_ & 7);
            uint64_t w = load8(d_ + b) << off;
            if (w) {
                int z = clz64(w);
                if (static_cast<unsigned>(z + 1 + k) <= 64 - off) {
                    pos_ += static_cast<uint64_t>(z + 1 + k);
                    if (k == 0) return static_cast<uint64_t>(z);
                    return (static_cast<uint64_t>(z) << k) |
                           ((w << (z + 1)) >> (64 - k));
                }
            }
        }
        uint64_t q = unary();
        return (q << k) | read(k);
    }

    void align() { pos_ = (pos_ + 7) & ~uint64_t(7); }
    size_t byte_pos() const { return static_cast<size_t>(pos_ >> 3); }

private:
    // 8 bytes starting at b, big-endian, zero-padded beyond the end
    uint64_t load(size_t b) const {
        if (b + 8 <= n_) return load8(d_ + b);
        uint64_t w = 0;
        for (size_t i = 0; i < 8; i++)
            w = (w << 8) | (b + i < n_ ? d_[b + i] : 0);
        return w;
    }

    const unsigned char *d_;
    size_t n_;
    uint64_t pos_, end_;
};

uint64_t read_utf8(Bits &bits)
{
    uint64_t x = bits.read(8);
    if (x < 0x80) return x;
    uint64_t v;
    int n;
    if ((x & 0xE0) == 0xC0) {
        v = x & 0x1F;
        n = 1;
    } else if ((x & 0xF0) == 0xE0) {
        v = x & 0x0F;
        n = 2;
    } else if ((x & 0xF8) == 0xF0) {
        v = x & 0x07;
        n = 3;
    } else if ((x & 0xFC) == 0xF8) {
        v = x & 0x03;
        n = 4;
    } else if ((x & 0xFE) == 0xFC) {
        v = x & 0x01;
        n = 5;
    } else if (x == 0xFE) {
        v = 0;
        n = 6;
    } else
        fail(Status::header);
    for (int i = 0; i < n; i++) {
        uint64_t y = bits.read(8);
        if ((y & 0xC0) != 0x80) fail(Status::header);
        v = (v << 6) | (y & 0x3F);
    }
    return v;
}

inline int64_t unfold(uint64_t u)
{
    return (u & 1) ? -static_cast<int64_t>(u >> 1) - 1
                   : static_cast<int64_t>(u >> 1);
}

void read_residual(Bits &bits, long blocksize, int order,
                   std::vector<int64_t> &out)
{
    int method = static_cast<int>(bits.read(2));
    if (method > 1) fail(Status::unparseable);
    int pbits = method == 0 ? RICE_PARAM_BITS : RICE2_PARAM_BITS;
    unsigned esc = method == 0 ? RICE_ESCAPE : RICE2_ESCAPE;
    int porder = static_cast<int>(bits.read(4));
    long nparts = 1L << porder;
    if (blocksize % nparts) fail(Status::unparseable);
    long psize = blocksize >> porder;
    if (porder > 0 && psize < order) fail(Status::unparseable);
    for (long part = 0; part < nparts; part++) {
        long n = part == 0 ? psize - order : psize;
        unsigned k = static_cast<unsigned>(bits.read(pbits));
        if (k == esc) {         // escaped partition: unencoded samples
            int nb = static_cast<int>(bits.read(5));
            for (long i = 0; i < n; i++) out.push_back(bits.read_signed(nb));
        } else {
            int kk = static_cast<int>(k);
            for (long i = 0; i < n; i++) out.push_back(unfold(bits.rice(kk)));
        }
    }
}

inline int64_t shl(int64_t x, int n)
{
    return static_cast<int64_t>(static_cast<uint64_t>(x) << n);
}

std::vector<int64_t> decode_subframe(Bits &bits, long blocksize, int bps)
{
    if (bits.read(1)) fail(Status::unparseable);
    int t = static_cast<int>(bits.read(6));
    int wasted = 0;
    if (bits.read(1)) {
        wasted = static_cast<int>(bits.unary()) + 1;
        bps -= wasted;
    }
    std::vector<int64_t> s;
    if (t == SUB_CONSTANT) {
        int64_t v = bits.read_signed(bps);
        s.assign(static_cast<size_t>(blocksize), v);
    } else if (t == SUB_VERBATIM) {
        s.reserve(static_cast<size_t>(blocksize));
        for (long i = 0; i < blocksize; i++) s.push_back(bits.read_signed(bps));
    } else if (t >= SUB_FIXED && t <= SUB_FIXED + MAX_FIXED_ORDER) {
        int order = t - SUB_FIXED;
        s.reserve(static_cast<size_t>(blocksize > order ? blocksize : order));
        for (int i = 0; i < order; i++) s.push_back(bits.read_signed(bps));
        std::vector<int64_t> res;
        res.reserve(static_cast<size_t>(blocksize));
        read_residual(bits, blocksize, order, res);
        switch (order) {
        case 0:
            s.insert(s.end(), res.begin(), res.end());
            break;
        case 1: {
            int64_t x = s[s.size() - 1];
            for (int64_t r : res) {
                x += r;
                s.push_back(x);
            }
            break;
        }
        case 2: {
            int64_t a = s[s.size() - 2], b = s[s.size() - 1];
            for (int64_t r : res) {
                int64_t nb = 2 * b - a + r;
                a = b;
                b = nb;
                s.push_back(b);
            }
            break;
        }
        case 3: {
            int64_t a = s[s.size() - 3], b = s[s.size() - 2],
                    c = s[s.size() - 1];
            for (int64_t r : res) {
                int64_t nc = 3 * c - 3 * b + a + r;
                a = b;
                b = c;
                c = nc;
                s.push_back(c);
            }
            break;
        }
        default: {
            int64_t a = s[s.size() - 4], b = s[s.size() - 3],
                    c = s[s.size() - 2], d = s[s.size() - 1];
            for (int64_t r : res) {
                int64_t nd = 4 * d - 6 * c + 4 * b - a + r;
                a = b;
                b = c;
                c = d;
                d = nd;
                s.push_back(d);
            }
            break;
        }
        }
    } else if (t >= SUB_LPC) {
        int order = t - (SUB_LPC - 1);
        s.reserve(static_cast<size_t>(blocksize > order ? blocksize : order));
        for (int i = 0; i < order; i++) s.push_back(bits.read_signed(bps));
        int prec = static_cast<int>(bits.read(4)) + 1;
        if (prec == LPC_PREC_INVALID) fail(Status::unparseable);
        int shift = static_cast<int>(bits.read_signed(5));
        int64_t coefs[MAX_LPC_ORDER];
        for (int i = 0; i < order; i++) coefs[i] = bits.read_signed(prec);
        std::vector<int64_t> res;
        res.reserve(static_cast<size_t>(blocksize));
        read_residual(bits, blocksize, order, res);
        if (shift < 0) fail(Status::unparseable);
        for (int64_t r : res) {
            const int64_t *hist = s.data() + s.size() - order;
            int64_t acc = 0;
            // coefs[0] applies to the most recent sample
            for (int j = 0; j < order; j++)
                acc += coefs[j] * hist[order - 1 - j];
            s.push_back(r + (acc >> shift));
        }
    } else
        fail(Status::unparseable);
    if (wasted)
        for (int64_t &x : s) x = shl(x, wasted);
    return s;
}

const int BPS_TABLE[8] = {0, 8, 12, 0, 16, 20, 24, 32};

long block_size_code(int bsc)
{
    switch (bsc) {
    case 1: return 192;
    case 2: return 576;
    case 3: return 1152;
    case 4: return 2304;
    case 5: return 4608;
    default: return 256L << (bsc - 8);    // 8 .. 15
    }
}

// Decode one frame at byte offset pos; returns the channels, sets bps and
// the offset of the next frame.
std::vector<std::vector<int64_t>> decode_frame(const unsigned char *data,
                                               size_t n, size_t pos,
                                               int si_bps, int &bps,
                                               size_t &newpos)
{
    if (pos + 2 > n ||
        ((unsigned(data[pos]) << 8 | data[pos + 1]) & SYNC_MASK) != FRAME_SYNC)
        fail(Status::sync);
    Bits bits(data, n, pos);
    bits.read(16);      // sync code and blocking strategy
    int bsc = static_cast<int>(bits.read(4));
    int src = static_cast<int>(bits.read(4));
    int chc = static_cast<int>(bits.read(4));
    int ssc = static_cast<int>(bits.read(3));
    if (bits.read(1)) fail(Status::header);
    read_utf8(bits);
    long blocksize;
    if (bsc == 0)
        fail(Status::header);
    else if (bsc == BS_8BIT)
        blocksize = static_cast<long>(bits.read(8)) + 1;
    else if (bsc == BS_16BIT)
        blocksize = static_cast<long>(bits.read(16)) + 1;
    else
        blocksize = block_size_code(bsc);
    if (src == SR_8BIT)
        bits.read(8);
    else if (src == SR_16BIT_HZ || src == SR_16BIT_DAHZ)
        bits.read(16);
    else if (src == SR_INVALID)
        fail(Status::header);
    if (ssc == 0)
        bps = si_bps;
    else if (BPS_TABLE[ssc])
        bps = BPS_TABLE[ssc];
    else
        fail(Status::header);
    size_t hend = bits.byte_pos();
    unsigned crc = static_cast<unsigned>(bits.read(8));
    if (crc8(data + pos, hend - pos) != crc) fail(Status::header);
    std::vector<std::vector<int64_t>> chans;
    if (chc < CH_LEFT_SIDE) {
        for (int c = 0; c <= chc; c++)
            chans.push_back(decode_subframe(bits, blocksize, bps));
    } else if (chc <= CH_MID_SIDE) {
        if (chc == CH_LEFT_SIDE) {
            std::vector<int64_t> a = decode_subframe(bits, blocksize, bps);
            std::vector<int64_t> sd = decode_subframe(bits, blocksize, bps + 1);
            size_t m = a.size() < sd.size() ? a.size() : sd.size();
            std::vector<int64_t> b(m);
            for (size_t i = 0; i < m; i++) b[i] = a[i] - sd[i];
            chans.push_back(std::move(a));
            chans.push_back(std::move(b));
        } else if (chc == CH_SIDE_RIGHT) {
            std::vector<int64_t> sd = decode_subframe(bits, blocksize, bps + 1);
            std::vector<int64_t> b = decode_subframe(bits, blocksize, bps);
            size_t m = b.size() < sd.size() ? b.size() : sd.size();
            std::vector<int64_t> a(m);
            for (size_t i = 0; i < m; i++) a[i] = sd[i] + b[i];
            chans.push_back(std::move(a));
            chans.push_back(std::move(b));
        } else {                // mid/side
            std::vector<int64_t> mid = decode_subframe(bits, blocksize, bps);
            std::vector<int64_t> sd = decode_subframe(bits, blocksize, bps + 1);
            size_t m = mid.size() < sd.size() ? mid.size() : sd.size();
            std::vector<int64_t> le(m), ri(m);
            for (size_t i = 0; i < m; i++) {
                int64_t x = shl(mid[i], 1) | (sd[i] & 1), y = sd[i];
                le[i] = (x + y) >> 1;
                ri[i] = (x - y) >> 1;
            }
            chans.push_back(std::move(le));
            chans.push_back(std::move(ri));
        }
    } else
        fail(Status::header);
    bits.align();
    size_t fend = bits.byte_pos();
    unsigned c16 = static_cast<unsigned>(bits.read(16));
    if (crc16(data + pos, fend - pos) != c16) fail(Status::crc);
    newpos = bits.byte_pos();
    return chans;
}

} // namespace

Decoded decode(const unsigned char *data, size_t n, int expect_nsig,
               int expect_bps)
{
    Decoded result;
    try {
        // Errors in the stream header and metadata are reported by libFLAC
        // without invoking its error callback ('meta' status).
        if (n < MARKER_LEN || std::memcmp(data, STREAM_MARKER, MARKER_LEN) != 0)
            fail(Status::meta);
        size_t pos = MARKER_LEN;
        int si_bps = 0, si_ch = 0;
        for (;;) {
            if (pos + META_HEADER_LEN > n) fail(Status::meta);
            unsigned hb = data[pos];
            size_t ln = (static_cast<size_t>(data[pos + 1]) << 16) |
                        (static_cast<size_t>(data[pos + 2]) << 8) |
                        data[pos + 3];
            if (pos + META_HEADER_LEN + ln > n) fail(Status::meta);
            if ((hb & META_TYPE) == META_STREAMINFO) {
                if (ln < STREAMINFO_LEN) fail(Status::meta);
                Bits b(data, n, pos + META_HEADER_LEN);
                b.read(16);
                b.read(16);
                b.read(24);
                b.read(24);
                b.read(20);
                si_ch = static_cast<int>(b.read(3)) + 1;
                si_bps = static_cast<int>(b.read(5)) + 1;
                b.read(36);
                result.has_md5 = true;
                std::memcpy(result.md5,
                            data + pos + META_HEADER_LEN + STREAMINFO_MD5,
                            MD5_LEN);
            }
            pos += META_HEADER_LEN + ln;
            if (hb & META_LAST) break;
        }
        result.channels = si_ch;
        result.bps = si_bps;
        result.chans.assign(si_ch > 1 ? si_ch : 1, std::vector<int32_t>());
        while (pos < n) {
            int bps = 0;
            size_t newpos = pos;
            std::vector<std::vector<int64_t>> fr;
            try {
                fr = decode_frame(data, n, pos, si_bps, bps, newpos);
            } catch (const FlacError &e) {
                if (e.status == Status::sync) {
                    bool zeros = true;
                    for (size_t i = pos; i < n; i++)
                        if (data[i]) {
                            zeros = false;
                            break;
                        }
                    if (zeros) break;
                }
                throw;
            }
            pos = newpos;
            if (expect_nsig > 0 &&
                fr.size() != static_cast<size_t>(expect_nsig)) {
                wfdb_error(
                    "getvec: wrong number of signals in FLAC signal file\n");
                fail(Status::wfdb);
            }
            if (expect_nsig > 0 && bps > expect_bps) {
                wfdb_error(
                    "getvec: wrong sample resolution in FLAC signal file\n");
                fail(Status::wfdb);
            }
            size_t m = fr.size() < result.chans.size() ? fr.size()
                                                       : result.chans.size();
            for (size_t c = 0; c < m; c++) {
                std::vector<int32_t> &dst = result.chans[c];
                size_t base = dst.size(), m2 = fr[c].size();
                dst.resize(base + m2);
                const int64_t *src = fr[c].data();
                int32_t *out = dst.data() + base;
                for (size_t i = 0; i < m2; i++)
                    out[i] = static_cast<int32_t>(src[i]);
            }
            if (m > 0)
                result.block_ends.push_back(
                    static_cast<long long>(result.chans[0].size()));
        }
    } catch (const FlacError &e) {
        result.status = e.status;
        result.chans.clear();
    }
    return result;
}

// ---------------------------------------------------------------------------
// MD5 (RFC 1321)

namespace {

const uint32_t MD5_K[64] = {
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a,
    0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340,
    0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8,
    0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
    0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92,
    0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391};

const int MD5_S[64] = {7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12,
                       17, 22, 5, 9,  14, 20, 5, 9,  14, 20, 5, 9,  14, 20,
                       5,  9,  14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11,
                       16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21,
                       6,  10, 15, 21, 6, 10, 15, 21};

inline uint32_t rotl(uint32_t x, int c) { return (x << c) | (x >> (32 - c)); }

} // namespace

MD5::MD5()
    : a_(0x67452301), b_(0xefcdab89), c_(0x98badcfe), d_(0x10325476),
      length_(0), buffer_(), buffered_(0) {}

void MD5::transform(const unsigned char block[64])
{
    uint32_t m[16];
    for (int i = 0; i < 16; i++)
        m[i] = static_cast<uint32_t>(block[4 * i]) |
               (static_cast<uint32_t>(block[4 * i + 1]) << 8) |
               (static_cast<uint32_t>(block[4 * i + 2]) << 16) |
               (static_cast<uint32_t>(block[4 * i + 3]) << 24);
    uint32_t a = a_, b = b_, c = c_, d = d_;
    for (int i = 0; i < 64; i++) {
        uint32_t f;
        int g;
        if (i < 16) {
            f = (b & c) | (~b & d);
            g = i;
        } else if (i < 32) {
            f = (d & b) | (~d & c);
            g = (5 * i + 1) & 15;
        } else if (i < 48) {
            f = b ^ c ^ d;
            g = (3 * i + 5) & 15;
        } else {
            f = c ^ (b | ~d);
            g = (7 * i) & 15;
        }
        f = f + a + MD5_K[i] + m[g];
        a = d;
        d = c;
        c = b;
        b = b + rotl(f, MD5_S[i]);
    }
    a_ += a;
    b_ += b;
    c_ += c;
    d_ += d;
}

void MD5::update(const void *data, size_t n)
{
    const unsigned char *p = static_cast<const unsigned char *>(data);
    length_ += n;
    if (buffered_) {
        size_t k = 64 - buffered_;
        if (k > n) k = n;
        std::memcpy(buffer_ + buffered_, p, k);
        buffered_ += k;
        p += k;
        n -= k;
        if (buffered_ < 64) return;
        transform(buffer_);
        buffered_ = 0;
    }
    while (n >= 64) {
        transform(p);
        p += 64;
        n -= 64;
    }
    if (n) {
        std::memcpy(buffer_, p, n);
        buffered_ = n;
    }
}

void MD5::digest(unsigned char out[16])
{
    uint64_t bits = length_ * 8;
    unsigned char pad[72] = {0x80};
    size_t padlen = (buffered_ < 56) ? 56 - buffered_ : 120 - buffered_;
    update(pad, padlen);
    unsigned char len[8];
    for (int i = 0; i < 8; i++) len[i] = static_cast<unsigned char>(bits >> (8 * i));
    update(len, 8);
    uint32_t v[4] = {a_, b_, c_, d_};
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            out[4 * i + j] = static_cast<unsigned char>(v[i] >> (8 * j));
}

void samples_md5(const std::vector<std::vector<int32_t>> &chans, int bps,
                 unsigned char out[16])
{
    MD5 md5;
    size_t nb = static_cast<size_t>((bps + 7) / 8);
    size_t n = chans.empty() ? 0 : chans[0].size();
    std::vector<unsigned char> buf;
    buf.reserve(4096 * nb * chans.size());
    for (size_t i = 0; i < n; i++) {
        for (const std::vector<int32_t> &c : chans) {
            uint32_t v = static_cast<uint32_t>(c[i]);
            for (size_t k = 0; k < nb; k++)
                buf.push_back(static_cast<unsigned char>(v >> (8 * k)));
        }
        if (buf.size() >= 65536) {
            md5.update(buf.data(), buf.size());
            buf.clear();
        }
    }
    md5.update(buf.data(), buf.size());
    md5.digest(out);
}

// ---------------------------------------------------------------------------
// Encoder

namespace {

class BitWriter {
public:
    explicit BitWriter(std::string &out) : out_(out) {}
    // Write the n (0 <= n <= 32) low bits of v.
    void write(uint64_t v, int n) {
        if (n == 0) return;
        acc_ = (acc_ << n) | (v & ((uint64_t(1) << n) - 1));
        nbits_ += n;
        while (nbits_ >= 8) {
            nbits_ -= 8;
            out_.push_back(static_cast<char>((acc_ >> nbits_) & 0xFF));
        }
    }
    // Write q zero bits followed by a one bit.
    void unary(uint64_t q) {
        while (q >= 32) {
            write(0, 32);
            q -= 32;
        }
        write(1, static_cast<int>(q) + 1);
    }
    void align() {
        if (nbits_ & 7) write(0, 8 - (nbits_ & 7));
    }
private:
    std::string &out_;
    uint64_t acc_ = 0;
    int nbits_ = 0;
};

void put_utf8(std::string &out, uint64_t v)
{
    if (v < 0x80) {
        out.push_back(static_cast<char>(v));
        return;
    }
    static const struct { int n; unsigned lead; uint64_t mx; } tbl[] = {
        {1, 0xC0, 0x7FF}, {2, 0xE0, 0xFFFF}, {3, 0xF0, 0x1FFFFF},
        {4, 0xF8, 0x3FFFFFF}, {5, 0xFC, 0x7FFFFFFF}, {6, 0xFE, 0xFFFFFFFFFULL}};
    for (const auto &t : tbl) {
        if (v <= t.mx) {
            unsigned char b[7];
            for (int i = t.n; i >= 1; i--) {
                b[i] = static_cast<unsigned char>(0x80 | (v & 0x3F));
                v >>= 6;
            }
            b[0] = static_cast<unsigned char>(t.lead | v);
            out.append(reinterpret_cast<const char *>(b), t.n + 1);
            return;
        }
    }
}

struct Partition {
    uint64_t cost = 0;
    int porder = 0;
    std::vector<int> params;
};

// Choose a partition order and Rice parameters for folded residuals (as
// _best_partition() in _flac.py).  For each partition order, and each
// partition, the parameter k is chosen among those near log2 of the mean,
// with the cost (in bits) sum(u >> k) + n * (k + 1).  The sums of u >> k
// are computed once for the partitions of the highest partition order and
// added up for the lower orders.
Partition best_partition(const std::vector<uint64_t> &u, int order,
                         long blocksize, int maxk)
{
    // The highest valid partition order
    int maxorder = 0;
    for (int porder = 1; porder <= MAX_PARTITION_ORDER; porder++) {
        long nparts = 1L << porder;
        if (blocksize % nparts) break;
        if ((blocksize >> porder) <= order) break;
        maxorder = porder;
    }
    constexpr int NK = MAX_RICE_PARAM + 2;  // sums for k = 0 .. maxk
    long nfine = 1L << maxorder, fsize = blocksize >> maxorder;
    std::vector<uint64_t> sums(static_cast<size_t>(nfine) * NK, 0);
    std::vector<long> counts(static_cast<size_t>(nfine), 0);
    size_t start = 0;
    for (long p = 0; p < nfine; p++) {
        long n = p == 0 ? fsize - order : fsize;
        if (n < 0) n = 0;
        uint64_t *sp = sums.data() + p * NK;
        for (long i = 0; i < n; i++) {
            uint64_t v = u[start + static_cast<size_t>(i)];
            for (int k = 0; v && k <= maxk; k++, v >>= 1) sp[k] += v;
        }
        counts[p] = n;
        start += static_cast<size_t>(n);
    }

    Partition best;
    bool have = false;
    std::vector<uint64_t> acc(NK);
    for (int porder = 0; porder <= maxorder; porder++) {
        long nparts = 1L << porder;
        long group = 1L << (maxorder - porder);     // fine partitions per part
        uint64_t cost = 6;
        std::vector<int> params;
        params.reserve(static_cast<size_t>(nparts));
        for (long p = 0; p < nparts; p++) {
            long n = 0;
            std::fill(acc.begin(), acc.end(), 0);
            for (long q = p * group; q < (p + 1) * group; q++) {
                n += counts[q];
                const uint64_t *sp = sums.data() + q * NK;
                for (int k = 0; k <= maxk; k++) acc[k] += sp[k];
            }
            if (n == 0) {
                params.push_back(0);
                cost += 4;
                continue;
            }
            uint64_t mean = acc[0] / static_cast<uint64_t>(n);
            int k0 = mean > 0 ? bit_length(mean) - 1 : 0;
            int lo = k0 - 1 > 0 ? k0 - 1 : 0;
            if (lo > maxk) lo = maxk;
            int hi = k0 + 2 < maxk ? k0 + 2 : maxk;
            int bk = -1;
            uint64_t bc = 0;
            for (int k = lo; k <= hi; k++) {
                uint64_t c = acc[k] + static_cast<uint64_t>(n) *
                                          static_cast<uint64_t>(k + 1);
                if (bk < 0 || c < bc) {
                    bk = k;
                    bc = c;
                }
            }
            params.push_back(bk);
            cost += 4 + bc;
        }
        if (!have || cost < best.cost) {
            best.cost = cost;
            best.porder = porder;
            best.params = std::move(params);
            have = true;
        }
    }
    return best;
}

void encode_subframe(BitWriter &bw, const std::vector<int32_t> &x, int bps)
{
    size_t n = x.size();
    bool constant = true;
    for (size_t i = 1; i < n; i++)
        if (x[i] != x[0]) {
            constant = false;
            break;
        }
    // Subframe header: a zero bit, the 6-bit type, and a "wasted bits" flag.
    if (constant) {
        bw.write(0, 1);
        bw.write(SUB_CONSTANT, 6);
        bw.write(0, 1);
        bw.write(static_cast<uint64_t>(static_cast<int64_t>(x[0])), bps);
        return;
    }
    const int maxk = MAX_RICE_PARAM;
    bool have = false;
    uint64_t best_cost = 0;
    int best_order = 0;
    std::vector<uint64_t> best_u, u;
    Partition best_bp;
    int maxorder = static_cast<int>(n - 1 < MAX_FIXED_ORDER ? n - 1
                                                            : MAX_FIXED_ORDER);
    for (int order = 0; order <= maxorder; order++) {
        u.clear();
        u.reserve(n);
        for (size_t i = static_cast<size_t>(order); i < n; i++) {
            int64_t r;
            switch (order) {
            case 0: r = x[i]; break;
            case 1: r = int64_t(x[i]) - x[i - 1]; break;
            case 2: r = int64_t(x[i]) - 2 * int64_t(x[i - 1]) + x[i - 2]; break;
            case 3:
                r = int64_t(x[i]) - 3 * int64_t(x[i - 1]) +
                    3 * int64_t(x[i - 2]) - x[i - 3];
                break;
            default:
                r = int64_t(x[i]) - 4 * int64_t(x[i - 1]) +
                    6 * int64_t(x[i - 2]) - 4 * int64_t(x[i - 3]) + x[i - 4];
                break;
            }
            u.push_back(r >= 0 ? static_cast<uint64_t>(r) << 1
                               : (static_cast<uint64_t>(-r) << 1) - 1);
        }
        Partition bp = best_partition(u, order, static_cast<long>(n), maxk);
        uint64_t cost = static_cast<uint64_t>(order) * bps + 2 + bp.cost;
        if (!have || cost < best_cost) {
            have = true;
            best_cost = cost;
            best_order = order;
            best_u.swap(u);
            best_bp = std::move(bp);
        }
    }
    if (!have || best_cost >= n * static_cast<uint64_t>(bps)) {
        bw.write(0, 1);
        bw.write(SUB_VERBATIM, 6);
        bw.write(0, 1);
        for (int32_t v : x)
            bw.write(static_cast<uint64_t>(static_cast<int64_t>(v)), bps);
        return;
    }
    int order = best_order;
    bw.write(0, 1);
    bw.write(static_cast<uint64_t>(SUB_FIXED + order), 6);
    bw.write(0, 1);
    for (int i = 0; i < order; i++)
        bw.write(static_cast<uint64_t>(static_cast<int64_t>(x[i])), bps);
    int maxparam = 0;
    for (int k : best_bp.params)
        if (k > maxparam) maxparam = k;
    int method = maxparam < RICE_ESCAPE ? 0 : 1;
    int pbits = method == 0 ? RICE_PARAM_BITS : RICE2_PARAM_BITS;
    bw.write(static_cast<uint64_t>(method), 2);
    bw.write(static_cast<uint64_t>(best_bp.porder), 4);
    long psize = static_cast<long>(n) >> best_bp.porder;
    size_t start = 0;
    for (size_t p = 0; p < best_bp.params.size(); p++) {
        int k = best_bp.params[p];
        long cnt = p == 0 ? psize - order : psize;
        bw.write(static_cast<uint64_t>(k), pbits);
        for (long i = 0; i < cnt; i++) {
            uint64_t v = best_u[start + static_cast<size_t>(i)];
            bw.unary(v >> k);
            if (k) bw.write(v, k);
        }
        if (cnt > 0) start += static_cast<size_t>(cnt);
    }
}

std::string make_streaminfo(uint32_t minfs, uint32_t maxfs, int nsig, int bps,
                            uint64_t total, const unsigned char md5[16])
{
    std::string out;
    BitWriter bw(out);
    bw.write(BLOCKSIZE, 16);
    bw.write(BLOCKSIZE, 16);
    bw.write(minfs, 24);
    bw.write(maxfs, 24);
    bw.write(STREAMINFO_RATE, 20);
    bw.write(static_cast<uint64_t>(nsig - 1), 3);
    bw.write(static_cast<uint64_t>(bps - 1), 5);
    bw.write(total >> 32, 4);
    bw.write(total & 0xFFFFFFFF, 32);
    out.append(reinterpret_cast<const char *>(md5), MD5_LEN);
    return out;
}

} // namespace

Encoder::Encoder(int nsig, int bps, int spf)
    : nsig_(nsig), bps_(bps), spf_(spf), chans_(nsig > 0 ? nsig : 0)
{
    pending_.reserve(static_cast<size_t>(nsig_ > 0 ? nsig_ : 0) *
                     (spf_ > 0 ? spf_ : 0));
}

std::string Encoder::header()
{
    static const unsigned char zeros[MD5_LEN] = {};
    size_t vlen = std::strlen(VENDOR);
    std::string vc;
    for (int i = 0; i < 4; i++) vc.push_back(static_cast<char>(vlen >> (8 * i)));
    vc += VENDOR;
    vc.append(4, '\0');
    std::string hdr = STREAM_MARKER;
    hdr.push_back(static_cast<char>(META_STREAMINFO));
    hdr.push_back('\0');
    hdr.push_back('\0');
    hdr.push_back(static_cast<char>(STREAMINFO_LEN));
    // (The total number of samples, a 36-bit field, is not yet known.)
    hdr += make_streaminfo(have_minfs_ ? minfs_ : 0, maxfs_, nsig_, bps_,
                           (uint64_t(1) << 36) - 1, zeros);
    hdr.push_back(static_cast<char>(META_LAST | META_VORBIS_COMMENT));
    hdr.push_back(static_cast<char>((vc.size() >> 16) & 0xFF));
    hdr.push_back(static_cast<char>((vc.size() >> 8) & 0xFF));
    hdr.push_back(static_cast<char>(vc.size() & 0xFF));
    hdr += vc;
    return hdr;
}

void Encoder::put(int v, std::string &out)
{
    uint32_t mask = bps_ >= 32 ? 0xFFFFFFFFu : (uint32_t(1) << bps_) - 1;
    uint32_t half = bps_ >= 32 ? 0x80000000u : uint32_t(1) << (bps_ - 1);
    int32_t w = static_cast<int32_t>(
        static_cast<int64_t>((static_cast<uint32_t>(v) + half) & mask) -
        static_cast<int64_t>(half));
    pending_.push_back(w);
    if (pending_.size() == static_cast<size_t>(nsig_) * spf_) {
        for (int c = 0; c < nsig_; c++)
            chans_[c].insert(chans_[c].end(), pending_.begin() + c * spf_,
                             pending_.begin() + (c + 1) * spf_);
        pending_.clear();
        if (chans_[0].size() >= static_cast<size_t>(BLOCKSIZE))
            write_block(BLOCKSIZE, out);
    }
}

void Encoder::finish(std::string &out)
{
    while (!chans_.empty() && !chans_[0].empty()) {
        size_t n = chans_[0].size();
        write_block(static_cast<int>(n < static_cast<size_t>(BLOCKSIZE)
                                         ? n : BLOCKSIZE), out);
    }
}

std::string Encoder::streaminfo()
{
    MD5 m = md5_;
    unsigned char digest[MD5_LEN];
    m.digest(digest);
    return make_streaminfo(have_minfs_ ? minfs_ : 0, maxfs_, nsig_, bps_,
                           total_, digest);
}

void Encoder::write_block(int n, std::string &out)
{
    std::vector<std::vector<int32_t>> block(chans_.size());
    for (size_t c = 0; c < chans_.size(); c++) {
        block[c].assign(chans_[c].begin(), chans_[c].begin() + n);
        chans_[c].erase(chans_[c].begin(), chans_[c].begin() + n);
    }
    // MD5 of the interleaved samples
    size_t nb = static_cast<size_t>((bps_ + 7) / 8);
    std::vector<unsigned char> inter;
    inter.reserve(static_cast<size_t>(n) * nb * block.size());
    for (int i = 0; i < n; i++)
        for (const std::vector<int32_t> &c : block) {
            uint32_t v = static_cast<uint32_t>(c[i]);
            for (size_t k = 0; k < nb; k++)
                inter.push_back(static_cast<unsigned char>(v >> (8 * k)));
        }
    md5_.update(inter.data(), inter.size());

    std::string frame;
    {
        BitWriter hb(frame);
        hb.write(FRAME_SYNC, 16);
        int bsc = n == BLOCKSIZE ? BS_4096 : (n <= 256 ? BS_8BIT : BS_16BIT);
        hb.write(static_cast<uint64_t>(bsc), 4);
        hb.write(SAMPLE_RATE_96K, 4);
        hb.write(static_cast<uint64_t>(nsig_ - 1), 4);  // independent channels
        // sample size code (see BPS_TABLE)
        hb.write(bps_ == 8 ? 1 : bps_ == 16 ? 4 : bps_ == 24 ? 6 : 0, 3);
        hb.write(0, 1);
        put_utf8(frame, frame_no_);
        if (bsc == BS_8BIT)
            frame.push_back(static_cast<char>(n - 1));
        else if (bsc == BS_16BIT) {
            frame.push_back(static_cast<char>(((n - 1) >> 8) & 0xFF));
            frame.push_back(static_cast<char>((n - 1) & 0xFF));
        }
        frame.push_back(static_cast<char>(crc8(
            reinterpret_cast<const unsigned char *>(frame.data()),
            frame.size())));
    }
    {
        BitWriter bw(frame);
        for (const std::vector<int32_t> &c : block)
            encode_subframe(bw, c, bps_);
        bw.align();
    }
    unsigned c16 = crc16(reinterpret_cast<const unsigned char *>(frame.data()),
                         frame.size());
    frame.push_back(static_cast<char>(c16 >> 8));
    frame.push_back(static_cast<char>(c16 & 0xFF));
    out += frame;
    frame_no_++;
    total_ += static_cast<uint64_t>(n);
    uint32_t fs = static_cast<uint32_t>(frame.size());
    if (!have_minfs_ || fs < minfs_) minfs_ = fs;
    have_minfs_ = true;
    if (fs > maxfs_) maxfs_ = fs;
}

} // namespace flac
} // namespace detail
} // namespace wfdbx
