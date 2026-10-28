// flac.cpp: FLAC decoder and encoder for signal formats 508, 516, and 524
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// Its FLAC decoder is a C++ translation of the stream decoder of libFLAC
// 1.4.3 (src/libFLAC/stream_decoder.c and bitreader.c, and the restore
// functions of fixed.c and lpc.c), made so that damaged files are decoded,
// resynchronized and reported exactly as by the C library, which uses
// libFLAC.  Its FLAC encoder is WFDB-x's own implementation of the FLAC
// format; it has no counterpart in the original package.  WFDB-x needs no
// external library at run time.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// libFLAC is distributed under the following license, which applies to the
// parts of this file translated from it (the stream decoder):
//
// Copyright (C) 2000-2009  Josh Coalson
// Copyright (C) 2011-2023  Xiph.Org Foundation
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// - Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//
// - Redistributions in binary form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// - Neither the name of the Xiph.org Foundation nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
// LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
// NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// The C library uses libFLAC for these formats; WFDB-x implements, without
// external libraries, a complete FLAC decoder and a lossless encoder (fixed
// predictors and Rice coding).  The decoder is a port of the parts of
// libFLAC 1.4.3 that the C library uses (stream_decoder.c and bitreader.c,
// and the restore functions of fixed.c and lpc.c, under the license above),
// so that damaged files are decoded, resynchronized and reported as libFLAC
// does.  The encoder (a port of python/src/wfdbx/_flac.py) writes exactly
// the bytes written by the Python implementation of WFDB-x.

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

} // namespace

// ---------------------------------------------------------------------------
// Stream decoder (a port of libFLAC 1.4.3, stream_decoder.c and bitreader.c;
// functions keep the names of their libFLAC counterparts)

namespace {

// The bit reader keeps the bytes it has read in big-endian words of 64 bits
// (libFLAC's default on 64-bit hosts), in a buffer of 8192 bytes.  Which
// data are still in the buffer matters: a damaged frame is re-read from
// the buffer or from the file, and the fast Rice decoder only checks the
// size of a value that is in complete words.
typedef uint64_t brword;
constexpr unsigned BR_WORD_BITS = 64;
constexpr unsigned BR_WORD_BYTES = 8;
constexpr uint32_t BR_CAPACITY = 65536u / BR_WORD_BITS;    // in words
constexpr brword BR_ALL_ONES = ~brword(0);
constexpr uint32_t BR_NO_FRAMESYNC = UINT32_MAX;

// Metadata and frame fields (lengths in bits)
constexpr unsigned META_IS_LAST_LEN = 1, META_TYPE_LEN = 7, META_LENGTH_LEN = 24;
constexpr unsigned META_APPLICATION = 2, META_SEEKTABLE = 3;
constexpr unsigned APPLICATION_ID_BYTES = 4;
constexpr uint32_t SEEKPOINT_BYTES = 18;
constexpr uint64_t SEEKPOINT_PLACEHOLDER = ~uint64_t(0);
constexpr unsigned ENTROPY_TYPE_LEN = 2, RICE_ORDER_LEN = 4, RICE_RAW_LEN = 5;
constexpr unsigned QLP_PRECISION_LEN = 4, QLP_SHIFT_LEN = 5;
constexpr unsigned FOOTER_CRC_LEN = 16;
constexpr int CA_INDEPENDENT = 0, CA_LEFT_SIDE = 1, CA_RIGHT_SIDE = 2,
              CA_MID_SIDE = 3;
const unsigned char ID3V2_TAG[3] = {'I', 'D', '3'};

inline unsigned clz2(brword w)  // COUNT_ZERO_MSBS2: 64 if w == 0
{
    return w ? static_cast<unsigned>(clz64(w)) : BR_WORD_BITS;
}

inline uint32_t crc16_byte(uint32_t data, uint32_t crc)    // FLAC__CRC16_UPDATE
{
    return ((crc << 8) & 0xFFFF) ^ crc_tables().crc16[(crc >> 8) ^ data];
}

uint32_t silog2(int64_t v)      // FLAC__bitmath_silog2
{
    if (v == 0) return 0;
    if (v == -1) return 2;
    uint64_t u = static_cast<uint64_t>(v < 0 ? -(v + 1) : v);
    return static_cast<uint32_t>(bit_length(u) - 1) + 2;
}

} // namespace

struct StreamDecoder::Impl {
    explicit Impl(StreamClient &c) : client(c), buffer(BR_CAPACITY, 0) {}

    StreamClient &client;
    State state = State::search_for_metadata;

    // Bit reader (FLAC__BitReader)
    std::vector<brword> buffer;
    uint32_t words = 0;             // complete words in buffer
    uint32_t bytes = 0;             // bytes of the incomplete word at buffer[words]
    uint32_t consumed_words = 0, consumed_bits = 0;
    uint32_t read_crc16 = 0, crc16_offset = 0, crc16_align = 0;
    uint32_t br_framesync = BR_NO_FRAMESYNC;   // in bytes from the front
    unsigned char staging[BR_CAPACITY * BR_WORD_BYTES];

    // Decoder (FLAC__StreamDecoderPrivate and Protected)
    bool md5_checking = false, do_md5_checking = false;
    bool has_stream_info = false, has_seek_table = false;
    bool is_seeking = false, cached = false, last_frame_is_set = false;
    bool side_subframe_in_use = false;
    struct {
        uint32_t min_blocksize = 0, max_blocksize = 0;
        uint32_t min_framesize = 0, max_framesize = 0;
        uint32_t sample_rate = 0, channels = 0, bits_per_sample = 0;
        uint64_t total_samples = 0;
        unsigned char md5sum[16] = {};
    } stream_info;
    struct SeekPoint {
        uint64_t sample_number, stream_offset;
        uint32_t frame_samples;
    };
    std::vector<SeekPoint> seek_table;
    uint64_t first_frame_offset = 0, samples_decoded = 0;
    uint64_t last_seen_framesync = 0, target_sample = 0;
    uint32_t fixed_block_size = 0, next_fixed_block_size = 0;
    uint32_t unparseable_frame_count = 0;
    unsigned char lookahead = 0, header_warmup[2] = {};
    FrameHeader frame, last_frame;
    uint32_t wasted_bits[MAX_CHANNELS] = {};
    std::vector<int32_t> output[MAX_CHANNELS];
    std::vector<int32_t> residual;
    std::vector<int64_t> side_subframe;
    uint32_t channels = 0, bits_per_sample = 0;    // of the last frame
    MD5 md5;

    // -- bit reader --------------------------------------------------------

    void br_clear()
    {
        words = bytes = 0;
        consumed_words = consumed_bits = 0;
        br_framesync = BR_NO_FRAMESYNC;
    }

    void crc16_update_word(brword word)
    {
        uint32_t crc = read_crc16;
        for (; crc16_align < BR_WORD_BITS; crc16_align += 8) {
            unsigned shift = BR_WORD_BITS - 8 - crc16_align;
            crc = crc16_byte(static_cast<uint32_t>((word >> shift) & 0xFF), crc);
        }
        read_crc16 = crc;
        crc16_align = 0;
    }

    void crc16_update_block()
    {
        if (consumed_words > crc16_offset && crc16_align)
            crc16_update_word(buffer[crc16_offset++]);
        for (uint32_t i = crc16_offset; i < consumed_words; i++) {
            brword w = buffer[i];
            for (int k = 56; k >= 0; k -= 8)
                read_crc16 = crc16_byte(static_cast<uint32_t>((w >> k) & 0xFF),
                                        read_crc16);
        }
        crc16_offset = 0;
    }

    bool br_read_from_client()
    {
        if (consumed_words > 0) {
            br_framesync = BR_NO_FRAMESYNC;
            crc16_update_block();
            uint32_t start = consumed_words, end = words + (bytes ? 1 : 0);
            std::memmove(buffer.data(), buffer.data() + start,
                         BR_WORD_BYTES * (end - start));
            words -= start;
            consumed_words = 0;
        }
        size_t n = (BR_CAPACITY - words) * BR_WORD_BYTES - bytes;
        if (n == 0) return false;
        if (!read_callback(staging, &n)) return false;
        uint32_t pos = words * BR_WORD_BYTES + bytes;
        for (size_t i = 0; i < n; i++, pos++) {
            brword &w = buffer[pos / BR_WORD_BYTES];
            unsigned shift = 56 - 8 * (pos % BR_WORD_BYTES);
            w = (w & ~(brword(0xFF) << shift)) | (brword(staging[i]) << shift);
        }
        words = pos / BR_WORD_BYTES;
        bytes = pos % BR_WORD_BYTES;
        return true;
    }

