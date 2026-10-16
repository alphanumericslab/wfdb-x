// test_flac.cpp: unit tests of the FLAC codec (cpp/src/flac.cpp)
//
// The expected values were computed with the Python implementation of wfdb-x
// (python/src/wfdbx/_flac.py): the samples decoded from the FLAC records of
// tests/data, and the exact bytes written by the encoder for a set of test
// signals (whose MD5 digests are stored here).
//
// Part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

#include "tests.hpp"

#include "../src/flac.hpp"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace wfdbx::detail::flac;

namespace {

std::string hex(const unsigned char d[16])
{
    static const char digits[] = "0123456789abcdef";
    std::string s;
    for (int i = 0; i < 16; i++) {
        s.push_back(digits[d[i] >> 4]);
        s.push_back(digits[d[i] & 15]);
    }
    return s;
}

std::string md5_hex(const void *data, size_t n)
{
    MD5 m;
    m.update(data, n);
    unsigned char d[16];
    m.digest(d);
    return hex(d);
}

bool read_file(const std::string &path, std::vector<unsigned char> &out)
{
    std::FILE *f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    unsigned char buf[65536];
    size_t n;
    out.clear();
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0)
        out.insert(out.end(), buf, buf + n);
    std::fclose(f);
    return true;
}

// MD5 of the samples interleaved, each as a 32-bit little-endian integer
std::string samples_digest(const std::vector<std::vector<int32_t>> &chans)
{
    MD5 m;
    size_t n = chans.empty() ? 0 : chans[0].size();
    for (size_t i = 0; i < n; i++)
        for (const auto &c : chans) {
            uint32_t v = static_cast<uint32_t>(c[i]);
            unsigned char b[4] = {static_cast<unsigned char>(v),
                                  static_cast<unsigned char>(v >> 8),
                                  static_cast<unsigned char>(v >> 16),
                                  static_cast<unsigned char>(v >> 24)};
            m.update(b, 4);
        }
    unsigned char d[16];
    m.digest(d);
    return hex(d);
}

struct RecordCase {
    const char *name;
    int channels, bps;
    size_t nsamp;
    const char *digest;
    int32_t first[3];
    int32_t last;
};

const RecordCase records[] = {
    {"flac8", 2, 8, 5000, "505da209b1473fbc46a21feb7833b00d",
     {-31, -42, -13}, -86},
    {"flac16", 3, 16, 9000, "c7031b07326efeaf5de0938839eccfd4",
     {-31, -58, -28}, 1335},
    {"flac24", 1, 24, 4500, "009556de1b80833f7f1d21d99c817729",
     {-17, -4, 29}, 8388435},
    {"flacmf", 2, 16, 8642, "76ee297c139a1538a9fd7f43d5398659",
     {-300, 700, -297}, 2979},
};

// Test signals for the encoder (the same as those of the Python script that
// computed the expected digests)
int32_t i32(uint32_t x) { return static_cast<int32_t>(x); }

std::vector<int32_t> gen(int vid, int nsig, int bps, int spf, int nframes,
                         const std::vector<int> &kinds)
{
    uint32_t state = 12345u + static_cast<uint32_t>(vid);
    std::vector<int32_t> out;
    int64_t half = int64_t(1) << (bps - 1);
    for (int f = 0; f < nframes; f++)
        for (int s = 0; s < nsig; s++)
            for (int k = 0; k < spf; k++) {
                state = state * 1664525u + 1013904223u;
                int64_t t = int64_t(f) * spf + k, v;
                switch (kinds[s]) {
                case 0: {
                    const int64_t P = 397;
                    int64_t m = t % P - P / 2;
                    int64_t tri = m < 0 ? -m : m;
                    v = tri * (half / 256) - half / 2 + ((state >> 20) % 7) - 3;
                    break;
                }
                case 1:
                    v = static_cast<int64_t>((state >> 8) &
                                             ((uint32_t(1) << bps) - 1)) - half;
                    break;
                case 2:
                    v = t < 5000 ? 17 : (t - 5000) * 3 - 100;
                    break;
                default:
                    v = i32(state);
                    break;
                }
                out.push_back(i32(static_cast<uint32_t>(v)));
            }
    return out;
}

