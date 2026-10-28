// flac.hpp: FLAC codec used for signal formats 508, 516, and 524
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
// parts of this file translated from it (the declarations of the stream
// decoder):
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
// The C library uses libFLAC; WFDB-x has a decoder translated from libFLAC
// (complete: a port of the parts of libFLAC that the C library uses) and its
// own lossless encoder
// (fixed predictors and Rice coding, a port of python/src/wfdbx/_flac.py).
// Files written by the encoder are standard FLAC streams; their compressed
// bytes differ from those written by libFLAC (whose output depends on its
// version), but the decoded samples are identical.

#ifndef WFDBX_FLAC_HPP
#define WFDBX_FLAC_HPP

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace wfdbx {
namespace detail {
namespace flac {

constexpr int MAX_CHANNELS = 8;     // FLAC__MAX_CHANNELS
constexpr int BLOCKSIZE = 4096;     // samples per channel in each frame

// ---------------------------------------------------------------------------
// Stream decoder: a port of the parts of libFLAC 1.4.3 (stream_decoder.c and
// bitreader.c) that the C library uses.  Like libFLAC, it reads the stream
// through callbacks, decodes one frame at a time, reports damaged data to
// the error callback and resynchronizes on the next frame, and seeks by
// bisection.  Its decoded samples, its calls of the callbacks and its states
// are those of libFLAC, so that the C library's FLAC glue (signal.c) can be
// ported line by line on top of it.

enum class State {          // FLAC__StreamDecoderState
    search_for_metadata,
    read_metadata,
    search_for_frame_sync,
    read_frame,
    end_of_stream,
    seek_error,
    aborted,
    memory_allocation_error
};

enum class ErrorStatus {    // FLAC__StreamDecoderErrorStatus
    lost_sync,
    bad_header,
    frame_crc_mismatch,
    unparseable_stream,
    bad_metadata
};

enum class ReadStatus { cont, end_of_stream, abort };
enum class CallbackStatus { ok, error, unsupported };  // seek, tell, length
enum class WriteStatus { cont, abort };

struct FrameHeader {
    uint32_t blocksize = 0;     // samples per channel
    uint32_t sample_rate = 0;
    uint32_t channels = 0;
    uint32_t bits_per_sample = 0;
    int channel_assignment = 0; // 0: independent, 1: left/side,
                                // 2: right/side, 3: mid/side
    uint64_t sample_number = 0;
};

// The callbacks of FLAC__stream_decoder_init_stream
class StreamClient {
public:
    virtual ~StreamClient() = default;
    virtual ReadStatus read(unsigned char *buffer, size_t *bytes) = 0;
    virtual CallbackStatus seek(uint64_t pos) = 0;
    virtual CallbackStatus tell(uint64_t *pos) = 0;
    virtual CallbackStatus length(uint64_t *len) = 0;
    virtual bool eof() = 0;
    // A decoded block: buffer[c] holds header.blocksize samples of
    // channel c.
    virtual WriteStatus write(const FrameHeader &header,
                              const int32_t *const buffer[]) = 0;
    virtual void error(ErrorStatus status) = 0;
};

class StreamDecoder {
public:
    // FLAC__stream_decoder_new, FLAC__stream_decoder_set_md5_checking and
    // FLAC__stream_decoder_init_stream (no metadata callback).
    StreamDecoder(StreamClient &client, bool md5_checking);
    ~StreamDecoder();
    StreamDecoder(const StreamDecoder &) = delete;
    StreamDecoder &operator=(const StreamDecoder &) = delete;
    bool process_single();
    bool seek_absolute(uint64_t sample);
    bool flush();
    // FLAC__stream_decoder_finish: false if MD5 checking was on (and not
    // turned off by a seek) and the signature does not match.
    bool finish();
    State state() const;
private:
    struct Impl;
    std::unique_ptr<Impl> d_;
};

// ---------------------------------------------------------------------------
// Decoding of a complete stream held in memory (a convenience for tests)

// The first error found (the error that libFLAC reports first)
enum class Status {
    ok,
    sync,           // lost sync
    header,         // invalid frame header
    crc,            // frame CRC mismatch
    unparseable,    // unsupported format
    meta,           // error in the stream header or metadata
    wfdb            // wrong number of channels or resolution (reported)
};

struct Decoded {
    Status status = Status::ok;
    int channels = 0;           // from STREAMINFO
    int bps = 0;                // bits per sample, from STREAMINFO
    std::vector<std::vector<int32_t>> chans;    // samples, one per channel
    bool has_md5 = false;
    unsigned char md5[16] = {}; // MD5 signature from STREAMINFO
};

// Decode a FLAC stream with StreamDecoder, up to its end or its first error.
// chans holds the samples of the frames decoded before the first error (as
// many channels as the first frame has).  If expect_nsig > 0, a frame with a
// different number of channels is reported with wfdb_error("getvec: wrong
// number of signals in FLAC signal file\n"), and a frame with more than
// expect_bps bits per sample with wfdb_error("getvec: wrong sample
// resolution in FLAC signal file\n"); the status is then Status::wfdb.
// Other errors are not reported (the status says what happened).
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
    // number of samples, and a VORBIS_COMMENT block (vendor "WFDB-x
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