    uint32_t bits_unconsumed() const
    {
        return (words - consumed_words) * BR_WORD_BITS + bytes * 8 -
               consumed_bits;
    }

    bool byte_aligned() const { return (consumed_bits & 7) == 0; }

    unsigned bits_left_for_byte_alignment() const
    {
        return 8 - (consumed_bits & 7);
    }

    void set_framesync_location()
    {
        br_framesync = consumed_words * BR_WORD_BYTES + consumed_bits / 8;
    }

    bool rewind_to_after_last_seen_framesync()
    {
        if (br_framesync == BR_NO_FRAMESYNC) {
            consumed_words = consumed_bits = 0;
            return false;
        }
        consumed_words = (br_framesync + 1) / BR_WORD_BYTES;
        consumed_bits = ((br_framesync + 1) % BR_WORD_BYTES) * 8;
        return true;
    }

    void reset_read_crc16(uint32_t seed)
    {
        read_crc16 = seed;
        crc16_offset = consumed_words;
        crc16_align = consumed_bits;
    }

    uint32_t get_read_crc16()
    {
        crc16_update_block();
        if (consumed_bits) {
            const brword tail = buffer[consumed_words];
            for (; crc16_align < consumed_bits; crc16_align += 8)
                read_crc16 = crc16_byte(static_cast<uint32_t>(
                    (tail >> (BR_WORD_BITS - 8 - crc16_align)) & 0xFF),
                    read_crc16);
        }
        return read_crc16;
    }

    bool read_raw_uint32(uint32_t &val, unsigned nbits)
    {
        if (nbits == 0) {
            val = 0;
            return true;
        }
        while (bits_unconsumed() < nbits)
            if (!br_read_from_client()) return false;
        if (consumed_words < words) {
            const brword word = buffer[consumed_words];
            const unsigned n = BR_WORD_BITS - consumed_bits;
            const brword mask = consumed_bits < BR_WORD_BITS
                                    ? BR_ALL_ONES >> consumed_bits : 0;
            if (nbits < n) {
                val = static_cast<uint32_t>((word & mask) >> (n - nbits));
                consumed_bits += nbits;
                return true;
            }
            val = static_cast<uint32_t>(word & mask);
            nbits -= n;
            consumed_words++;
            consumed_bits = 0;
            if (nbits) {
                val = nbits < 32 ? val << nbits : 0;
                val |= static_cast<uint32_t>(buffer[consumed_words] >>
                                             (BR_WORD_BITS - nbits));
                consumed_bits = nbits;
            }
            return true;
        }
        // a partial tail word holds at least nbits bits
        val = static_cast<uint32_t>(
            (buffer[consumed_words] & (BR_ALL_ONES >> consumed_bits)) >>
            (BR_WORD_BITS - consumed_bits - nbits));
        consumed_bits += nbits;
        return true;
    }

    bool read_raw_int32(int32_t &val, unsigned nbits)
    {
        uint32_t u;
        if (nbits < 1 || !read_raw_uint32(u, nbits)) return false;
        uint32_t mask = nbits >= 33 ? 0 : uint32_t(1) << (nbits - 1);
        val = static_cast<int32_t>((u ^ mask) - mask);
        return true;
    }

    bool read_raw_uint64(uint64_t &val, unsigned nbits)
    {
        uint32_t hi, lo;
        if (nbits > 32) {
            if (!read_raw_uint32(hi, nbits - 32)) return false;
            if (!read_raw_uint32(lo, 32)) return false;
            val = (uint64_t(hi) << 32) | lo;
        } else {
            if (!read_raw_uint32(lo, nbits)) return false;
            val = lo;
        }
        return true;
    }

    bool read_raw_int64(int64_t &val, unsigned nbits)
    {
        uint64_t u;
        if (nbits < 1 || !read_raw_uint64(u, nbits)) return false;
        uint64_t mask = nbits >= 65 ? 0 : uint64_t(1) << (nbits - 1);
        val = static_cast<int64_t>((u ^ mask) - mask);
        return true;
    }

    // FLAC__bitreader_read_byte_block_aligned_no_crc (val may be null:
    // FLAC__bitreader_skip_byte_block_aligned_no_crc)
    bool read_byte_block(unsigned char *val, uint32_t nvals)
    {
        uint32_t x;
        while (nvals && consumed_bits) {
            if (!read_raw_uint32(x, 8)) return false;
            if (val) *val++ = static_cast<unsigned char>(x);
            nvals--;
        }
        if (nvals == 0) return true;
        while (nvals >= BR_WORD_BYTES) {
            if (consumed_words < words) {
                const brword word = buffer[consumed_words++];
                if (val)
                    for (unsigned k = 0; k < BR_WORD_BYTES; k++)
                        *val++ = static_cast<unsigned char>(
                            word >> (8 * (BR_WORD_BYTES - k - 1)));
                nvals -= BR_WORD_BYTES;
            } else if (!br_read_from_client())
                return false;
        }
        while (nvals) {
            if (!read_raw_uint32(x, 8)) return false;
            if (val) *val++ = static_cast<unsigned char>(x);
            nvals--;
        }
        return true;
    }

    bool read_unary_unsigned(uint32_t &val)
    {
        val = 0;
        for (;;) {
            while (consumed_words < words) {
                brword b = consumed_bits < BR_WORD_BITS
                               ? buffer[consumed_words] << consumed_bits : 0;
                if (b) {
                    unsigned i = static_cast<unsigned>(clz64(b));
                    val += i;
                    consumed_bits += i + 1;
                    if (consumed_bits >= BR_WORD_BITS) {
                        consumed_words++;
                        consumed_bits = 0;
                    }
                    return true;
                }
                val += BR_WORD_BITS - consumed_bits;
                consumed_words++;
                consumed_bits = 0;
            }
            if (bytes * 8 > consumed_bits) {
                const unsigned end = bytes * 8;
                brword b = (buffer[consumed_words] &
                            (BR_ALL_ONES << (BR_WORD_BITS - end))) << consumed_bits;
                if (b) {
                    unsigned i = static_cast<unsigned>(clz64(b));
                    val += i;
                    consumed_bits += i + 1;
                    return true;
                }
                val += end - consumed_bits;
                consumed_bits = end;
            }
            if (!br_read_from_client()) return false;
        }
    }

    // FLAC__bitreader_read_rice_signed_block (returns false without a
    // change of state for a value that does not fit in 32 bits).  The
    // labels of the original are flags here.
    bool read_rice_signed_block(int32_t *vals, uint32_t nvals,
                                unsigned parameter)
    {
        uint32_t cwords, nwords, lsbs, msbs = 0, x, y, limit, ucbits = 0;
        brword b = 0;
        uint32_t k = 0;     // values read
        const auto put = [&](uint32_t u) {
            // (when entered at its end, the original stores one value
            // more, which the caller overwrites)
            if (k < nvals)
                vals[k] = static_cast<int32_t>(u >> 1) ^ -static_cast<int32_t>(u & 1);
            k++;
        };

        limit = UINT32_MAX >> parameter;
        if (parameter == 0) {
            while (k < nvals) {
                if (!read_unary_unsigned(msbs)) return false;
                put(msbs);
            }
            return true;
        }
        cwords = consumed_words;
        nwords = words;
        bool process_tail = false, incomplete_lsbs = false;
        if (cwords >= nwords) {
            x = 0;
            process_tail = true;
        } else {
            ucbits = BR_WORD_BITS - consumed_bits;
            b = buffer[cwords] << consumed_bits;
        }
        while (process_tail || k < nvals) {
            if (!process_tail) {
                x = y = clz2(b);
                if (x == BR_WORD_BITS) {
                    x = ucbits;
                    do {
                        cwords++;
                        if (cwords >= nwords) {     // incomplete_msbs
                            consumed_bits = 0;
                            consumed_words = cwords;
                            process_tail = true;
                            break;
                        }
                        b = buffer[cwords];
                        y = clz2(b);
                        x += y;
                    } while (y == BR_WORD_BITS);
                }
                if (!process_tail) {
                    b <<= y;
                    b <<= 1;
                    ucbits = (ucbits - x - 1) % BR_WORD_BITS;
                    msbs = x;
                    if (x > limit) return false;
                    x = static_cast<uint32_t>(b >> (BR_WORD_BITS - parameter));
                    if (parameter <= ucbits) {
                        ucbits -= parameter;
                        b <<= parameter;
                    } else {
                        cwords++;
                        if (cwords >= nwords) {     // incomplete_lsbs
                            consumed_bits = 0;
                            consumed_words = cwords;
                            process_tail = incomplete_lsbs = true;
                        } else {
                            b = buffer[cwords];
                            ucbits += BR_WORD_BITS - parameter;
                            x |= static_cast<uint32_t>(b >> ucbits);
                            b <<= BR_WORD_BITS - ucbits;
                        }
                    }
                    if (!process_tail) {
                        lsbs = x;
                        put((msbs << parameter) | lsbs);
                        continue;
                    }
                }
            }
            // process_tail: the whole words have been consumed
            process_tail = false;
            do {
                if (!incomplete_lsbs) {
                    if (!read_unary_unsigned(msbs)) return false;
                    msbs += x;
                    x = ucbits = 0;
                }
                incomplete_lsbs = false;
                if (!read_raw_uint32(lsbs, parameter - ucbits)) return false;
                lsbs = x | lsbs;
                put((msbs << parameter) | lsbs);
                x = 0;
                cwords = consumed_words;
                nwords = words;
                ucbits = BR_WORD_BITS - consumed_bits;
                b = cwords < BR_CAPACITY ? buffer[cwords] << consumed_bits : 0;
            } while (cwords >= nwords && k < nvals);
        }
        if (ucbits == 0 && cwords < nwords) {
            cwords++;
            ucbits = BR_WORD_BITS;
        }
        consumed_bits = BR_WORD_BITS - ucbits;
        consumed_words = cwords;
        return true;
    }

