// flac.hpp: FLAC codec used for signal formats 508, 516, and 524
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package: it is wfdb-x's own
// implementation of the FLAC format, which the original package reads and
// writes with libFLAC.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// The C library uses libFLAC; wfdb-x has its own decoder (complete) and a
// lossless encoder (fixed predictors and Rice coding).  Files written by
// the encoder are standard FLAC streams; their compressed bytes differ from
// those written by libFLAC (whose output depends on its version), but the
// decoded samples are identical.  This is a port of python/src/wfdbx/_flac.py.

#ifndef WFDBX_FLAC_HPP
#define WFDBX_FLAC_HPP

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace wfdbx {
namespace detail {
namespace flac {

constexpr int MAX_CHANNELS = 8;     // FLAC__MAX_CHANNELS
constexpr int BLOCKSIZE = 4096;     // samples per channel in each frame

// Decoding status (the libFLAC error that would have been reported)
enum class Status {
    ok,
    sync,           // lost sync
    header,         // invalid frame header
    crc,            // frame CRC mismatch
    unparseable,    // unsupported format
    eof,            // unexpected end of stream
    meta,           // error in the stream header or metadata
    wfdb            // wrong number of channels or resolution (reported)
};

struct Decoded {
    Status status = Status::ok;
    int channels = 0;           // from STREAMINFO
    int bps = 0;                // bits per sample, from STREAMINFO
    std::vector<std::vector<int32_t>> chans;    // samples, one per channel
    std::vector<long long> block_ends;  // end of each frame (FLAC block),
                                        // in samples per channel
    bool has_md5 = false;
    unsigned char md5[16] = {}; // MD5 signature from STREAMINFO
};

// Decode a complete FLAC stream.  If expect_nsig > 0, a frame with a
// different number of channels is reported with wfdb_error("getvec: wrong
// number of signals in FLAC signal file\n"), and a frame with more than
// expect_bps bits per sample with wfdb_error("getvec: wrong sample
// resolution in FLAC signal file\n"); the status is then Status::wfdb.
// Other errors are not reported (the status says what happened).  Trailing
// zero bytes after the last frame are ignored.
Decoded decode(const unsigned char *data, size_t n, int expect_nsig,
               int expect_bps);

// MD5 message digest (RFC 1321)
class MD5 {
public:
    MD5();
    void update(const void *data, size_t n);
    void digest(unsigned char out[16]);     // finishes the computation
private:
    void transform(const unsigned char block[64]);
    uint32_t a_, b_, c_, d_;
    uint64_t length_;
    unsigned char buffer_[64];
    size_t buffered_;
};

// The MD5 signature of decoded samples, as computed by libFLAC: the
// samples interleaved, each stored in (bps+7)/8 little-endian bytes.
void samples_md5(const std::vector<std::vector<int32_t>> &chans, int bps,
                 unsigned char out[16]);

// Encoder for a signal group of nsig signals with spf samples per frame and
// bps (8, 16, or 24) bits per sample.
class Encoder {
public:
    Encoder(int nsig, int bps, int spf);
    // The stream header: "fLaC", a STREAMINFO block with an unknown total
    // number of samples, and a VORBIS_COMMENT block (vendor "wfdb-x
    // <version>").  The final STREAMINFO is written later at offset 8.
    std::string header();
    // Append one sample (in WFDB frame order: spf samples of signal 0, then
    // spf samples of signal 1, ...), wrapped to bps bits.  Encoded frames,
    // if any, are appended to `out`.
    void put(int v, std::string &out);
    // Encode the remaining samples (appended to `out`).
    void finish(std::string &out);
    // The final 34-byte STREAMINFO block body (after finish()).
    std::string streaminfo();
private:
    void write_block(int n, std::string &out);
    int nsig_, bps_, spf_;
    std::vector<std::vector<int32_t>> chans_;
    std::vector<int32_t> pending_;
    uint64_t frame_no_ = 0, total_ = 0;
    uint32_t minfs_ = 0, maxfs_ = 0;
    bool have_minfs_ = false;
    MD5 md5_;
};

} // namespace flac
} // namespace detail
} // namespace wfdbx

#endif // WFDBX_FLAC_HPP