struct EncoderCase {
    int vid, nsig, bps, spf, nframes;
    std::vector<int> kinds;
    size_t size;            // bytes written by the Python encoder
    const char *digest;     // MD5 of those bytes
    uint32_t sum;           // sum of the input samples (mod 2^32)
};

const EncoderCase encoder_cases[] = {
    {0, 2, 16, 1, 10000, {0, 1}, 26203, "5495badb24f7c490c5484be5441c2f76",
     4257896572u},
    {1, 1, 24, 2, 6000, {0}, 11846, "40596f848ca112518ce4d7c573aa9622",
     1739685865u},
    {2, 3, 8, 1, 7000, {2, 0, 1}, 11704, "0efb1695c22420deb64837c433e39c61",
     5422484u},
    {3, 1, 16, 1, 100, {0}, 130, "109b65398fce5e82b3817c267a879467", 262406u},
    {4, 1, 16, 1, 300, {3}, 671, "459bc9a342c66d4d1c720002dd7670e2",
     3379252398u},
    {5, 2, 24, 3, 3000, {1, 2}, 27782, "25779b07efedeaadef4350bbb5148b01",
     4163323067u},
};

// Encode a complete stream as the WFDB library writes it (the final
// STREAMINFO block replaces the provisional one at offset 8).
std::string encode(const EncoderCase &ec, const std::vector<int32_t> &x)
{
    Encoder enc(ec.nsig, ec.bps, ec.spf);
    std::string out = enc.header();
    for (int32_t v : x) enc.put(v, out);
    enc.finish(out);
    std::string si = enc.streaminfo();
    out.replace(8, si.size(), si);
    return out;
}

int32_t wrap(int32_t v, int bps)
{
    uint32_t mask = (uint32_t(1) << bps) - 1, half = uint32_t(1) << (bps - 1);
    return static_cast<int32_t>(
        static_cast<int64_t>((static_cast<uint32_t>(v) + half) & mask) -
        static_cast<int64_t>(half));
}

} // namespace

WFDBX_TEST(md5_vectors)
{
    CHECK_EQ(md5_hex("", 0), "d41d8cd98f00b204e9800998ecf8427e");
    CHECK_EQ(md5_hex("abc", 3), "900150983cd24fb0d6963f7d28e17f72");
    std::vector<unsigned char> v;
    for (int r = 0; r < 5; r++)
        for (int i = 0; i < 256; i++) v.push_back(static_cast<unsigned char>(i));
    CHECK_EQ(md5_hex(v.data(), v.size()), "82829f1f3f2bb0f18b25f278e5bba8bd");
    // the same data in pieces of various sizes
    MD5 m;
    size_t pos = 0, step = 1;
    while (pos < v.size()) {
        size_t k = std::min(step, v.size() - pos);
        m.update(v.data() + pos, k);
        pos += k;
        step = step * 3 + 1;
    }
    unsigned char d[16];
    m.digest(d);
    CHECK_EQ(hex(d), "82829f1f3f2bb0f18b25f278e5bba8bd");
}

WFDBX_TEST(flac_decode_records)
{
    for (const RecordCase &rc : records) {
        std::vector<unsigned char> data;
        REQUIRE(read_file(wfdbx_tests::data_dir() + "/" + rc.name + ".dat",
                          data));
        Decoded d = decode(data.data(), data.size(), 0, 0);
        REQUIRE(d.status == Status::ok);
        CHECK_EQ(d.channels, rc.channels);
        CHECK_EQ(d.bps, rc.bps);
        REQUIRE(d.chans.size() == static_cast<size_t>(rc.channels));
        CHECK_EQ(d.chans[0].size(), rc.nsamp);
        CHECK_EQ(samples_digest(d.chans), std::string(rc.digest));
        for (int i = 0; i < 3; i++) CHECK_EQ(d.chans[0][i], rc.first[i]);
        CHECK_EQ(d.chans.back().back(), rc.last);
        // The MD5 signature in STREAMINFO matches the decoded samples.
        CHECK(d.has_md5);
        unsigned char md5[16];
        samples_md5(d.chans, d.bps, md5);
        CHECK(std::memcmp(md5, d.md5, 16) == 0);
        // Decoding with the expected numbers of signals and bits
        Decoded d2 = decode(data.data(), data.size(), rc.channels, rc.bps);
        CHECK(d2.status == Status::ok);
        CHECK(d2.chans == d.chans);
        // Trailing zero bytes are ignored.
        std::vector<unsigned char> padded = data;
        padded.resize(padded.size() + 100, 0);
        Decoded d3 = decode(padded.data(), padded.size(), 0, 0);
        CHECK(d3.status == Status::ok);
        CHECK(d3.chans == d.chans);
        // A truncated stream cannot be decoded.
        Decoded d4 = decode(data.data(), data.size() - 3, 0, 0);
        CHECK(d4.status != Status::ok);
        // Neither can a stream with a corrupted frame.
        std::vector<unsigned char> bad = data;
        bad[bad.size() / 2] ^= 0x10;
        Decoded d5 = decode(bad.data(), bad.size(), 0, 0);
        CHECK(d5.status != Status::ok);
        // nor something that is not a FLAC stream.
        Decoded d6 = decode(data.data() + 1, data.size() - 1, 0, 0);
        CHECK(d6.status == Status::meta);
    }
}