    // FLAC__bitreader_read_utf8_uint32 and _uint64 (wide): val is all ones
    // if the sequence is invalid
    bool read_utf8(uint64_t &val, bool wide, unsigned char *raw,
                   uint32_t &rawlen)
    {
        uint64_t v = 0;
        uint32_t x;
        unsigned i;
        const uint64_t invalid = wide ? ~uint64_t(0) : 0xFFFFFFFFu;
        if (!read_raw_uint32(x, 8)) return false;
        raw[rawlen++] = static_cast<unsigned char>(x);
        if (!(x & 0x80)) {
            v = x;
            i = 0;
        } else if (x & 0xC0 && !(x & 0x20)) {
            v = x & 0x1F;
            i = 1;
        } else if (x & 0xE0 && !(x & 0x10)) {
            v = x & 0x0F;
            i = 2;
        } else if (x & 0xF0 && !(x & 0x08)) {
            v = x & 0x07;
            i = 3;
        } else if (x & 0xF8 && !(x & 0x04)) {
            v = x & 0x03;
            i = 4;
        } else if (x & 0xFC && !(x & 0x02)) {
            v = x & 0x01;
            i = 5;
        } else if (wide && x & 0xFE && !(x & 0x01)) {
            v = 0;
            i = 6;
        } else {
            val = invalid;
            return true;
        }
        for (; i; i--) {
            if (!read_raw_uint32(x, 8)) return false;
            raw[rawlen++] = static_cast<unsigned char>(x);
            if (!(x & 0x80) || (x & 0x40)) {
                val = invalid;
                return true;
            }
            v = (v << 6) | (x & 0x3F);
        }
        val = wide ? v : (v & 0xFFFFFFFFu);
        return true;
    }

    // -- decoder -----------------------------------------------------------

    uint64_t total_samples() const
    {
        return has_stream_info ? stream_info.total_samples : 0;
    }

    void send_error(ErrorStatus status)
    {
        if (!is_seeking)
            client.error(status);
        else if (status == ErrorStatus::unparseable_stream)
            unparseable_frame_count++;
    }

    bool read_callback(unsigned char *buf, size_t *n)
    {
        if (client.eof()) {
            *n = 0;
            state = State::end_of_stream;
            return false;
        }
        if (*n > 0) {
            if (is_seeking && unparseable_frame_count > 20) {
                state = State::aborted;
                return false;
            }
            ReadStatus status = client.read(buf, n);
            if (status == ReadStatus::abort) {
                state = State::aborted;
                return false;
            }
            if (*n == 0) {
                if (status == ReadStatus::end_of_stream || client.eof()) {
                    state = State::end_of_stream;
                    return false;
                }
            }
            return true;
        }
        state = State::aborted;
        return false;
    }

    bool get_decode_position(uint64_t &position)
    {
        if (client.tell(&position) != CallbackStatus::ok) return false;
        if (!byte_aligned()) return false;
        position -= bits_unconsumed() / 8;
        return true;
    }

    bool reset()    // FLAC__stream_decoder_reset, as called by init
    {
        if (!flush()) return false;
        state = State::search_for_metadata;
        has_stream_info = false;
        seek_table.clear();
        has_seek_table = false;
        do_md5_checking = md5_checking;
        fixed_block_size = next_fixed_block_size = 0;
        md5 = MD5();
        first_frame_offset = 0;
        unparseable_frame_count = 0;
        last_seen_framesync = 0;
        last_frame_is_set = false;
        return true;
    }

    bool flush()
    {
        samples_decoded = 0;
        do_md5_checking = false;
        last_seen_framesync = 0;
        last_frame_is_set = false;
        br_clear();
        state = State::search_for_frame_sync;
        return true;
    }

    bool find_metadata()
    {
        static const unsigned char SYNC_STRING[4] = {'f', 'L', 'a', 'C'};
        uint32_t x;
        unsigned i, id;
        bool first = true;

        for (i = id = 0; i < 4;) {
            if (cached) {
                x = lookahead;
                cached = false;
            } else if (!read_raw_uint32(x, 8))
                return false;
            if (x == SYNC_STRING[i]) {
                first = true;
                i++;
                id = 0;
                continue;
            }
            if (id >= 3) return false;
            if (x == ID3V2_TAG[id]) {
                id++;
                i = 0;
                if (id == 3 && !skip_id3v2_tag()) return false;
                continue;
            }
            id = 0;
            if (x == 0xFF) {
                header_warmup[0] = static_cast<unsigned char>(x);
                if (!read_raw_uint32(x, 8)) return false;
                if (x == 0xFF) {
                    lookahead = static_cast<unsigned char>(x);
                    cached = true;
                } else if (x >> 1 == 0x7C) {
                    header_warmup[1] = static_cast<unsigned char>(x);
                    state = State::read_frame;
                    return true;
                }
            }
            i = 0;
            if (first) {
                send_error(ErrorStatus::lost_sync);
                first = false;
            }
        }
        state = State::read_metadata;
        return true;
    }

    bool read_metadata()
    {
        uint32_t x, type, length;
        if (!read_raw_uint32(x, META_IS_LAST_LEN)) return false;
        const bool is_last = x != 0;
        if (!read_raw_uint32(type, META_TYPE_LEN)) return false;
        if (!read_raw_uint32(length, META_LENGTH_LEN)) return false;

        if (type == META_STREAMINFO) {
            if (!read_metadata_streaminfo(length)) return false;
            has_stream_info = true;
            static const unsigned char zeros[16] = {};
            if (std::memcmp(stream_info.md5sum, zeros, 16) == 0)
                do_md5_checking = false;
        } else if (type == META_SEEKTABLE) {
            has_seek_table = false;
            if (length > 0) {
                if (!read_metadata_seektable(length)) return false;
                has_seek_table = true;
            }
        } else {
            // Other blocks are skipped (the C library does not ask for
            // them).
            uint32_t real_length = length;
            if (type == META_APPLICATION) {
                unsigned char id[APPLICATION_ID_BYTES];
                if (!read_byte_block(id, APPLICATION_ID_BYTES)) return false;
                if (real_length < APPLICATION_ID_BYTES) {
                    state = State::memory_allocation_error;
                    return false;
                }
                real_length -= APPLICATION_ID_BYTES;
            }
            if (!read_byte_block(nullptr, real_length)) return false;
        }
        if (is_last) {
            if (!get_decode_position(first_frame_offset))
                first_frame_offset = 0;
            state = State::search_for_frame_sync;
        }
        return true;
    }

    bool read_metadata_streaminfo(uint32_t length)
    {
        uint32_t x;
        if (!read_raw_uint32(x, 16)) return false;
        stream_info.min_blocksize = x;
        if (!read_raw_uint32(x, 16)) return false;
        stream_info.max_blocksize = x;
        if (!read_raw_uint32(x, 24)) return false;
        stream_info.min_framesize = x;
        if (!read_raw_uint32(x, 24)) return false;
        stream_info.max_framesize = x;
        if (!read_raw_uint32(x, 20)) return false;
        stream_info.sample_rate = x;
        if (!read_raw_uint32(x, 3)) return false;
        stream_info.channels = x + 1;
        if (!read_raw_uint32(x, 5)) return false;
        stream_info.bits_per_sample = x + 1;
        if (!read_raw_uint64(stream_info.total_samples, 36)) return false;
        if (!read_byte_block(stream_info.md5sum, 16)) return false;
        const uint32_t used = static_cast<uint32_t>(STREAMINFO_LEN);
        if (length < used) return false;
        return read_byte_block(nullptr, length - used);
    }

    bool read_metadata_seektable(uint32_t length)
    {
        if (length % SEEKPOINT_BYTES) return false;
        const uint32_t n = length / SEEKPOINT_BYTES;
        seek_table.assign(n, SeekPoint{0, 0, 0});
        for (uint32_t i = 0; i < n; i++) {
            uint64_t xx;
            uint32_t x;
            if (!read_raw_uint64(xx, 64)) return false;
            seek_table[i].sample_number = xx;
            if (!read_raw_uint64(xx, 64)) return false;
            seek_table[i].stream_offset = xx;
            if (!read_raw_uint32(x, 16)) return false;
            seek_table[i].frame_samples = x;
        }
        return true;
    }

    bool skip_id3v2_tag()
    {
        uint32_t x, skip = 0;
        if (!read_raw_uint32(x, 24)) return false;  // version and flags
        for (int i = 0; i < 4; i++) {
            if (!read_raw_uint32(x, 8)) return false;
            skip = (skip << 7) | (x & 0x7F);
        }
        return read_byte_block(nullptr, skip);
    }

    bool frame_sync()
    {
        uint32_t x;
        bool first = true;
        if (!byte_aligned() &&
            !read_raw_uint32(x, bits_left_for_byte_alignment()))
            return false;
        for (;;) {
            if (cached) {
                x = lookahead;
                cached = false;
            } else if (!read_raw_uint32(x, 8))
                return false;
            if (x == 0xFF) {
                header_warmup[0] = static_cast<unsigned char>(x);
                if (!read_raw_uint32(x, 8)) return false;
                if (x == 0xFF) {
                    lookahead = static_cast<unsigned char>(x);
                    cached = true;
                } else if (x >> 1 == 0x7C) {
                    header_warmup[1] = static_cast<unsigned char>(x);
                    state = State::read_frame;
                    set_framesync_location();
                    if (!get_decode_position(last_seen_framesync))
                        last_seen_framesync = 0;
                    return true;
                }
            }
            if (first) {
                send_error(ErrorStatus::lost_sync);
                first = false;
            }
        }
    }

    // A header error: resynchronize (the last byte read may start a sync
    // code if `cache`).
    bool header_error(ErrorStatus status, const unsigned char *raw,
                      uint32_t rawlen, bool cache)
    {
        if (cache) {
            lookahead = raw[rawlen - 1];
            cached = true;
        }
        send_error(status);
        state = State::search_for_frame_sync;
        return true;
    }

    bool read_frame_header()
    {
        uint32_t x;
        uint64_t xx;
        uint32_t blocksize_hint = 0, sample_rate_hint = 0;
        unsigned char raw[16];
        uint32_t rawlen = 2;
        bool is_unparseable = false;

        raw[0] = header_warmup[0];
        raw[1] = header_warmup[1];
        if (raw[1] & 0x02) is_unparseable = true;
        for (int i = 0; i < 2; i++) {
            if (!read_raw_uint32(x, 8)) return false;
            if (x == 0xFF) {
                lookahead = static_cast<unsigned char>(x);
                cached = true;
                send_error(ErrorStatus::bad_header);
                state = State::search_for_frame_sync;
                return true;
            }
            raw[rawlen++] = static_cast<unsigned char>(x);
        }

        switch (x = raw[2] >> 4) {
        case 0: is_unparseable = true; break;
        case 1: frame.blocksize = 192; break;
        case 2: case 3: case 4: case 5: frame.blocksize = 576u << (x - 2); break;
        case 6: case 7: blocksize_hint = x; break;
        default: frame.blocksize = 256u << (x - 8); break;
        }

        switch (x = raw[2] & 0x0F) {
        case 0:
            if (has_stream_info)
                frame.sample_rate = stream_info.sample_rate;
            else
                is_unparseable = true;
            break;
        case 1: frame.sample_rate = 88200; break;
        case 2: frame.sample_rate = 176400; break;
        case 3: frame.sample_rate = 192000; break;
        case 4: frame.sample_rate = 8000; break;
        case 5: frame.sample_rate = 16000; break;
        case 6: frame.sample_rate = 22050; break;
        case 7: frame.sample_rate = 24000; break;
        case 8: frame.sample_rate = 32000; break;
        case 9: frame.sample_rate = 44100; break;
        case 10: frame.sample_rate = 48000; break;
        case 11: frame.sample_rate = 96000; break;
        case 12: case 13: case 14: sample_rate_hint = x; break;
        default:
            send_error(ErrorStatus::bad_header);
            state = State::search_for_frame_sync;
            return true;
        }

        x = static_cast<uint32_t>(raw[3] >> 4);
        if (x & 8) {
            frame.channels = 2;
            switch (x & 7) {
            case 0: frame.channel_assignment = CA_LEFT_SIDE; break;
            case 1: frame.channel_assignment = CA_RIGHT_SIDE; break;
            case 2: frame.channel_assignment = CA_MID_SIDE; break;
            default: is_unparseable = true; break;
            }
        } else {
            frame.channels = x + 1;
            frame.channel_assignment = CA_INDEPENDENT;
        }

        switch (x = static_cast<uint32_t>(raw[3] & 0x0E) >> 1) {
        case 0:
            if (has_stream_info)
                frame.bits_per_sample = stream_info.bits_per_sample;
            else
                is_unparseable = true;
            break;
        case 1: frame.bits_per_sample = 8; break;
        case 2: frame.bits_per_sample = 12; break;
        case 3: is_unparseable = true; break;
        case 4: frame.bits_per_sample = 16; break;
        case 5: frame.bits_per_sample = 20; break;
        case 6: frame.bits_per_sample = 24; break;
        default: frame.bits_per_sample = 32; break;
        }
        if (raw[3] & 0x01) is_unparseable = true;

        bool frame_number;
        uint32_t frame_no = 0;
        if (raw[1] & 0x01 ||
            (has_stream_info &&
             stream_info.min_blocksize != stream_info.max_blocksize)) {
            if (!read_utf8(xx, true, raw, rawlen)) return false;
            if (xx == ~uint64_t(0))
                return header_error(ErrorStatus::bad_header, raw, rawlen, true);
            frame_number = false;
            frame.sample_number = xx;
        } else {
            if (!read_utf8(xx, false, raw, rawlen)) return false;
            if (xx == 0xFFFFFFFFu)
                return header_error(ErrorStatus::bad_header, raw, rawlen, true);
            frame_number = true;
            frame_no = static_cast<uint32_t>(xx);
        }

        if (blocksize_hint) {
            if (!read_raw_uint32(x, 8)) return false;
            raw[rawlen++] = static_cast<unsigned char>(x);
            if (blocksize_hint == 7) {
                uint32_t x2;
                if (!read_raw_uint32(x2, 8)) return false;
                raw[rawlen++] = static_cast<unsigned char>(x2);
                x = (x << 8) | x2;
            }
            frame.blocksize = x + 1;
            if (frame.blocksize > 65535)
                return header_error(ErrorStatus::bad_header, raw, rawlen, true);
        }

        if (sample_rate_hint) {
            if (!read_raw_uint32(x, 8)) return false;
            raw[rawlen++] = static_cast<unsigned char>(x);
            if (sample_rate_hint != 12) {
                uint32_t x2;
                if (!read_raw_uint32(x2, 8)) return false;
                raw[rawlen++] = static_cast<unsigned char>(x2);
                x = (x << 8) | x2;
            }
            if (sample_rate_hint == 12)
                frame.sample_rate = x * 1000;
            else if (sample_rate_hint == 13)
                frame.sample_rate = x;
            else
                frame.sample_rate = x * 10;
        }

        if (!read_raw_uint32(x, 8)) return false;
        if (crc8(raw, rawlen) != x)
            return header_error(ErrorStatus::bad_header, raw, rawlen, false);

        next_fixed_block_size = 0;
        if (frame_number) {
            x = frame_no;
            if (fixed_block_size)
                frame.sample_number = uint64_t(fixed_block_size) * x;
            else if (has_stream_info) {
                if (stream_info.min_blocksize == stream_info.max_blocksize) {
                    frame.sample_number = uint64_t(stream_info.min_blocksize) * x;
                    next_fixed_block_size = stream_info.max_blocksize;
                } else
                    is_unparseable = true;
            } else if (x == 0) {
                frame.sample_number = 0;
                next_fixed_block_size = frame.blocksize;
            } else
                frame.sample_number = uint64_t(frame.blocksize) * x;
        }

        if (is_unparseable) {
            send_error(ErrorStatus::unparseable_stream);
            state = State::search_for_frame_sync;
        }
        return true;
    }