WFDBX_TEST(flac_encoder_matches_python)
{
    for (const EncoderCase &ec : encoder_cases) {
        std::vector<int32_t> x =
            gen(ec.vid, ec.nsig, ec.bps, ec.spf, ec.nframes, ec.kinds);
        uint32_t sum = 0;
        for (int32_t v : x) sum += static_cast<uint32_t>(v);
        REQUIRE(sum == ec.sum);
        std::string bytes = encode(ec, x);
        CHECK_EQ(bytes.size(), ec.size);
        CHECK_EQ(md5_hex(bytes.data(), bytes.size()), std::string(ec.digest));
        // The vendor string
        CHECK(bytes.find("wfdb-x") != std::string::npos);

        // Round trip
        Decoded d = decode(reinterpret_cast<const unsigned char *>(bytes.data()),
                           bytes.size(), ec.nsig, ec.bps);
        REQUIRE(d.status == Status::ok);
        CHECK_EQ(d.channels, ec.nsig);
        CHECK_EQ(d.bps, ec.bps);
        REQUIRE(d.chans.size() == static_cast<size_t>(ec.nsig));
        size_t nper = static_cast<size_t>(ec.nframes) * ec.spf;
        bool same = true;
        for (int s = 0; s < ec.nsig; s++) {
            REQUIRE(d.chans[s].size() == nper);
            for (int f = 0; f < ec.nframes; f++)
                for (int k = 0; k < ec.spf; k++) {
                    size_t in = (static_cast<size_t>(f) * ec.nsig + s) * ec.spf + k;
                    if (d.chans[s][static_cast<size_t>(f) * ec.spf + k] !=
                        wrap(x[in], ec.bps))
                        same = false;
                }
        }
        CHECK(same);
        unsigned char md5[16];
        samples_md5(d.chans, d.bps, md5);
        CHECK(d.has_md5 && std::memcmp(md5, d.md5, 16) == 0);
    }
}

WFDBX_TEST(flac_encoder_incomplete_frame)
{
    // Samples of an incomplete frame (fewer than nsig*spf) are not written.
    Encoder enc(2, 16, 1);
    std::string out = enc.header();
    for (int i = 0; i < 9; i++) enc.put(i * 100, out);
    enc.finish(out);
    std::string si = enc.streaminfo();
    out.replace(8, si.size(), si);
    Decoded d = decode(reinterpret_cast<const unsigned char *>(out.data()),
                       out.size(), 0, 0);
    REQUIRE(d.status == Status::ok);
    REQUIRE(d.chans.size() == 2);
    CHECK_EQ(d.chans[0].size(), 4u);
    CHECK_EQ(d.chans[1][3], 700);
    // The wrong number of signals is detected when expected.
    Decoded d2 = decode(reinterpret_cast<const unsigned char *>(out.data()),
                        out.size(), 3, 16);
    CHECK(d2.status == Status::wfdb);
    Decoded d3 = decode(reinterpret_cast<const unsigned char *>(out.data()),
                        out.size(), 2, 8);
    CHECK(d3.status == Status::wfdb);
}