    bool sync_error(ErrorStatus status)     // resynchronize after an error
    {
        send_error(status);
        state = State::search_for_frame_sync;
        return true;
    }

    // Partition order and entropy coding method of a FIXED or LPC subframe;
    // returns 0 (error: resynchronize), 1 (Rice), 2 (Rice2), or -1 (false).
    int read_entropy_coding(uint32_t order, uint32_t &partition_order)
    {
        uint32_t u32;
        if (!read_raw_uint32(u32, ENTROPY_TYPE_LEN)) return -1;
        if (u32 > 1) {
            sync_error(ErrorStatus::unparseable_stream);
            return 0;
        }
        const int method = static_cast<int>(u32) + 1;
        if (!read_raw_uint32(u32, RICE_ORDER_LEN)) return -1;
        if ((frame.blocksize >> u32 < order) ||
            (frame.blocksize % (1u << u32) > 0)) {
            sync_error(ErrorStatus::lost_sync);
            return 0;
        }
        partition_order = u32;
        return method;
    }

    bool read_residual_partitioned_rice(uint32_t predictor_order,
                                        uint32_t partition_order,
                                        bool is_extended)
    {
        const uint32_t partitions = 1u << partition_order;
        const uint32_t partition_samples = frame.blocksize >> partition_order;
        const unsigned plen = is_extended ? 5 : 4;
        const uint32_t pesc = is_extended ? 31 : 15;
        int32_t *res = residual.data();
        uint32_t sample = 0;
        for (uint32_t partition = 0; partition < partitions; partition++) {
            uint32_t rice_parameter;
            if (!read_raw_uint32(rice_parameter, plen)) return false;
            if (rice_parameter < pesc) {
                uint32_t u = partition == 0 ? partition_samples - predictor_order
                                            : partition_samples;
                if (!read_rice_signed_block(res + sample, u, rice_parameter)) {
                    if (state == State::read_frame)     // invalid Rice symbol
                        return sync_error(ErrorStatus::lost_sync);
                    return false;
                }
                sample += u;
            } else {
                if (!read_raw_uint32(rice_parameter, RICE_RAW_LEN)) return false;
                uint32_t u = partition == 0 ? predictor_order : 0;
                if (rice_parameter == 0) {
                    for (; u < partition_samples; u++, sample++) res[sample] = 0;
                } else {
                    for (; u < partition_samples; u++, sample++) {
                        int32_t i;
                        if (!read_raw_int32(i, rice_parameter)) return false;
                        res[sample] = i;
                    }
                }
            }
        }
        return true;
    }

    bool read_subframe_constant(uint32_t channel, uint32_t bps)
    {
        int64_t x;
        if (!read_raw_int64(x, bps)) return false;
        if (bps <= 32) {
            int32_t v = static_cast<int32_t>(static_cast<uint32_t>(x));
            std::fill(output[channel].begin(),
                      output[channel].begin() + frame.blocksize, v);
        } else {
            side_subframe_in_use = true;
            std::fill(side_subframe.begin(),
                      side_subframe.begin() + frame.blocksize, x);
        }
        return true;
    }

    bool read_subframe_verbatim(uint32_t channel, uint32_t bps)
    {
        if (bps < 33) {
            for (uint32_t i = 0; i < frame.blocksize; i++) {
                int32_t x;
                if (!read_raw_int32(x, bps)) return false;
                residual[i] = x;
            }
            std::copy(residual.begin(), residual.begin() + frame.blocksize,
                      output[channel].begin());
        } else {
            side_subframe_in_use = true;
            for (uint32_t i = 0; i < frame.blocksize; i++) {
                int64_t x;
                if (!read_raw_int64(x, bps)) return false;
                side_subframe[i] = x;
            }
        }
        return true;
    }

    bool read_subframe_fixed(uint32_t channel, uint32_t bps, uint32_t order)
    {
        int64_t warmup[4];
        for (uint32_t u = 0; u < order; u++)
            if (!read_raw_int64(warmup[u], bps)) return false;
        uint32_t porder;
        int method = read_entropy_coding(order, porder);
        if (method <= 0) return method == 0;
        if (!read_residual_partitioned_rice(order, porder, method == 2))
            return false;
        if (state != State::read_frame) return true;
        const uint32_t n = frame.blocksize - order;
        const int32_t *r = residual.data();
        if (bps < 33) {
            // FLAC__fixed_restore_signal and _wide: the result is that of
            // 32-bit arithmetic (wrapping on damaged data)
            uint32_t *d = reinterpret_cast<uint32_t *>(output[channel].data());
            for (uint32_t i = 0; i < order; i++)
                d[i] = static_cast<uint32_t>(warmup[i]);
            d += order;
            for (uint32_t i = 0; i < n; i++) {
                const uint32_t ri = static_cast<uint32_t>(r[i]);
                const uint32_t *h = d + i;
                switch (order) {
                case 0: d[i] = ri; break;
                case 1: d[i] = ri + h[-1]; break;
                case 2: d[i] = ri + 2 * h[-1] - h[-2]; break;
                case 3: d[i] = ri + 3 * h[-1] - 3 * h[-2] + h[-3]; break;
                default:
                    d[i] = ri + 4 * h[-1] - 6 * h[-2] + 4 * h[-3] - h[-4];
                    break;
                }
            }
        } else {
            side_subframe_in_use = true;
            uint64_t *d = reinterpret_cast<uint64_t *>(side_subframe.data());
            for (uint32_t i = 0; i < order; i++)
                d[i] = static_cast<uint64_t>(warmup[i]);
            d += order;
            for (uint32_t i = 0; i < n; i++) {
                const uint64_t ri = static_cast<uint64_t>(int64_t(r[i]));
                const uint64_t *h = d + i;
                switch (order) {
                case 0: d[i] = ri; break;
                case 1: d[i] = ri + h[-1]; break;
                case 2: d[i] = ri + 2 * h[-1] - h[-2]; break;
                case 3: d[i] = ri + 3 * h[-1] - 3 * h[-2] + h[-3]; break;
                default:
                    d[i] = ri + 4 * h[-1] - 6 * h[-2] + 4 * h[-3] - h[-4];
                    break;
                }
            }
        }
        return true;
    }

    bool read_subframe_lpc(uint32_t channel, uint32_t bps, uint32_t order)
    {
        int64_t warmup[32];
        int32_t qlp_coeff[32];
        uint32_t u32;
        int32_t i32;
        for (uint32_t u = 0; u < order; u++)
            if (!read_raw_int64(warmup[u], bps)) return false;
        if (!read_raw_uint32(u32, QLP_PRECISION_LEN)) return false;
        if (u32 == (1u << QLP_PRECISION_LEN) - 1)
            return sync_error(ErrorStatus::lost_sync);
        const unsigned precision = u32 + 1;
        if (!read_raw_int32(i32, QLP_SHIFT_LEN)) return false;
        if (i32 < 0) return sync_error(ErrorStatus::lost_sync);
        const int shift = i32;
        for (uint32_t u = 0; u < order; u++)
            if (!read_raw_int32(qlp_coeff[u], precision)) return false;
        uint32_t porder;
        int method = read_entropy_coding(order, porder);
        if (method <= 0) return method == 0;
        if (!read_residual_partitioned_rice(order, porder, method == 2))
            return false;
        if (state != State::read_frame) return true;
        const uint32_t n = frame.blocksize - order;
        const int32_t *r = residual.data();
        if (bps <= 32) {
            int32_t *d = output[channel].data();
            for (uint32_t i = 0; i < order; i++)
                d[i] = static_cast<int32_t>(static_cast<uint32_t>(warmup[i]));
            d += order;
            int32_t abs_sum = 0;
            for (uint32_t j = 0; j < order; j++)
                abs_sum += qlp_coeff[j] < 0 ? -qlp_coeff[j] : qlp_coeff[j];
            if (abs_sum == 0) abs_sum = 1;
            const int32_t before_shift = static_cast<int32_t>(bps + silog2(abs_sum));
            const int32_t sum_bps = before_shift - shift;
            const int32_t max_residual_bps =
                static_cast<int32_t>(bps) > sum_bps ? static_cast<int32_t>(bps) + 1
                                                    : sum_bps + 1;
            if (max_residual_bps <= 32 && before_shift <= 32) {
                // FLAC__lpc_restore_signal: 32-bit sums (which cannot
                // overflow unless the warm-up samples are damaged; they
                // wrap then)
                for (uint32_t i = 0; i < n; i++) {
                    uint32_t sum = 0;
                    for (uint32_t j = 0; j < order; j++)
                        sum += static_cast<uint32_t>(qlp_coeff[j]) *
                               static_cast<uint32_t>(d[int64_t(i) - 1 - j]);
                    d[i] = static_cast<int32_t>(
                        static_cast<uint32_t>(r[i]) +
                        static_cast<uint32_t>(static_cast<int32_t>(sum) >> shift));
                }
            } else {
                // FLAC__lpc_restore_signal_wide: 64-bit sums (exact), the
                // result truncated to 32 bits
                for (uint32_t i = 0; i < n; i++) {
                    int64_t sum = 0;
                    for (uint32_t j = 0; j < order; j++)
                        sum += int64_t(qlp_coeff[j]) * d[int64_t(i) - 1 - j];
                    d[i] = static_cast<int32_t>(
                        static_cast<uint32_t>(r[i]) +
                        static_cast<uint32_t>(sum >> shift));
                }
            }
        } else {
            // FLAC__lpc_restore_signal_wide_33bit (the sums wrap on damaged
            // data)
            side_subframe_in_use = true;
            int64_t *d = side_subframe.data();
            for (uint32_t i = 0; i < order; i++) d[i] = warmup[i];
            d += order;
            for (uint32_t i = 0; i < n; i++) {
                uint64_t sum = 0;
                for (uint32_t j = 0; j < order; j++)
                    sum += static_cast<uint64_t>(int64_t(qlp_coeff[j])) *
                           static_cast<uint64_t>(d[int64_t(i) - 1 - j]);
                d[i] = static_cast<int64_t>(
                    static_cast<uint64_t>(int64_t(r[i])) +
                    static_cast<uint64_t>(static_cast<int64_t>(sum) >> shift));
            }
        }
        return true;
    }

    bool read_subframe(uint32_t channel, uint32_t bps)
    {
        uint32_t x;
        if (!read_raw_uint32(x, 8)) return false;
        const bool wasted = x & 1;
        x &= 0xFE;
        if (wasted) {
            uint32_t u;
            if (!read_unary_unsigned(u)) return false;
            wasted_bits[channel] = u + 1;
            if (wasted_bits[channel] >= bps)
                return sync_error(ErrorStatus::lost_sync);
            bps -= wasted_bits[channel];
        } else
            wasted_bits[channel] = 0;

        if (x & 0x80)
            return sync_error(ErrorStatus::lost_sync);
        else if (x == 0) {
            if (!read_subframe_constant(channel, bps)) return false;
        } else if (x == 2) {
            if (!read_subframe_verbatim(channel, bps)) return false;
        } else if (x < 16)
            return sync_error(ErrorStatus::unparseable_stream);
        else if (x <= 24) {
            uint32_t order = (x >> 1) & 7;
            if (frame.blocksize <= order)
                return sync_error(ErrorStatus::lost_sync);
            if (!read_subframe_fixed(channel, bps, order)) return false;
            if (state == State::search_for_frame_sync) return true;
        } else if (x < 64)
            return sync_error(ErrorStatus::unparseable_stream);
        else {
            uint32_t order = ((x >> 1) & 31) + 1;
            if (frame.blocksize <= order)
                return sync_error(ErrorStatus::lost_sync);
            if (!read_subframe_lpc(channel, bps, order)) return false;
            if (state == State::search_for_frame_sync) return true;
        }

        if (wasted) {
            x = wasted_bits[channel];
            if (bps + x < 33) {
                uint32_t *d = reinterpret_cast<uint32_t *>(output[channel].data());
                for (uint32_t i = 0; i < frame.blocksize; i++) d[i] <<= x;
            } else {
                side_subframe_in_use = true;
                for (uint32_t i = 0; i < frame.blocksize; i++)
                    side_subframe[i] = static_cast<int64_t>(
                        static_cast<uint64_t>(int64_t(output[channel][i])) << x);
            }
        }
        return true;
    }

    bool read_zero_padding()
    {
        if (!byte_aligned()) {
            uint32_t zero = 0;
            if (!read_raw_uint32(zero, bits_left_for_byte_alignment()))
                return false;
            if (zero != 0) sync_error(ErrorStatus::lost_sync);
        }
        return true;
    }

    void undo_channel_coding()
    {
        uint32_t *o0 = reinterpret_cast<uint32_t *>(output[0].data());
        uint32_t *o1 = reinterpret_cast<uint32_t *>(output[1].data());
        const uint32_t n = frame.blocksize;
        switch (frame.channel_assignment) {
        case CA_LEFT_SIDE:
            for (uint32_t i = 0; i < n; i++)
                o1[i] = side_subframe_in_use
                            ? o0[i] - static_cast<uint32_t>(side_subframe[i])
                            : o0[i] - o1[i];
            break;
        case CA_RIGHT_SIDE:
            for (uint32_t i = 0; i < n; i++)
                o0[i] = side_subframe_in_use
                            ? o1[i] + static_cast<uint32_t>(side_subframe[i])
                            : o0[i] + o1[i];
            break;
        case CA_MID_SIDE:
            for (uint32_t i = 0; i < n; i++) {
                if (!side_subframe_in_use) {
                    int32_t side = static_cast<int32_t>(o1[i]);
                    int32_t mid = static_cast<int32_t>((o0[i] << 1) |
                                                       (o1[i] & 1));
                    o0[i] = static_cast<uint32_t>(static_cast<int32_t>(
                                static_cast<uint32_t>(mid) +
                                static_cast<uint32_t>(side)) >> 1);
                    o1[i] = static_cast<uint32_t>(static_cast<int32_t>(
                                static_cast<uint32_t>(mid) -
                                static_cast<uint32_t>(side)) >> 1);
                } else {
                    uint64_t s = static_cast<uint64_t>(side_subframe[i]);
                    int64_t mid = static_cast<int64_t>(
                        (static_cast<uint64_t>(int64_t(static_cast<int32_t>(o0[i]))) << 1) |
                        (s & 1));
                    o0[i] = static_cast<uint32_t>(
                        static_cast<int64_t>(static_cast<uint64_t>(mid) + s) >> 1);
                    o1[i] = static_cast<uint32_t>(
                        static_cast<int64_t>(static_cast<uint64_t>(mid) - s) >> 1);
                }
            }
            break;
        default:
            break;
        }
    }

    void md5_accumulate(const FrameHeader &h, const int32_t *const buf[])
    {
        const uint32_t nb = (h.bits_per_sample + 7) / 8;
        std::vector<unsigned char> tmp;
        tmp.reserve(static_cast<size_t>(h.blocksize) * h.channels * nb);
        for (uint32_t i = 0; i < h.blocksize; i++)
            for (uint32_t c = 0; c < h.channels; c++) {
                uint32_t v = static_cast<uint32_t>(buf[c][i]);
                for (uint32_t k = 0; k < nb; k++)
                    tmp.push_back(static_cast<unsigned char>(v >> (8 * k)));
            }
        md5.update(tmp.data(), tmp.size());
    }

    WriteStatus write_audio_frame(const FrameHeader &h,
                                  const int32_t *const buf[])
    {
        last_frame = h;
        last_frame_is_set = true;
        if (is_seeking) {
            const uint64_t this_frame_sample = h.sample_number;
            const uint64_t next_frame_sample = this_frame_sample + h.blocksize;
            if (this_frame_sample <= target_sample &&
                target_sample < next_frame_sample) {
                const uint32_t delta =
                    static_cast<uint32_t>(target_sample - this_frame_sample);
                is_seeking = false;
                if (delta > 0) {
                    const int32_t *newbuf[MAX_CHANNELS];
                    for (uint32_t c = 0; c < h.channels; c++)
                        newbuf[c] = buf[c] + delta;
                    last_frame.blocksize -= delta;
                    last_frame.sample_number += delta;
                    return client.write(last_frame, newbuf);
                }
                return client.write(h, buf);
            }
            return WriteStatus::cont;
        }
        if (!has_stream_info) do_md5_checking = false;
        if (do_md5_checking) md5_accumulate(h, buf);
        return client.write(h, buf);
    }

    bool read_frame(bool &got_a_frame)
    {
        uint32_t x = 0;
        got_a_frame = false;
        side_subframe_in_use = false;

        uint32_t frame_crc = 0;
        frame_crc = crc16_byte(header_warmup[0], frame_crc);
        frame_crc = crc16_byte(header_warmup[1], frame_crc);
        reset_read_crc16(frame_crc);

        if (!read_frame_header()) return false;
        if (state == State::search_for_frame_sync) return true;
        // allocate_output_
        for (uint32_t c = 0; c < frame.channels; c++)
            if (output[c].size() < frame.blocksize)
                output[c].resize(frame.blocksize);
        if (residual.size() < frame.blocksize) residual.resize(frame.blocksize);
        if (frame.bits_per_sample == 32 && side_subframe.size() < frame.blocksize)
            side_subframe.resize(frame.blocksize);

        for (uint32_t channel = 0; channel < frame.channels; channel++) {
            uint32_t bps = frame.bits_per_sample;
            switch (frame.channel_assignment) {
            case CA_LEFT_SIDE: if (channel == 1) bps++; break;
            case CA_RIGHT_SIDE: if (channel == 0) bps++; break;
            case CA_MID_SIDE: if (channel == 1) bps++; break;
            default: break;
            }
            if (bps == 33 && side_subframe.size() < frame.blocksize)
                side_subframe.resize(frame.blocksize);
            if (!read_subframe(channel, bps)) {
                if (state == State::end_of_stream)
                    break;
                return false;
            }
            if (state != State::read_frame) break;
        }

        if (state != State::end_of_stream && !read_zero_padding()) return false;

        if (state == State::read_frame) {
            frame_crc = get_read_crc16();
            if (!read_raw_uint32(x, FOOTER_CRC_LEN)) {
                if (state != State::end_of_stream) return false;
            }
        }
        if (state == State::read_frame && frame_crc == x) {
            undo_channel_coding();
            // Check whether the decoded data fit in bits_per_sample.
            const unsigned shift_bits = 32 - frame.bits_per_sample;
            const int32_t lo = INT32_MIN >> shift_bits, hi = INT32_MAX >> shift_bits;
            for (uint32_t c = 0; c < frame.channels; c++)
                for (uint32_t i = 0; i < frame.blocksize; i++)
                    if (output[c][i] < lo || output[c][i] > hi) {
                        sync_error(ErrorStatus::frame_crc_mismatch);
                        break;
                    }
        } else if (state == State::read_frame)
            sync_error(ErrorStatus::frame_crc_mismatch);

        // Missing frames (a gap in the sample numbers) are replaced by
        // silence.
        if (last_frame_is_set && state == State::read_frame && !is_seeking &&
            last_frame.sample_number + last_frame.blocksize < frame.sample_number) {
            uint32_t padding = static_cast<uint32_t>(
                frame.sample_number -
                (last_frame.sample_number + last_frame.blocksize));
            if (last_frame.sample_rate == frame.sample_rate &&
                last_frame.channels == frame.channels &&
                last_frame.bits_per_sample == frame.bits_per_sample &&
                last_frame.blocksize >= 16) {
                FrameHeader empty = last_frame;
                std::vector<int32_t> zeros(empty.blocksize, 0);
                const int32_t *zbuf[MAX_CHANNELS];
                for (uint32_t c = 0; c < empty.channels; c++)
                    zbuf[c] = zeros.data();
                if (padding > 5 * empty.sample_rate)
                    padding = 5 * empty.sample_rate;
                if (padding > 50 * empty.blocksize)
                    padding = 50 * empty.blocksize;
                while (padding) {
                    empty.sample_number += empty.blocksize;
                    if (padding < empty.blocksize) empty.blocksize = padding;
                    padding -= empty.blocksize;
                    samples_decoded = empty.sample_number + empty.blocksize;
                    if (write_audio_frame(empty, zbuf) != WriteStatus::cont) {
                        state = State::aborted;
                        return false;
                    }
                }
            }
        }

        if (state == State::search_for_frame_sync ||
            state == State::end_of_stream) {
            // Damaged data: go back to just after the last frame sync code.
            if (!rewind_to_after_last_seen_framesync() && last_seen_framesync) {
                if (client.seek(last_seen_framesync) == CallbackStatus::error) {
                    state = State::seek_error;
                    return false;
                }
                br_clear();
            }
        } else {
            got_a_frame = true;
            if (next_fixed_block_size) fixed_block_size = next_fixed_block_size;
            channels = frame.channels;
            bits_per_sample = frame.bits_per_sample;
            samples_decoded = frame.sample_number + frame.blocksize;
            const int32_t *buf[MAX_CHANNELS];
            for (uint32_t c = 0; c < frame.channels; c++)
                buf[c] = output[c].data();
            if (write_audio_frame(frame, buf) != WriteStatus::cont) {
                state = State::aborted;
                return false;
            }
        }
        state = State::search_for_frame_sync;
        return true;
    }

    bool process_single()
    {
        bool got_a_frame;
        for (;;) {
            switch (state) {
            case State::search_for_metadata:
                if (!find_metadata()) return false;
                break;
            case State::read_metadata:
                return read_metadata();
            case State::search_for_frame_sync:
                if (!frame_sync()) return true;
                break;
            case State::read_frame:
                if (!read_frame(got_a_frame)) return false;
                if (got_a_frame) return true;
                break;
            case State::end_of_stream:
            case State::aborted:
                return true;
            default:
                return false;
            }
        }
    }

    bool process_until_end_of_metadata()
    {
        for (;;) {
            switch (state) {
            case State::search_for_metadata:
                if (!find_metadata()) return false;
                break;
            case State::read_metadata:
                if (!read_metadata()) return false;
                break;
            case State::search_for_frame_sync:
            case State::read_frame:
            case State::end_of_stream:
            case State::aborted:
                return true;
            default:
                return false;
            }
        }
    }

    bool seek_absolute(uint64_t sample)
    {
        uint64_t length;
        if (state != State::search_for_metadata &&
            state != State::read_metadata &&
            state != State::search_for_frame_sync &&
            state != State::read_frame && state != State::end_of_stream)
            return false;
        if (total_samples() > 0 && sample >= total_samples()) return false;
        is_seeking = true;
        do_md5_checking = false;
        if (client.length(&length) != CallbackStatus::ok) {
            is_seeking = false;
            return false;
        }
        if (state == State::search_for_metadata ||
            state == State::read_metadata) {
            if (!process_until_end_of_metadata()) {
                is_seeking = false;
                return false;
            }
            if (total_samples() > 0 && sample >= total_samples()) {
                is_seeking = false;
                return false;
            }
        }
        const bool ok = seek_to_absolute_sample(length, sample);
        is_seeking = false;
        return ok;
    }

    bool seek_to_absolute_sample(uint64_t stream_length, uint64_t target)
    {
        uint64_t lower_bound, upper_bound, lower_bound_sample,
            upper_bound_sample, this_frame_sample;
        int64_t pos = -1;
        uint32_t approx_bytes_per_frame;
        bool first_seek = true, seek_from_lower_bound = false;
        const uint64_t total = total_samples();
        const uint32_t min_blocksize = stream_info.min_blocksize;
        const uint32_t max_blocksize = stream_info.max_blocksize;
        const uint32_t max_framesize = stream_info.max_framesize;
        const uint32_t min_framesize = stream_info.min_framesize;
        uint32_t nch = channels, bps = bits_per_sample;
        if (nch == 0) nch = stream_info.channels;
        if (bps == 0) bps = stream_info.bits_per_sample;

        if (max_framesize > 0)
            approx_bytes_per_frame = (max_framesize + min_framesize) / 2 + 1;
        else if (min_blocksize == max_blocksize && min_blocksize > 0)
            approx_bytes_per_frame = min_blocksize * nch * bps / 8 + 64;
        else
            approx_bytes_per_frame = 4096 * nch * bps / 8 + 64;

        lower_bound = first_frame_offset;
        lower_bound_sample = 0;
        upper_bound = stream_length;
        upper_bound_sample = total > 0 ? total : target;

        if (state == State::search_for_frame_sync && samples_decoded != 0) {
            if (target < samples_decoded) {
                if (get_decode_position(upper_bound))
                    upper_bound_sample = samples_decoded;
            } else {
                if (get_decode_position(lower_bound))
                    lower_bound_sample = samples_decoded;
            }
        }

        if (has_seek_table) {
            uint64_t new_lower_bound = lower_bound, new_upper_bound = upper_bound;
            uint64_t new_lower_bound_sample = lower_bound_sample;
            uint64_t new_upper_bound_sample = upper_bound_sample;
            const int npoints = static_cast<int>(seek_table.size());
            int i;
            for (i = npoints - 1; i >= 0; i--) {
                const SeekPoint &p = seek_table[static_cast<size_t>(i)];
                if (p.sample_number != SEEKPOINT_PLACEHOLDER &&
                    p.frame_samples > 0 &&
                    (total <= 0 || p.sample_number < total) &&
                    p.sample_number <= target)
                    break;
            }
            if (i >= 0) {
                new_lower_bound = first_frame_offset +
                                  seek_table[static_cast<size_t>(i)].stream_offset;
                new_lower_bound_sample = seek_table[static_cast<size_t>(i)].sample_number;
            }
            for (i = 0; i < npoints; i++) {
                const SeekPoint &p = seek_table[static_cast<size_t>(i)];
                if (p.sample_number != SEEKPOINT_PLACEHOLDER &&
                    p.frame_samples > 0 &&
                    (total <= 0 || p.sample_number < total) &&
                    p.sample_number > target)
                    break;
            }
            if (i < npoints) {
                new_upper_bound = first_frame_offset +
                                  seek_table[static_cast<size_t>(i)].stream_offset;
                new_upper_bound_sample = seek_table[static_cast<size_t>(i)].sample_number;
            }
            if (new_upper_bound >= new_lower_bound) {
                lower_bound = new_lower_bound;
                upper_bound = new_upper_bound;
                lower_bound_sample = new_lower_bound_sample;
                upper_bound_sample = new_upper_bound_sample;
            }
        }

        if (upper_bound_sample == lower_bound_sample) upper_bound_sample++;

        target_sample = target;
        for (;;) {
            if (state == State::memory_allocation_error ||
                state == State::aborted)
                return false;
            if (lower_bound_sample >= upper_bound_sample ||
                lower_bound > upper_bound ||
                upper_bound >= static_cast<uint64_t>(INT64_MAX)) {
                state = State::seek_error;
                return false;
            }
            if (seek_from_lower_bound)
                pos = static_cast<int64_t>(lower_bound);
            else
                pos = static_cast<int64_t>(lower_bound) +
                      static_cast<int64_t>(
                          static_cast<double>(target - lower_bound_sample) /
                          static_cast<double>(upper_bound_sample - lower_bound_sample) *
                          static_cast<double>(upper_bound - lower_bound)) -
                      approx_bytes_per_frame;
            if (pos >= static_cast<int64_t>(upper_bound))
                pos = static_cast<int64_t>(upper_bound) - 1;
            if (pos < static_cast<int64_t>(lower_bound))
                pos = static_cast<int64_t>(lower_bound);
            if (client.seek(static_cast<uint64_t>(pos)) != CallbackStatus::ok) {
                state = State::seek_error;
                return false;
            }
            flush();
            unparseable_frame_count = 0;
            if (!process_single() || state == State::aborted ||
                samples_decoded == 0) {
                if (state != State::aborted && client.eof() &&
                    !seek_from_lower_bound) {
                    seek_from_lower_bound = true;
                    continue;
                }
                state = State::seek_error;
                return false;
            }
            seek_from_lower_bound = false;
            if (!is_seeking) break;

            this_frame_sample = last_frame.sample_number;
            if (this_frame_sample + last_frame.blocksize >= upper_bound_sample &&
                !first_seek) {
                if (pos == static_cast<int64_t>(lower_bound)) {
                    state = State::seek_error;
                    return false;
                }
                approx_bytes_per_frame =
                    approx_bytes_per_frame ? approx_bytes_per_frame * 2 : 16;
                continue;
            }
            first_seek = false;
            if (this_frame_sample < lower_bound_sample) {
                state = State::seek_error;
                return false;
            }
            if (target < this_frame_sample) {
                upper_bound_sample = this_frame_sample + last_frame.blocksize;
                if (!get_decode_position(upper_bound)) {
                    state = State::seek_error;
                    return false;
                }
                approx_bytes_per_frame = static_cast<uint32_t>(
                    2 * (upper_bound - static_cast<uint64_t>(pos)) / 3 + 16);
            } else {
                lower_bound_sample = this_frame_sample + last_frame.blocksize;
                if (!get_decode_position(lower_bound)) {
                    state = State::seek_error;
                    return false;
                }
                approx_bytes_per_frame = static_cast<uint32_t>(
                    2 * (lower_bound - static_cast<uint64_t>(pos)) / 3 + 16);
            }
        }
        return true;
    }
};

StreamDecoder::StreamDecoder(StreamClient &client, bool md5_checking)
    : d_(new Impl(client))
{
    d_->md5_checking = md5_checking;
    d_->cached = false;
    d_->reset();
}

StreamDecoder::~StreamDecoder() = default;

bool StreamDecoder::process_single() { return d_->process_single(); }

bool StreamDecoder::seek_absolute(uint64_t sample)
{
    return d_->seek_absolute(sample);
}

bool StreamDecoder::flush() { return d_->flush(); }

State StreamDecoder::state() const { return d_->state; }

bool StreamDecoder::finish()
{
    unsigned char computed[16];
    d_->md5.digest(computed);
    bool md5_failed = d_->do_md5_checking &&
                      std::memcmp(d_->stream_info.md5sum, computed, 16) != 0;
    d_->is_seeking = false;
    return !md5_failed;
}

// ---------------------------------------------------------------------------
// Decoding of a complete stream held in memory

namespace {

class MemoryClient : public StreamClient {
public:
    MemoryClient(const unsigned char *data, size_t n, int expect_nsig,
                 int expect_bps, Decoded &result)
        : data_(data), n_(n), expect_nsig_(expect_nsig),
          expect_bps_(expect_bps), result_(result) {}

    ReadStatus read(unsigned char *buffer, size_t *nbytes) override
    {
        size_t avail = n_ - pos_;
        size_t k = *nbytes < avail ? *nbytes : avail;
        if (*nbytes > avail) eof_ = true;   // (as fread() sets the flag)
        std::memcpy(buffer, data_ + pos_, k);
        pos_ += k;
        *nbytes = k;
        return k ? ReadStatus::cont : ReadStatus::end_of_stream;
    }
    CallbackStatus seek(uint64_t pos) override
    {
        if (pos > n_) return CallbackStatus::error;
        pos_ = static_cast<size_t>(pos);
        eof_ = false;
        return CallbackStatus::ok;
    }
    CallbackStatus tell(uint64_t *pos) override
    {
        *pos = pos_;
        return CallbackStatus::ok;
    }
    CallbackStatus length(uint64_t *len) override
    {
        *len = n_;
        return CallbackStatus::ok;
    }
    bool eof() override { return eof_; }
    WriteStatus write(const FrameHeader &h,
                      const int32_t *const buffer[]) override
    {
        if (expect_nsig_ > 0 && h.channels != static_cast<uint32_t>(expect_nsig_)) {
            wfdb_error("getvec: wrong number of signals in FLAC signal file\n");
            fail(Status::wfdb);
        }
        if (expect_nsig_ > 0 && h.bits_per_sample > static_cast<uint32_t>(expect_bps_)) {
            wfdb_error("getvec: wrong sample resolution in FLAC signal file\n");
            fail(Status::wfdb);
        }
        if (result_.status != Status::ok) return WriteStatus::abort;
        if (result_.chans.empty()) result_.chans.resize(h.channels);
        size_t m = h.channels < result_.chans.size() ? h.channels
                                                    : result_.chans.size();
        for (size_t c = 0; c < m; c++)
            result_.chans[c].insert(result_.chans[c].end(), buffer[c],
                                    buffer[c] + h.blocksize);
        return WriteStatus::cont;
    }
    void error(ErrorStatus status) override
    {
        switch (status) {
        case ErrorStatus::lost_sync: fail(Status::sync); break;
        case ErrorStatus::bad_header: fail(Status::header); break;
        case ErrorStatus::frame_crc_mismatch: fail(Status::crc); break;
        case ErrorStatus::unparseable_stream: fail(Status::unparseable); break;
        case ErrorStatus::bad_metadata: fail(Status::meta); break;
        }
    }
    void fail(Status s)
    {
        if (result_.status == Status::ok) result_.status = s;
    }

private:
    const unsigned char *data_;
    size_t n_, pos_ = 0;
    bool eof_ = false;
    int expect_nsig_, expect_bps_;
    Decoded &result_;
};

} // namespace

Decoded decode(const unsigned char *data, size_t n, int expect_nsig,
               int expect_bps)
{
    Decoded result;
    MemoryClient client(data, n, expect_nsig, expect_bps, result);
    StreamDecoder dec(client, false);
    while (result.status == Status::ok) {
        if (!dec.process_single()) {
            client.fail(Status::meta);
            break;
        }
        State st = dec.state();
        if (st == State::end_of_stream || st == State::aborted) break;
    }
    // STREAMINFO (read again: the decoder does not report it)
    if (n >= MARKER_LEN + META_HEADER_LEN + STREAMINFO_LEN &&
        std::memcmp(data, STREAM_MARKER, MARKER_LEN) == 0 &&
        (data[MARKER_LEN] & META_TYPE) == META_STREAMINFO) {
        const unsigned char *p = data + MARKER_LEN + META_HEADER_LEN;
        result.channels = ((p[12] >> 1) & 0x07) + 1;
        result.bps = (((p[12] & 1) << 4) | (p[13] >> 4)) + 1;
        result.has_md5 = true;
        std::memcpy(result.md5, p + STREAMINFO_MD5, MD5_LEN);
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
