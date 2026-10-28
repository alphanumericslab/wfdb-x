# flac.jl: FLAC decoder and encoder for the FLAC signal formats 508, 516 and
# 524 (a translation of rust/src/flac.rs, itself a translation of
# cpp/src/flac.cpp and python/src/wfdbx/_flac.py).
#
# The C library uses libFLAC for these formats; WFDB-x implements, without
# external libraries, a complete FLAC decoder (all subframe types, fixed and
# LPC predictors, Rice and Rice2 partitions with escape codes, wasted bits,
# stereo decorrelation, variable block sizes, CRC verification; it follows
# libFLAC's stream decoder step by step, including its recovery from damaged
# frames and its seeking) and a lossless encoder (fixed predictors and Rice coding). The encoder writes
# exactly the bytes written by the Python, C++ and Rust implementations of
# WFDB-x (standard FLAC streams; their compressed bytes differ from those
# written by libFLAC, whose output depends on its version, but the decoded
# samples are identical).
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# Its FLAC decoder is a Julia translation of the stream decoder of libFLAC
# 1.4.3 (src/libFLAC/stream_decoder.c and bitreader.c, and the restore
# functions of fixed.c and lpc.c), made so that damaged files are decoded,
# resynchronized and reported exactly as by the C library, which uses
# libFLAC. Its FLAC encoder is WFDB-x's own implementation of the FLAC format;
# it has no counterpart in the original package. WFDB-x needs no external
# library at run time.
#
# Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# libFLAC is distributed under the following license, which applies to the
# parts of this file translated from it (the stream decoder):
#
# Copyright (C) 2000-2009  Josh Coalson
# Copyright (C) 2011-2023  Xiph.Org Foundation
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# - Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
#
# - Redistributions in binary form must reproduce the above copyright
# notice, this list of conditions and the following disclaimer in the
# documentation and/or other materials provided with the distribution.
#
# - Neither the name of the Xiph.org Foundation nor the names of its
# contributors may be used to endorse or promote products derived from
# this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

"`FLAC__MAX_CHANNELS`: the largest number of channels of a FLAC stream."
const FLAC_MAX_CHANNELS = 8
"Samples per channel in each frame written by the encoder."
const FLAC_BLOCKSIZE = 4096

# Vendor string of the VORBIS_COMMENT block written by the encoder.
const _FLAC_VENDOR = b"wfdb-x"
# Length of the body of a STREAMINFO metadata block.
const _FLAC_STREAMINFO_LEN = 34
# Metadata block types and flags, and the length of a seek point.
const _FLAC_META_STREAMINFO = 0x00
const _FLAC_META_APPLICATION = 0x02
const _FLAC_META_SEEKTABLE = 0x03
const _FLAC_META_VORBIS_COMMENT = 0x04
const _FLAC_META_LAST = 0x80
const _FLAC_SEEKPOINT_LEN = 18
# Frame sync code (14 bits, then a reserved 0 bit), as the first 15 bits of
# a frame header.
const _FLAC_SYNC15 = 0xfff8 >> 1
# Sample rate code written in frame headers (96 kHz), and the sample rate
# written in STREAMINFO.
const _FLAC_RATE_CODE_96K = 11
const _FLAC_SAMPLE_RATE = 96000
# Block size codes: 8-bit or 16-bit size (minus 1) at the end of the header,
# and 4096 samples.
const _FLAC_BSC_8BIT = 6
const _FLAC_BSC_16BIT = 7
const _FLAC_BSC_4096 = 12
# Residual coding parameters: escape codes (Rice and Rice2 methods).
const _FLAC_RICE_ESCAPE = 15
const _FLAC_RICE2_ESCAPE = 31
# Largest Rice parameter chosen by the encoder.
const _FLAC_MAX_RICE_PARAM = 30
# Largest partition order tried by the encoder.
const _FLAC_MAX_PARTITION_ORDER = 6
# Largest fixed predictor order.
const _FLAC_MAX_FIXED_ORDER = 4
# Subframe types: constant, verbatim, fixed (8 + order), LPC (32 + order - 1).
const _FLAC_SUBFRAME_CONSTANT = 0
const _FLAC_SUBFRAME_VERBATIM = 1
const _FLAC_SUBFRAME_FIXED = 8
const _FLAC_SUBFRAME_LPC = 32
# Channel assignments (independent channels: 0..7).
const _FLAC_LEFT_SIDE = 8
const _FLAC_RIGHT_SIDE = 9
const _FLAC_MID_SIDE = 10
# Sample sizes given by the sample size codes of a frame header (0: from
# STREAMINFO; code 3 is reserved).
const _FLAC_BPS_TABLE = (0, 8, 12, 0, 16, 20, 24, 32)
# Unknown total number of samples in a provisional STREAMINFO (36 bits).
const _FLAC_UNKNOWN_TOTAL = (UInt64(1) << 36) - 1
# Size of the buffer of interleaved samples given to MD5 at a time.
const _FLAC_MD5_CHUNK = 65536

"""
    FlacStatus

Decoding status (the libFLAC error that the C library would report):
`FLAC_OK`, `FLAC_SYNC` (lost sync), `FLAC_HEADER` (invalid frame header),
`FLAC_CRC` (frame CRC mismatch), `FLAC_UNPARSEABLE` (unsupported stream),
`FLAC_META` (bad stream header or metadata), `FLAC_WFDB` (wrong number of
channels or resolution).
"""
@enum FlacStatus begin
    FLAC_OK             # no error
    FLAC_SYNC           # lost sync
    FLAC_HEADER         # invalid frame header
    FLAC_CRC            # frame CRC mismatch
    FLAC_UNPARSEABLE    # unsupported format
    FLAC_META           # error in the stream header or metadata
    FLAC_WFDB           # wrong number of channels or resolution (see error_message)
end
for _s in instances(FlacStatus)
    @eval @doc "A decoding status (see [`FlacStatus`](@ref))." $(Symbol(_s))
end

"""
    FlacDecoded

The result of [`flac_decode`](@ref): `status`, `channels` and `bps` (from
STREAMINFO), `chans` (the samples, one vector per channel; empty on error),
`has_md5` (is there a STREAMINFO block?), `md5` (its 16-byte MD5 signature),
`error_message` (with status `FLAC_WFDB`: the message that the C library
reports with `wfdb_error`; the caller prints it).
"""
mutable struct FlacDecoded
    status::FlacStatus
    channels::Int32
    bps::Int32
    chans::Vector{Vector{Int32}}
    has_md5::Bool
    md5::Vector{UInt8}
    error_message::Union{Nothing,Vector{UInt8}}
end
FlacDecoded() = FlacDecoded(FLAC_OK, 0, 0, Vector{Int32}[], false, zeros(UInt8, _MD5_LEN), nothing)

# ---------------------------------------------------------------------------
# CRC tables

# (One entry per byte value.)
function _make_crc8()
    t = zeros(UInt8, 256)
    for i in 0:255
        c = UInt8(i)
        for _ in 1:8
            c = (c & 0x80) != 0 ? (c << 1) ⊻ 0x07 : c << 1
        end
        t[i+1] = c
    end
    t
end

function _make_crc16()
    t = zeros(UInt16, 256)
    for i in 0:255
        c = UInt16(i) << 8
        for _ in 1:8
            c = (c & 0x8000) != 0 ? (c << 1) ⊻ 0x8005 : c << 1
        end
        t[i+1] = c
    end
    t
end

const _CRC8 = _make_crc8()
const _CRC16 = _make_crc16()

# CRC-8 (polynomial 0x07) of d[a:b].
function _crc8(d::AbstractVector{UInt8}, a::Int, b::Int)
    c = 0x00
    @inbounds for i in a:b
        c = _CRC8[(c ⊻ d[i])+1]
    end
    c
end

# CRC-16 (polynomial 0x8005) of d[a:b].
function _crc16(d::AbstractVector{UInt8}, a::Int, b::Int)
    c = 0x0000
    @inbounds for i in a:b
        c = (c << 8) ⊻ _CRC16[((c >> 8) ⊻ d[i])+1]
    end
    c
end

_bit_length(x::UInt64) = 64 - leading_zeros(x)

# ---------------------------------------------------------------------------
# MD5 (RFC 1321)

const _MD5_K = UInt32[
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391]

const _MD5_S = UInt32[
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9,
    14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15,
    21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]

const _MD5_BLOCK = 64       # bytes per MD5 block
const _MD5_WORDS = 16       # 32-bit words per MD5 block
const _MD5_LENPOS = 56      # position of the length in the last block
const _MD5_LEN = 16         # bytes of an MD5 digest

"MD5 message digest (RFC 1321)."
mutable struct Md5
    a::UInt32
    b::UInt32
    c::UInt32
    d::UInt32
    length::UInt64
    buffer::Vector{UInt8}
    buffered::Int
    m::Vector{UInt32}
end
Md5() = Md5(0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0, zeros(UInt8, _MD5_BLOCK), 0,
            zeros(UInt32, _MD5_WORDS))
Base.copy(x::Md5) = Md5(x.a, x.b, x.c, x.d, x.length, copy(x.buffer), x.buffered, zeros(UInt32, _MD5_WORDS))

# Process one 64-byte block (d[p+1:p+64]).
function _md5_transform!(md::Md5, d::AbstractVector{UInt8}, p::Int)
    m = md.m
    @inbounds for i in 0:15
        q = p + 4i
        m[i+1] = UInt32(d[q+1]) | (UInt32(d[q+2]) << 8) | (UInt32(d[q+3]) << 16) |
                 (UInt32(d[q+4]) << 24)
    end
    a, b, c, dd = md.a, md.b, md.c, md.d
    @inbounds for i in 0:63
        if i < 16
            f, g = (b & c) | (~b & dd), i
        elseif i < 32
            f, g = (dd & b) | (~dd & c), (5i + 1) & 15
        elseif i < 48
            f, g = b ⊻ c ⊻ dd, (3i + 5) & 15
        else
            f, g = c ⊻ (b | ~dd), (7i) & 15
        end
        f = f + a + _MD5_K[i+1] + m[g+1]
        a = dd
        dd = c
        c = b
        b = b + bitrotate(f, _MD5_S[i+1])
    end
    md.a += a
    md.b += b
    md.c += c
    md.d += dd
    nothing
end

"Add data to an MD5 computation."
function md5_update!(md::Md5, data::AbstractVector{UInt8})
    n = length(data)
    md.length += n
    p = 0
    if md.buffered > 0
        k = min(_MD5_BLOCK - md.buffered, n)
        copyto!(md.buffer, md.buffered + 1, data, 1, k)
        md.buffered += k
        p = k
        md.buffered < _MD5_BLOCK && return md
        _md5_transform!(md, md.buffer, 0)
        md.buffered = 0
    end
    while n - p >= _MD5_BLOCK
        _md5_transform!(md, data, p)
        p += _MD5_BLOCK
    end
    if p < n
        copyto!(md.buffer, 1, data, p + 1, n - p)
        md.buffered = n - p
    end
    md
end

"Finish an MD5 computation and return the 16-byte digest."
function md5_digest!(md::Md5)
    bits = md.length * 8
    pad = zeros(UInt8, _MD5_BLOCK + 8)
    pad[1] = 0x80
    padlen = md.buffered < _MD5_LENPOS ? _MD5_LENPOS - md.buffered :
             _MD5_BLOCK + _MD5_LENPOS - md.buffered
    md5_update!(md, view(pad, 1:padlen))
    md5_update!(md, UInt8[(bits >> (8k)) % UInt8 for k in 0:7])
    out = Vector{UInt8}(undef, _MD5_LEN)
    for (i, v) in enumerate((md.a, md.b, md.c, md.d))
        for k in 0:3
            out[4(i-1)+k+1] = (v >> (8k)) % UInt8
        end
    end
    out
end

# Append the samples i of each channel, interleaved, each in nb
# little-endian bytes (the data whose MD5 signature libFLAC computes).
@inline function _put_le!(buf::Vector{UInt8}, v::Int32, nb::Int)
    u = v % UInt32
    for k in 0:nb-1
        push!(buf, (u >> (8k)) % UInt8)
    end
end

"""
    flac_samples_md5(chans, bps) -> Vector{UInt8}

The MD5 signature of decoded samples, as computed by libFLAC: the samples
interleaved, each stored in `(bps+7)/8` little-endian bytes.
"""
function flac_samples_md5(chans::AbstractVector{<:AbstractVector{Int32}}, bps::Integer)
    md = Md5()
    nb = (Int(bps) + 7) ÷ 8
    n = isempty(chans) ? 0 : length(chans[1])
    buf = UInt8[]
    sizehint!(buf, _FLAC_MD5_CHUNK + nb * length(chans))
    for i in 1:n
        for c in chans
            _put_le!(buf, c[i], nb)
        end
        if length(buf) >= _FLAC_MD5_CHUNK
            md5_update!(md, buf)
            empty!(buf)
        end
    end
    md5_update!(md, buf)
    md5_digest!(md)
end

# ---------------------------------------------------------------------------
# Decoder
#
# The decoder follows libFLAC's stream decoder (version 1.4.3) step by step,
# as python/src/wfdbx/_flac.py does: its states, its search for frame sync
# codes, its error statuses and the point at which it reports each one, its
# recovery after a damaged frame, and its binary search when seeking. The C
# library's results on damaged files depend on all of these. libFLAC reads
# its input through a buffer of _FLAC_CAPACITY bytes; the buffer is modelled
# as far as its contents affect the results (the end-of-file flag, and the
# return to the last frame sync code after a damaged frame).

# Decoder states (FLAC__StreamDecoderState)
const _FS_SEARCH_FOR_METADATA = 0
const _FS_READ_METADATA = 1
const _FS_SEARCH_FOR_FRAME_SYNC = 2
const _FS_READ_FRAME = 3
const _FS_END_OF_STREAM = 4
const _FS_ABORTED = 5
const _FS_SEEK_ERROR = 6
const _FS_MEMORY_ALLOCATION_ERROR = 7

const _FLAC_CAPACITY = 8192     # bytes in the input buffer of libFLAC's bit reader

# The bit reader could not get the bits it needs; the decoder state says why
# (as libFLAC's read callback leaves it).
struct _FlacNoInput <: Exception end

# Sample rates given by the sample rate codes 1 to 11 of a frame header, and
# (sample sizes: _FLAC_BPS_TABLE).
const _FLAC_RATE_TABLE = (88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000,
                          44100, 48000, 96000)

# Block sizes given by the block size codes 1 to 5 and 8 to 15 of a frame
# header.
function _block_size_code(bsc::Int)
    bsc == 1 && return 192
    bsc == 2 && return 576
    bsc == 3 && return 1152
    bsc == 4 && return 2304
    bsc == 5 && return 4608
    256 << (bsc - 8)                # 8 .. 15
end

_wrap32(x::Int64) = Int64(x % Int32)

"""
    FlacDecoder

libFLAC's stream decoder, reading the bytes `data`. `on_error(status)` is
called for each error that libFLAC reports to its error callback (status
`FLAC_SYNC`, `FLAC_HEADER`, `FLAC_CRC` or `FLAC_UNPARSEABLE`);
`on_write(chans)` is called for each block of decoded samples (one vector
per channel), and returns false to abort decoding.
"""
mutable struct FlacDecoder
    data::Vector{UInt8}
    nbytes::Int
    seekable::Bool
    on_error::Function
    on_write::Function
    # Bit reader: the buffer holds bytes bstart to bend - 1 of the file (bend
    # is the file position), and pos is the position (in bits) of the next
    # bit to be read; endb = 8 bend. fsloc is the location of the last frame
    # sync code seen, while it remains in the buffer (-1: none).
    bstart::Int
    bend::Int
    endb::Int
    pos::Int
    fsloc::Int
    feof::Bool
    state::Int
    cached::Int             # a byte read ahead while looking for sync (-1: none)
    warmup::Int             # the second byte of the frame sync code
    has_stream_info::Bool
    min_blocksize::Int
    max_blocksize::Int
    min_framesize::Int
    max_framesize::Int
    si_rate::Int
    si_channels::Int
    si_bps::Int
    total_samples::Int64
    si_md5::Vector{UInt8}
    seek_table::Union{Nothing,Vector{NTuple{3,UInt64}}}
    fixed_block_size::Int
    next_fixed_block_size::Int
    samples_decoded::Int64
    last_seen_framesync::Int
    # the last frame passed to on_write: sample number, block size, sample
    # rate, channels, bits per sample (has_last_frame: is there one?)
    has_last_frame::Bool
    lf_sample::Int64
    lf_bs::Int
    lf_rate::Int
    lf_ch::Int
    lf_bps::Int
    channels::Int           # of the last frame decoded
    bps::Int
    is_seeking::Bool
    target_sample::Int64
    unparseable_frame_count::Int
    first_frame_offset::Int
    do_md5_checking::Bool
    md5::Md5
    # the frame header being decoded
    f_blocksize::Int
    f_rate::Int
    f_channels::Int
    f_assign::Int
    f_bps::Int
    f_sample::Int64
end

function FlacDecoder(data::Vector{UInt8}, seekable::Bool, on_error::Function,
                     on_write::Function, md5_checking::Bool)
    FlacDecoder(data, length(data), seekable, on_error, on_write,
                0, 0, 0, 0, -1, false, _FS_SEARCH_FOR_METADATA, -1, 0,
                false, 0, 0, 0, 0, 0, 0, 0, 0, zeros(UInt8, _MD5_LEN), nothing,
                0, 0, 0, 0, false, 0, 0, 0, 0, 0, 0, 0, false, 0, 0, 0,
                md5_checking, Md5(), 0, 0, 0, 0, 0, 0)
end

# -- bit reader --------------------------------------------------------------

# Read more input into the buffer (bitreader_read_from_client_, read_callback_
# and the C library's iflac_read).
function _fill!(d::FlacDecoder)
    consumed = (d.pos - d.bstart * 8) >> 6      # whole 8-byte words
    if consumed > 0
        d.fsloc = -1
        d.bstart += consumed * 8
    end
    request = _FLAC_CAPACITY - (d.bend - d.bstart)
    request <= 0 && throw(_FlacNoInput())
    if d.feof
        d.state = _FS_END_OF_STREAM
        throw(_FlacNoInput())
    end
    if d.is_seeking && d.unparseable_frame_count > 20
        d.state = _FS_ABORTED
        throw(_FlacNoInput())
    end
    got = min(request, d.nbytes - d.bend)
    got < request && (d.feof = true)
    if got <= 0
        d.state = _FS_END_OF_STREAM
        throw(_FlacNoInput())
    end
    d.bend += got
    d.endb = d.bend * 8
    nothing
end

# 8 bytes starting at (0-based) byte b, big-endian, zero-padded beyond the end.
@inline function _load(data::Vector{UInt8}, b::Int)
    if b + 8 <= length(data)
        w = UInt64(0)
        @inbounds for i in 1:8
            w = (w << 8) | data[b+i]
        end
        return w
    end
    w = UInt64(0)
    for i in 1:8
        w = (w << 8) | (b + i <= length(data) ? UInt64(data[b+i]) : UInt64(0))
    end
    w
end

# Read n bits (0 <= n <= 57) as an unsigned value.
@inline function _rd(d::FlacDecoder, n::Int)
    e = d.pos + n
    while e > d.endb
        _fill!(d)
    end
    n == 0 && return UInt64(0)
    w = _load(d.data, d.pos >> 3) << (d.pos & 7)
    d.pos = e
    w >> (64 - n)
end

# Read n bits (0 <= n <= 64) as an unsigned value.
function _rd_long(d::FlacDecoder, n::Int)
    n <= 32 && return _rd(d, n)
    hi = _rd(d, n - 32)
    (hi << 32) | _rd(d, 32)
end

# Read n bits (1 <= n <= 33) as a signed value.
@inline function _rd_signed(d::FlacDecoder, n::Int)
    v = _rd(d, n)
    (v >> (n - 1)) != 0 ? (v % Int64) - (Int64(1) << n) : v % Int64
end

# Count zero bits up to (and consume) the next one bit.
function _unary!(d::FlacDecoder)
    data = d.data
    p = d.pos
    n = 0
    while true
        eb = d.endb >> 3
        bi = p >> 3
        if bi < eb
            byte = (@inbounds(data[bi+1]) << (p & 7)) % UInt8
            if byte != 0
                z = leading_zeros(byte)
                d.pos = p + z + 1
                return n + z
            end
            n += 8 - (p & 7)
            bi += 1
            while bi < eb && @inbounds(data[bi+1]) == 0
                bi += 1
            end
            n += (bi - (p >> 3) - 1) * 8
            p = bi << 3
            bi < eb && continue
        end
        d.pos = p
        _fill!(d)
    end
end

function _skip_bytes!(d::FlacDecoder, n::Int)
    target = d.pos + 8 * n
    while true
        d.pos = min(target, d.endb)
        d.pos >= target && return nothing
        _fill!(d)
    end
end

# Empty the buffer (FLAC__bitreader_clear).
function _clear!(d::FlacDecoder)
    d.bstart = d.bend
    d.pos = d.endb = d.bend * 8
    d.fsloc = -1
    nothing
end

# Move the file position (the C library's iflac_seek).
function _seek_file!(d::FlacDecoder, pos::Int)
    d.seekable || return false
    d.bend = pos
    d.endb = pos * 8
    d.feof = false
    true
end

# FLAC__stream_decoder_get_decode_position: the position in the file of the
# next byte to be decoded (-1 if it is not known).
_decode_position(d::FlacDecoder) = (!d.seekable || (d.pos & 7) != 0) ? -1 : d.pos >> 3

# send_error_to_client_
function _send_error(d::FlacDecoder, status::FlacStatus)
    if !d.is_seeking
        d.on_error(status)
    elseif status == FLAC_UNPARSEABLE
        d.unparseable_frame_count += 1
    end
    nothing
end

# -- stream ------------------------------------------------------------------

"FLAC__stream_decoder_process_single"
function flac_process_single!(d::FlacDecoder)
    while true
        st = d.state
        if st == _FS_SEARCH_FOR_METADATA
            _find_metadata!(d) || return false
        elseif st == _FS_READ_METADATA
            return _read_metadata!(d)
        elseif st == _FS_SEARCH_FOR_FRAME_SYNC
            _frame_sync!(d) || return true
        elseif st == _FS_READ_FRAME
            ok, got = _read_frame!(d)
            ok || return false
            got && return true
        elseif st == _FS_END_OF_STREAM || st == _FS_ABORTED
            return true
        else
            return false
        end
    end
end

function _process_until_end_of_metadata!(d::FlacDecoder)
    while true
        st = d.state
        if st == _FS_SEARCH_FOR_METADATA
            _find_metadata!(d) || return false
        elseif st == _FS_READ_METADATA
            _read_metadata!(d) || return false
        elseif st == _FS_SEARCH_FOR_FRAME_SYNC || st == _FS_READ_FRAME ||
               st == _FS_END_OF_STREAM || st == _FS_ABORTED
            return true
        else
            return false
        end
    end
end

# Look for the stream marker "fLaC", skipping an ID3v2 tag.
function _find_metadata!(d::FlacDecoder)
    i = id3 = 0
    first = true
    try
        while i < 4
            if d.cached >= 0
                x = d.cached
                d.cached = -1
            else
                x = Int(_rd(d, 8))
            end
            if x == b"fLaC"[i+1]
                first = true
                i += 1
                id3 = 0
                continue
            end
            id3 >= 3 && return false
            if x == b"ID3"[id3+1]
                id3 += 1
                i = 0
                if id3 == 3
                    _rd(d, 24)          # version and flags
                    skip = 0
                    for _ in 1:4
                        skip = (skip << 7) | (Int(_rd(d, 8)) & 0x7f)
                    end
                    _skip_bytes!(d, skip)
                end
                continue
            end
            id3 = 0
            if x == 0xff
                x = Int(_rd(d, 8))
                if x == 0xff
                    d.cached = x
                elseif x >> 1 == 0x7c
                    d.warmup = x
                    d.state = _FS_READ_FRAME
                    return true
                end
            end
            i = 0
            if first
                _send_error(d, FLAC_SYNC)
                first = false
            end
        end
    catch e
        e isa _FlacNoInput || rethrow()
        return false
    end
    d.state = _FS_READ_METADATA
    true
end

# Read one metadata block. Only STREAMINFO and SEEKTABLE are examined;
# libFLAC skips the others (as the C library does not ask for them).
function _read_metadata!(d::FlacDecoder)
    local is_last
    try
        is_last = _rd(d, 1) != 0
        typ = Int(_rd(d, 7))
        len = Int(_rd(d, 24))
        if typ == _FLAC_META_STREAMINFO
            d.min_blocksize = Int(_rd(d, 16))
            d.max_blocksize = Int(_rd(d, 16))
            d.min_framesize = Int(_rd(d, 24))
            d.max_framesize = Int(_rd(d, 24))
            d.si_rate = Int(_rd(d, 20))
            d.si_channels = Int(_rd(d, 3)) + 1
            d.si_bps = Int(_rd(d, 5)) + 1
            d.total_samples = Int64(_rd(d, 36))
            for k in 1:_MD5_LEN
                d.si_md5[k] = _rd(d, 8) % UInt8
            end
            len < _FLAC_STREAMINFO_LEN && return false
            _skip_bytes!(d, len - _FLAC_STREAMINFO_LEN)
            d.has_stream_info = true
            all(iszero, d.si_md5) && (d.do_md5_checking = false)
        elseif typ == _FLAC_META_SEEKTABLE
            d.seek_table = nothing
            if len > 0
                len % _FLAC_SEEKPOINT_LEN != 0 && return false
                points = NTuple{3,UInt64}[]
                for _ in 1:len÷_FLAC_SEEKPOINT_LEN
                    a = _rd_long(d, 64)
                    b = _rd_long(d, 64)
                    push!(points, (a, b, _rd(d, 16)))
                end
                d.seek_table = points
            end
        else
            if typ == _FLAC_META_APPLICATION     # an identifier first
                _rd(d, 32)
                if len < 4
                    d.state = _FS_MEMORY_ALLOCATION_ERROR
                    return false
                end
                len -= 4
            end
            _skip_bytes!(d, len)
        end
    catch e
        e isa _FlacNoInput || rethrow()
        return false
    end
    if is_last
        p = _decode_position(d)
        d.first_frame_offset = max(p, 0)
        d.state = _FS_SEARCH_FOR_FRAME_SYNC
    end
    true
end

# Look for the next frame sync code.
function _frame_sync!(d::FlacDecoder)
    data = d.data
    first = true
    try
        (d.pos & 7) != 0 && _rd(d, 8 - (d.pos & 7))
        while true
            if d.cached >= 0
                x = d.cached
                d.cached = -1
            else
                # (skip quickly to the next 0xff byte in the buffer)
                p = d.pos >> 3
                if p >= d.bend
                    _fill!(d)
                    continue
                end
                q = p
                while q < d.bend && @inbounds(data[q+1]) != 0xff
                    q += 1
                end
                if q != p
                    if first
                        _send_error(d, FLAC_SYNC)
                        first = false
                    end
                    if q >= d.bend
                        d.pos = d.endb
                        _fill!(d)
                        continue
                    end
                    d.pos = q << 3
                end
                x = Int(_rd(d, 8))
            end
            if x == 0xff
                x = Int(_rd(d, 8))
                if x == 0xff
                    d.cached = x
                elseif x >> 1 == 0x7c
                    d.warmup = x
                    d.state = _FS_READ_FRAME
                    d.fsloc = (d.pos >> 3) - d.bstart
                    d.last_seen_framesync = max(_decode_position(d), 0)
                    return true
                end
            end
            if first
                _send_error(d, FLAC_SYNC)
                first = false
            end
        end
    catch e
        e isa _FlacNoInput || rethrow()
        return false
    end
end

# -- frames ------------------------------------------------------------------

# Read one frame; returns (ok, got_a_frame).
function _read_frame!(d::FlacDecoder)
    start = (d.pos >> 3) - 2            # (the frame sync code)
    try
        _read_frame_header!(d)
    catch e
        e isa _FlacNoInput || rethrow()
        return false, false
    end
    d.state == _FS_SEARCH_FOR_FRAME_SYNC && return true, false
    nch = d.f_channels
    bs = d.f_blocksize
    assign = d.f_assign
    chans = Vector{Int64}[]
    for ch in 0:nch-1
        bps = d.f_bps
        if (assign == _FLAC_LEFT_SIDE && ch == 1) || (assign == _FLAC_RIGHT_SIDE && ch == 0) ||
           (assign == _FLAC_MID_SIDE && ch == 1)
            bps += 1                    # the side channel
        end
        local out
        try
            out = _read_subframe!(d, bps, bs)
        catch e
            e isa _FlacNoInput || rethrow()
            d.state == _FS_END_OF_STREAM && break
            return false, false
        end
        d.state != _FS_READ_FRAME && break
        push!(chans, out)
    end
    if d.state != _FS_END_OF_STREAM
        # zero padding to the end of the byte
        try
            if (d.pos & 7) != 0 && _rd(d, 8 - (d.pos & 7)) != 0
                _send_error(d, FLAC_SYNC)
                d.state = _FS_SEARCH_FOR_FRAME_SYNC
            end
        catch e
            e isa _FlacNoInput || rethrow()
            return false, false
        end
    end
    local frame::Vector{Vector{Int32}}
    if d.state == _FS_READ_FRAME
        crc = _crc16(d.data, start + 1, d.pos >> 3)
        x = -1
        try
            x = Int(_rd(d, 16))
        catch e
            e isa _FlacNoInput || rethrow()
            d.state != _FS_END_OF_STREAM && return false, false
        end
        if d.state == _FS_READ_FRAME
            if crc == x
                fr = _undo_channel_coding(d, chans, assign)
                if fr === nothing
                    _send_error(d, FLAC_CRC)
                    d.state = _FS_SEARCH_FOR_FRAME_SYNC
                else
                    frame = fr
                end
            else
                _send_error(d, FLAC_CRC)
                d.state = _FS_SEARCH_FOR_FRAME_SYNC
            end
        end
    end
    sn = d.f_sample
    if d.has_last_frame && d.state == _FS_READ_FRAME && !d.is_seeking
        _pad_missing_samples!(d, sn) || return false, false
    end
    if d.state == _FS_SEARCH_FOR_FRAME_SYNC || d.state == _FS_END_OF_STREAM
        # a damaged frame: go back to just after its sync code
        if d.fsloc >= 0
            d.pos = (d.bstart + d.fsloc + 1) * 8
        else
            d.pos = d.bstart * 8
            if d.last_seen_framesync != 0
                if !_seek_file!(d, d.last_seen_framesync)
                    d.state = _FS_SEEK_ERROR
                    return false, false
                end
                _clear!(d)
            end
        end
        d.state = _FS_SEARCH_FOR_FRAME_SYNC
        return true, false
    end
    d.next_fixed_block_size != 0 && (d.fixed_block_size = d.next_fixed_block_size)
    d.channels = nch
    d.bps = d.f_bps
    d.samples_decoded = sn + bs
    if !_write_frame!(d, sn, bs, d.f_rate, nch, d.f_bps, frame)
        d.state = _FS_ABORTED
        return false, false
    end
    d.state = _FS_SEARCH_FOR_FRAME_SYNC
    true, true
end

function _bad_header!(d::FlacDecoder, back::Int=-1)
    back >= 0 && (d.cached = back)
    _send_error(d, FLAC_HEADER)
    d.state = _FS_SEARCH_FOR_FRAME_SYNC
    nothing
end

# A frame or sample number (-1 if its coding is invalid).
function _read_utf8!(d::FlacDecoder, raw::Vector{UInt8}, wide::Bool)
    x = Int(_rd(d, 8))
    push!(raw, x % UInt8)
    (x & 0x80) == 0 && return Int64(x)
    if (x & 0x20) == 0
        v, n = x & 0x1f, 1
    elseif (x & 0x10) == 0
        v, n = x & 0x0f, 2
    elseif (x & 0x08) == 0
        v, n = x & 0x07, 3
    elseif (x & 0x04) == 0
        v, n = x & 0x03, 4
    elseif (x & 0x02) == 0
        v, n = x & 0x01, 5
    elseif wide && (x & 0x01) == 0
        v, n = 0, 6
    else
        return Int64(-1)
    end
    v = Int64(v)
    for _ in 1:n
        x = Int(_rd(d, 8))
        push!(raw, x % UInt8)
        (x & 0xc0) != 0x80 && return Int64(-1)
        v = (v << 6) | (x & 0x3f)
    end
    v
end

function _read_frame_header!(d::FlacDecoder)
    raw = UInt8[0xff, d.warmup % UInt8]
    unparseable = (d.warmup & 0x02) != 0
    for _ in 1:2
        x = Int(_rd(d, 8))
        # (a sync code cannot occur in a frame header)
        x == 0xff && return _bad_header!(d, x)
        push!(raw, x % UInt8)
    end
    bsc = Int(raw[3]) >> 4
    blocksize_hint = 0
    if bsc == 0
        unparseable = true
    elseif bsc == _FLAC_BSC_8BIT || bsc == _FLAC_BSC_16BIT
        blocksize_hint = bsc
    else
        d.f_blocksize = _block_size_code(bsc)
    end
    src = Int(raw[3]) & 0x0f
    rate_hint = 0
    if src == 0
        if d.has_stream_info
            d.f_rate = d.si_rate
        else
            unparseable = true
        end
    elseif src <= 11
        d.f_rate = _FLAC_RATE_TABLE[src]
    elseif src <= 14
        rate_hint = src
    else
        return _bad_header!(d)
    end
    x = Int(raw[4]) >> 4
    if (x & 8) != 0
        d.f_channels = 2
        if (x & 7) <= 2
            d.f_assign = x
        else
            unparseable = true
        end
    else
        d.f_channels = x + 1
        d.f_assign = 0
    end
    ssc = (Int(raw[4]) & 0x0e) >> 1
    if ssc == 0
        if d.has_stream_info
            d.f_bps = d.si_bps
        else
            unparseable = true
        end
    elseif ssc == 3
        unparseable = true
    else
        d.f_bps = _FLAC_BPS_TABLE[ssc+1]
    end
    (raw[4] & 0x01) != 0 && (unparseable = true)
    if (d.warmup & 0x01) != 0 || (d.has_stream_info && d.min_blocksize != d.max_blocksize)
        number = _read_utf8!(d, raw, true)      # sample number
        number < 0 && return _bad_header!(d, Int(raw[end]))
        is_sample = true
    else
        number = _read_utf8!(d, raw, false)     # frame number
        number < 0 && return _bad_header!(d, Int(raw[end]))
        is_sample = false
    end
    if blocksize_hint != 0
        x = Int(_rd(d, 8))
        push!(raw, x % UInt8)
        if blocksize_hint == _FLAC_BSC_16BIT
            y = Int(_rd(d, 8))
            push!(raw, y % UInt8)
            x = (x << 8) | y
        end
        d.f_blocksize = x + 1
        d.f_blocksize > 65535 && return _bad_header!(d, Int(raw[end]))
    end
    if rate_hint != 0
        x = Int(_rd(d, 8))
        push!(raw, x % UInt8)
        if rate_hint != 12
            y = Int(_rd(d, 8))
            push!(raw, y % UInt8)
            x = (x << 8) | y
        end
        d.f_rate = rate_hint == 12 ? x * 1000 : rate_hint == 13 ? x : x * 10
    end
    crc = _rd(d, 8)
    _crc8(raw, 1, length(raw)) != crc && return _bad_header!(d)
    d.next_fixed_block_size = 0
    if !is_sample
        if d.fixed_block_size != 0
            number *= d.fixed_block_size
        elseif d.has_stream_info
            if d.min_blocksize == d.max_blocksize
                number *= d.min_blocksize
                d.next_fixed_block_size = d.max_blocksize
            else
                unparseable = true
            end
        elseif number == 0
            d.next_fixed_block_size = d.f_blocksize
        else
            number *= d.f_blocksize
        end
    end
    d.f_sample = number
    if unparseable
        _send_error(d, FLAC_UNPARSEABLE)
        d.state = _FS_SEARCH_FOR_FRAME_SYNC
    end
    nothing
end

function _lost_sync!(d::FlacDecoder)
    _send_error(d, FLAC_SYNC)
    d.state = _FS_SEARCH_FOR_FRAME_SYNC
    nothing
end

function _unparseable!(d::FlacDecoder)
    _send_error(d, FLAC_UNPARSEABLE)
    d.state = _FS_SEARCH_FOR_FRAME_SYNC
    nothing
end

# Read one subframe; returns its samples (nothing after an error, which
# leaves the state changed).
function _read_subframe!(d::FlacDecoder, bps::Int, bs::Int)
    x = Int(_rd(d, 8))
    wasted = 0
    if (x & 1) != 0
        wasted = _unary!(d) + 1
        wasted >= bps && return _lost_sync!(d)
        bps -= wasted
    end
    x &= 0xfe
    (x & 0x80) != 0 && return _lost_sync!(d)
    local out::Vector{Int64}
    if x == _FLAC_SUBFRAME_CONSTANT
        out = fill(_rd_signed(d, bps), bs)
    elseif x == 2 * _FLAC_SUBFRAME_VERBATIM
        out = Vector{Int64}(undef, bs)
        for i in 1:bs
            out[i] = _rd_signed(d, bps)
        end
    elseif x < 2 * _FLAC_SUBFRAME_FIXED
        return _unparseable!(d)
    elseif x <= 2 * (_FLAC_SUBFRAME_FIXED + _FLAC_MAX_FIXED_ORDER)
        order = (x >> 1) & 7
        bs <= order && return _lost_sync!(d)
        o = _read_fixed!(d, bps, bs, order)
        o === nothing && return nothing
        out = o
    elseif x < 2 * _FLAC_SUBFRAME_LPC
        return _unparseable!(d)
    else
        order = ((x >> 1) & 31) + 1
        bs <= order && return _lost_sync!(d)
        o = _read_lpc!(d, bps, bs, order)
        o === nothing && return nothing
        out = o
    end
    if wasted != 0
        for i in eachindex(out)
            out[i] <<= wasted
        end
    end
    out
end

# The entropy coding method and partition order, then the residual, into
# s[order+1:bs] (false after an error).
function _read_coding!(d::FlacDecoder, s::Vector{Int64}, bs::Int, order::Int)
    method = Int(_rd(d, 2))
    if method > 1
        _unparseable!(d)
        return false
    end
    porder = Int(_rd(d, 4))
    if bs >> porder < order || bs % (1 << porder) != 0
        _lost_sync!(d)
        return false
    end
    _read_residual!(d, s, bs, order, porder, method)
end

function _read_fixed!(d::FlacDecoder, bps::Int, bs::Int, order::Int)
    s = Vector{Int64}(undef, bs)
    for i in 1:order
        s[i] = _rd_signed(d, bps)
    end
    _read_coding!(d, s, bs, order) || return nothing
    # (s[order+1:bs] holds the residual)
    if order == 1
        @inbounds for i in 2:bs
            s[i] += s[i-1]
        end
    elseif order == 2
        @inbounds for i in 3:bs
            s[i] += 2s[i-1] - s[i-2]
        end
    elseif order == 3
        @inbounds for i in 4:bs
            s[i] += 3s[i-1] - 3s[i-2] + s[i-3]
        end
    elseif order == 4
        @inbounds for i in 5:bs
            s[i] += 4s[i-1] - 6s[i-2] + 4s[i-3] - s[i-4]
        end
    end
    s
end

function _read_lpc!(d::FlacDecoder, bps::Int, bs::Int, order::Int)
    s = Vector{Int64}(undef, bs)
    for i in 1:order
        s[i] = _rd_signed(d, bps)
    end
    prec = Int(_rd(d, 4))           # coefficient precision - 1
    prec == 15 && return _lost_sync!(d)
    prec += 1
    shift = Int(_rd_signed(d, 5))
    shift < 0 && return _lost_sync!(d)
    coefs = Vector{Int64}(undef, order)
    for j in 1:order
        coefs[j] = _rd_signed(d, prec)
    end
    _read_coding!(d, s, bs, order) || return nothing
    # (s[order+1:bs] holds the residual; coefs[1] applies to the most recent
    # sample)
    @inbounds for i in order+1:bs
        acc = Int64(0)
        for j in 1:order
            acc += coefs[j] * s[i-j]
        end
        s[i] += acc >> shift
    end
    s
end

# Fold back a zigzag-coded residual.
@inline _unfold(u::Int64) = (u >> 1) ⊻ -(u & 1)

function _read_residual!(d::FlacDecoder, s::Vector{Int64}, bs::Int, order::Int, porder::Int,
                         method::Int)
    # Rice parameters have 4 bits (method 0) or 5 bits (method 1); the
    # all-ones parameter is an escape code for unencoded residuals.
    pbits, esc = method == 0 ? (4, _FLAC_RICE_ESCAPE) : (5, _FLAC_RICE2_ESCAPE)
    psize = bs >> porder
    i = order
    data = d.data
    for part in 0:(1<<porder)-1
        n = part == 0 ? psize - order : psize
        k = Int(_rd(d, pbits))
        if k == esc
            nb = Int(_rd(d, 5))     # bits per unencoded residual
            if nb == 0
                for _ in 1:n
                    s[i+=1] = 0
                end
            else
                for _ in 1:n
                    s[i+=1] = _rd_signed(d, nb)
                end
            end
        elseif k == 0
            for _ in 1:n
                s[i+=1] = _unfold(Int64(_unary!(d)))
            end
        else
            # (libFLAC rejects a quotient too large for 32 bits; its position
            # is then that of the start of the partition)
            limit = 0xffffffff >> k
            start = d.pos
            for _ in 1:n
                p = d.pos
                if (p >> 3) + 8 <= d.bend
                    # (fast path: the whole code within the next 8 bytes)
                    w = _load(data, p >> 3) << (p & 7)
                    z = leading_zeros(w)
                    if w != 0 && z + 1 + k <= 64 - (p & 7)
                        if z > limit
                            d.pos = start
                            _lost_sync!(d)
                            return false
                        end
                        d.pos = p + z + 1 + k
                        u = (Int64(z) << k) | Int64((w << (z + 1)) >> (64 - k))
                        s[i+=1] = _unfold(u)
                        continue
                    end
                end
                q = _unary!(d)
                if q > limit
                    d.pos = start
                    _lost_sync!(d)
                    return false
                end
                u = (Int64(q) << k) | Int64(_rd(d, k))
                s[i+=1] = _unfold(u)
            end
        end
    end
    true
end

# Restore left and right channels from side channels, and check that the
# samples fit the sample size (nothing if they do not).
function _undo_channel_coding(d::FlacDecoder, chans::Vector{Vector{Int64}}, assign::Int)
    if assign == _FLAC_LEFT_SIDE
        a, sd = chans
        chans = [a, a .- sd]
    elseif assign == _FLAC_RIGHT_SIDE
        sd, b = chans
        chans = [sd .+ b, b]
    elseif assign == _FLAC_MID_SIDE
        m, sd = chans
        le = similar(m)
        ri = similar(m)
        for i in eachindex(m)
            x = (m[i] << 1) | (sd[i] & 1)
            le[i] = (x + sd[i]) >> 1
            ri[i] = (x - sd[i]) >> 1
        end
        chans = [le, ri]
    end
    lo = -(Int64(1) << (d.f_bps - 1))
    hi = -lo - 1
    out = Vector{Vector{Int32}}(undef, length(chans))
    for (i, c) in enumerate(chans)
        if !isempty(c) && (minimum(c) < lo || maximum(c) > hi)
            c = _wrap32.(c)
            (minimum(c) < lo || maximum(c) > hi) && return nothing
        end
        out[i] = Int32.(c)
    end
    out
end

# Fill a gap between the previous frame and this one with silence, as libFLAC
# does for missing frames (false if decoding is aborted).
function _pad_missing_samples!(d::FlacDecoder, sn::Int64)
    lsn, lbs, lrate, lch, lbps = d.lf_sample, d.lf_bs, d.lf_rate, d.lf_ch, d.lf_bps
    lsn + lbs >= sn && return true
    need = (sn - (lsn + lbs)) & 0xffffffff
    if lrate != d.f_rate || lch != d.f_channels || lbps != d.f_bps || lbs < 16
        return true
    end
    need = min(need, Int64((5 * lrate) & 0xffffffff), Int64(50 * lbs))
    while need != 0
        lsn += lbs
        need < lbs && (lbs = Int(need))
        need -= lbs
        d.samples_decoded = lsn + lbs
        if !_write_frame!(d, lsn, lbs, lrate, lch, lbps, [zeros(Int32, lbs) for _ in 1:lch])
            d.state = _FS_ABORTED
            return false
        end
    end
    true
end

# write_audio_frame_to_client_
function _write_frame!(d::FlacDecoder, sn::Int64, bs::Int, rate::Int, nch::Int, bps::Int,
                       chans::Vector{Vector{Int32}})
    d.has_last_frame = true
    d.lf_sample, d.lf_bs, d.lf_rate, d.lf_ch, d.lf_bps = sn, bs, rate, nch, bps
    if d.is_seeking
        target = d.target_sample
        if sn <= target < sn + bs       # the target frame
            delta = Int(target - sn)
            d.is_seeking = false
            if delta != 0
                chans = [c[delta+1:end] for c in chans]
                d.lf_sample, d.lf_bs = sn + delta, bs - delta
            end
            return d.on_write(chans)::Bool
        end
        return true
    end
    d.has_stream_info || (d.do_md5_checking = false)
    if d.do_md5_checking
        nb = (bps + 7) ÷ 8
        buf = UInt8[]
        sizehint!(buf, nb * nch * bs)
        for i in 1:bs, c in chans
            _put_le!(buf, c[i], nb)
        end
        md5_update!(d.md5, buf)
    end
    d.on_write(chans)::Bool
end

# -- seeking -----------------------------------------------------------------

"FLAC__stream_decoder_flush"
function flac_flush!(d::FlacDecoder)
    d.samples_decoded = 0
    d.do_md5_checking = false
    d.last_seen_framesync = 0
    d.has_last_frame = false
    _clear!(d)
    d.state = _FS_SEARCH_FOR_FRAME_SYNC
    nothing
end

"FLAC__stream_decoder_seek_absolute"
function flac_seek_absolute!(d::FlacDecoder, sample::Int64)
    d.state in (_FS_SEARCH_FOR_METADATA, _FS_READ_METADATA, _FS_SEARCH_FOR_FRAME_SYNC,
                _FS_READ_FRAME, _FS_END_OF_STREAM) || return false
    total = d.has_stream_info ? d.total_samples : Int64(0)
    total > 0 && sample >= total && return false
    d.is_seeking = true
    d.do_md5_checking = false
    if !d.seekable                      # (the length is not known)
        d.is_seeking = false
        return false
    end
    d.feof = false                      # (finding the length seeks)
    if d.state == _FS_SEARCH_FOR_METADATA || d.state == _FS_READ_METADATA
        if !_process_until_end_of_metadata!(d)
            d.is_seeking = false
            return false
        end
        total = d.has_stream_info ? d.total_samples : Int64(0)
        if total > 0 && sample >= total
            d.is_seeking = false
            return false
        end
    end
    ok = _seek_to_absolute_sample!(d, d.nbytes, sample)
    d.is_seeking = false
    ok
end

# seek_to_absolute_sample_: a binary search for the frame that holds the
# target sample.
function _seek_to_absolute_sample!(d::FlacDecoder, stream_length::Int, target::Int64)
    u32 = Int64(0xffffffff)
    total = d.has_stream_info ? d.total_samples : Int64(0)
    channels = d.channels != 0 ? d.channels : d.si_channels
    bps = d.bps != 0 ? d.bps : d.si_bps
    approx = if d.max_framesize > 0
        Int64((d.max_framesize + d.min_framesize) ÷ 2 + 1)
    elseif d.min_blocksize == d.max_blocksize && d.min_blocksize > 0
        ((Int64(d.min_blocksize) * channels * bps) & u32) ÷ 8 + 64
    else
        ((Int64(4096) * channels * bps) & u32) ÷ 8 + 64
    end
    approx &= u32
    lower = Int64(d.first_frame_offset)
    lower_sample = Int64(0)
    upper = Int64(stream_length)
    upper_sample = total > 0 ? total : target
    if d.state == _FS_SEARCH_FOR_FRAME_SYNC && d.samples_decoded != 0
        p = _decode_position(d)
        if target < d.samples_decoded
            if p >= 0
                upper = p
                upper_sample = d.samples_decoded
            end
        elseif p >= 0
            lower = p
            lower_sample = d.samples_decoded
        end
    end
    if d.seek_table !== nothing && !isempty(d.seek_table)
        new_lower, new_upper = lower, upper
        new_lower_sample, new_upper_sample = lower_sample, upper_sample
        usable(pt) = pt[1] != typemax(UInt64) && pt[3] > 0 &&
                     (total <= 0 || pt[1] < UInt64(total))
        below = [pt for pt in d.seek_table if usable(pt) && pt[1] <= reinterpret(UInt64, target)]
        if !isempty(below)
            new_lower = d.first_frame_offset + reinterpret(Int64, below[end][2])
            new_lower_sample = reinterpret(Int64, below[end][1])
        end
        above = [pt for pt in d.seek_table if usable(pt) && pt[1] > reinterpret(UInt64, target)]
        if !isempty(above)
            new_upper = d.first_frame_offset + reinterpret(Int64, above[1][2])
            new_upper_sample = reinterpret(Int64, above[1][1])
        end
        if new_upper >= new_lower
            lower, upper = new_lower, new_upper
            lower_sample, upper_sample = new_lower_sample, new_upper_sample
        end
    end
    upper_sample == lower_sample && (upper_sample += 1)
    d.target_sample = target
    first_seek = true
    from_lower = false
    while true
        (d.state == _FS_MEMORY_ALLOCATION_ERROR || d.state == _FS_ABORTED) && return false
        if lower_sample >= upper_sample || lower > upper || upper >= typemax(Int64)
            d.state = _FS_SEEK_ERROR
            return false
        end
        if from_lower
            pos = lower
        else
            f = Float64(reinterpret(UInt64, target - lower_sample)) /
                Float64(reinterpret(UInt64, upper_sample - lower_sample)) * Float64(upper - lower)
            # (a value beyond the stream is limited below)
            pos = f >= 4.0e18 ? upper : lower + trunc(Int64, f) - approx
        end
        pos >= upper && (pos = upper - 1)
        pos < lower && (pos = lower)
        if !_seek_file!(d, Int(pos))
            d.state = _FS_SEEK_ERROR
            return false
        end
        flac_flush!(d)
        d.unparseable_frame_count = 0
        if !flac_process_single!(d) || d.state == _FS_ABORTED || d.samples_decoded == 0
            # no frame could be decoded
            if d.state != _FS_ABORTED && d.feof && !from_lower
                from_lower = true
                continue
            end
            d.state = _FS_SEEK_ERROR
            return false
        end
        from_lower = false
        d.is_seeking || break
        this_sample, this_bs = d.lf_sample, Int64(d.lf_bs)
        if this_sample + this_bs >= upper_sample && !first_seek
            if pos == lower
                d.state = _FS_SEEK_ERROR
                return false
            end
            approx = approx != 0 ? (approx * 2) & u32 : Int64(16)
            continue
        end
        first_seek = false
        if this_sample < lower_sample
            d.state = _FS_SEEK_ERROR
            return false
        end
        p = _decode_position(d)
        if p < 0
            d.state = _FS_SEEK_ERROR
            return false
        end
        if target < this_sample
            upper_sample = this_sample + this_bs
            upper = p
            approx = (UInt128(reinterpret(UInt64, upper - pos)) * 2 ÷ 3 + 16) % Int64 & u32
        else
            lower_sample = this_sample + this_bs
            lower = p
            approx = (UInt128(reinterpret(UInt64, lower - pos)) * 2 ÷ 3 + 16) % Int64 & u32
        end
    end
    true
end

"""
    flac_finish!(d::FlacDecoder) -> Bool

FLAC__stream_decoder_finish: false if the MD5 signature does not match the
samples decoded.
"""
function flac_finish!(d::FlacDecoder)
    d.do_md5_checking && return md5_digest!(d.md5) == d.si_md5
    true
end

"""
    flac_decode(data, expect_nsig, expect_bps) -> FlacDecoded

Decode a complete FLAC stream.

If `expect_nsig > 0`, a frame with a different number of channels, or with
more than `expect_bps` bits per sample, ends decoding with status
`FLAC_WFDB` and the message the C library reports (`getvec: wrong number of
signals in FLAC signal file`, `getvec: wrong sample resolution in FLAC
signal file`) in `error_message`; the caller reports it. The first error
that libFLAC reports ends decoding with its status (bytes after the last
frame, even zero bytes, are reported as lost sync).
"""
function flac_decode(data::Vector{UInt8}, expect_nsig::Integer, expect_bps::Integer)
    result = FlacDecoded()
    status = Ref(FLAC_OK)
    on_error = s -> (status[] == FLAC_OK && (status[] = s); nothing)
    local dec::FlacDecoder
    function on_write(fr)
        status[] == FLAC_OK || return false
        if expect_nsig > 0 && length(fr) != expect_nsig
            result.error_message = Vector{UInt8}(b"getvec: wrong number of signals in FLAC signal file\n")
            status[] = FLAC_WFDB
        elseif expect_nsig > 0 && dec.f_bps > expect_bps
            result.error_message = Vector{UInt8}(b"getvec: wrong sample resolution in FLAC signal file\n")
            status[] = FLAC_WFDB
        elseif !isempty(result.chans) && length(fr) != length(result.chans)
            status[] = FLAC_UNPARSEABLE
        end
        status[] == FLAC_OK || return false
        isempty(result.chans) && append!(result.chans, [Int32[] for _ in fr])
        for (c, f) in zip(result.chans, fr)
            append!(c, f)
        end
        true
    end
    dec = FlacDecoder(data, true, on_error, on_write, false)
    while dec.state != _FS_END_OF_STREAM && status[] == FLAC_OK
        flac_process_single!(dec) || status[] != FLAC_OK || (status[] = FLAC_META)
    end
    result.status = status[]
    result.channels = dec.si_channels
    result.bps = dec.si_bps
    result.has_md5 = dec.has_stream_info
    result.md5 = copy(dec.si_md5)
    if result.status != FLAC_OK
        empty!(result.chans)
    elseif isempty(result.chans)
        append!(result.chans, [Int32[] for _ in 1:max(dec.si_channels, 1)])
    end
    result
end

# ---------------------------------------------------------------------------
# Encoder

# MSB-first bit writer appending to a byte vector.
mutable struct _BitWriter
    out::Vector{UInt8}
    acc::UInt64
    nbits::Int
end
_BitWriter(out::Vector{UInt8}) = _BitWriter(out, 0, 0)

# Write the n (0 <= n <= 32) low bits of v.
@inline function _write!(bw::_BitWriter, v::UInt64, n::Int)
    n == 0 && return nothing
    bw.acc = (bw.acc << n) | (v & ((UInt64(1) << n) - 1))
    bw.nbits += n
    while bw.nbits >= 8
        bw.nbits -= 8
        push!(bw.out, (bw.acc >> bw.nbits) % UInt8)
    end
    nothing
end
@inline _write!(bw::_BitWriter, v::Integer, n::Integer) = _write!(bw, v % UInt64, Int(n))

# Write q zero bits followed by a one bit.
function _write_unary!(bw::_BitWriter, q::UInt64)
    while q >= 32
        _write!(bw, UInt64(0), 32)
        q -= 32
    end
    _write!(bw, UInt64(1), Int(q) + 1)
end

function _bw_align!(bw::_BitWriter)
    (bw.nbits & 7) != 0 && _write!(bw, UInt64(0), 8 - (bw.nbits & 7))
    nothing
end

# Append a frame number, UTF-8-like coded.
function _put_utf8!(out::Vector{UInt8}, v::UInt64)
    if v < 0x80
        push!(out, v % UInt8)
        return
    end
    # (number of continuation bytes, lead byte, largest value)
    for (n, lead, mx) in ((1, 0xc0, 0x7ff), (2, 0xe0, 0xffff), (3, 0xf0, 0x1fffff),
                          (4, 0xf8, 0x3ffffff), (5, 0xfc, 0x7fffffff), (6, 0xfe, 0xfffffffff))
        if v <= mx
            b = zeros(UInt8, n + 1)
            for i in n:-1:1
                b[i+1] = (0x80 | (v & 0x3f)) % UInt8
                v >>= 6
            end
            b[1] = (lead | v) % UInt8
            append!(out, b)
            return
        end
    end
end

struct _Partition
    cost::UInt64
    porder::Int
    params::Vector{Int}
end

const _NK = 32      # number of Rice parameters tracked (k = 0 .. maxk <= 30)

# Choose a partition order and Rice parameters for folded residuals (as
# `_best_partition()` in `_flac.py`). For each partition order, and each
# partition, the parameter k is chosen among those near log2 of the mean,
# with the cost (in bits) sum(u >> k) + n * (k + 1). The sums of u >> k are
# computed once for the partitions of the highest partition order and added
# up for the lower orders.
function _best_partition(u::Vector{UInt64}, order::Int, blocksize::Int, maxk::Int)
    # The highest valid partition order
    maxorder = 0
    for porder in 1:_FLAC_MAX_PARTITION_ORDER
        nparts = 1 << porder
        blocksize % nparts != 0 && break
        (blocksize >> porder) <= order && break
        maxorder = porder
    end
    nfine = 1 << maxorder
    fsize = blocksize >> maxorder
    sums = zeros(UInt64, _NK, nfine)
    counts = zeros(Int, nfine)
    start = 0
    @inbounds for p in 0:nfine-1
        n = max(p == 0 ? fsize - order : fsize, 0)
        for j in start+1:start+n
            v = u[j]
            k = 0
            while v != 0 && k <= maxk
                sums[k+1, p+1] += v
                k += 1
                v >>= 1
            end
        end
        counts[p+1] = n
        start += n
    end

    best = _Partition(0, 0, Int[])
    have = false
    acc = zeros(UInt64, _NK)
    for porder in 0:maxorder
        nparts = 1 << porder
        group = 1 << (maxorder - porder)    # fine partitions per part
        cost = UInt64(6)
        params = Int[]
        sizehint!(params, nparts)
        for p in 0:nparts-1
            n = 0
            fill!(acc, 0)
            @inbounds for q in p*group:(p+1)*group-1
                n += counts[q+1]
                for k in 0:maxk
                    acc[k+1] += sums[k+1, q+1]
                end
            end
            if n == 0
                push!(params, 0)
                cost += 4
                continue
            end
            mean = acc[1] ÷ UInt64(n)
            k0 = mean > 0 ? _bit_length(mean) - 1 : 0
            lo = min(max(k0 - 1, 0), maxk)
            hi = min(k0 + 2, maxk)
            bk = -1
            bc = UInt64(0)
            for k in lo:hi
                c = acc[k+1] + UInt64(n) * UInt64(k + 1)
                if bk < 0 || c < bc
                    bk = k
                    bc = c
                end
            end
            push!(params, bk)
            cost += 4 + bc
        end
        if !have || cost < best.cost
            best = _Partition(cost, porder, params)
            have = true
        end
    end
    best
end

# Fixed predictor residual of order 0..4 at x[i].
@inline function _fixed_residual(x::AbstractVector{Int32}, i::Int, order::Int)
    @inbounds begin
        x0 = Int64(x[i])
        order == 0 && return x0
        x1 = Int64(x[i-1])
        order == 1 && return x0 - x1
        x2 = Int64(x[i-2])
        order == 2 && return x0 - 2x1 + x2
        x3 = Int64(x[i-3])
        order == 3 && return x0 - 3x1 + 3x2 - x3
        return x0 - 4x1 + 6x2 - 4x3 + Int64(x[i-4])
    end
end

function _encode_subframe!(bw::_BitWriter, x::AbstractVector{Int32}, bps::Int)
    n = length(x)
    if all(==(x[1]), x)
        _write!(bw, 0, 1)
        _write!(bw, _FLAC_SUBFRAME_CONSTANT, 6)
        _write!(bw, 0, 1)
        _write!(bw, Int64(x[1]), bps)
        return
    end
    maxk = _FLAC_MAX_RICE_PARAM
    have = false
    best_cost = UInt64(0)
    best_order = 0
    best_u = UInt64[]
    u = UInt64[]
    sizehint!(u, n)
    best_bp = _Partition(0, 0, Int[])
    for order in 0:min(n - 1, _FLAC_MAX_FIXED_ORDER)
        empty!(u)
        for i in order+1:n
            r = _fixed_residual(x, i, order)
            push!(u, r >= 0 ? (r % UInt64) << 1 : (((-r) % UInt64) << 1) - 1)
        end
        bp = _best_partition(u, order, n, maxk)
        cost = UInt64(order) * UInt64(bps) + 2 + bp.cost
        if !have || cost < best_cost
            have = true
            best_cost = cost
            best_order = order
            best_u, u = u, best_u
            best_bp = bp
        end
    end
    if !have || best_cost >= UInt64(n) * UInt64(bps)
        _write!(bw, 0, 1)
        _write!(bw, _FLAC_SUBFRAME_VERBATIM, 6)
        _write!(bw, 0, 1)
        for v in x
            _write!(bw, Int64(v), bps)
        end
        return
    end
    order = best_order
    _write!(bw, 0, 1)
    _write!(bw, _FLAC_SUBFRAME_FIXED + order, 6)
    _write!(bw, 0, 1)
    for i in 1:order
        _write!(bw, Int64(x[i]), bps)
    end
    maxparam = max(isempty(best_bp.params) ? 0 : maximum(best_bp.params), 0)
    method = maxparam < _FLAC_RICE_ESCAPE ? 0 : 1
    pbits = method == 0 ? 4 : 5
    _write!(bw, method, 2)
    _write!(bw, best_bp.porder, 4)
    psize = n >> best_bp.porder
    start = 0
    for (p, k) in enumerate(best_bp.params)
        cnt = p == 1 ? psize - order : psize
        _write!(bw, k, pbits)
        for i in 1:max(cnt, 0)
            v = best_u[start+i]
            _write_unary!(bw, v >> k)
            k != 0 && _write!(bw, v, k)
        end
        cnt > 0 && (start += cnt)
    end
end

function _make_streaminfo(minfs::UInt32, maxfs::UInt32, nsig::Integer, bps::Integer,
                          total::UInt64, md5::AbstractVector{UInt8})
    out = UInt8[]
    sizehint!(out, _FLAC_STREAMINFO_LEN)
    bw = _BitWriter(out)
    _write!(bw, FLAC_BLOCKSIZE, 16)     # minimum block size
    _write!(bw, FLAC_BLOCKSIZE, 16)     # maximum block size
    _write!(bw, minfs, 24)
    _write!(bw, maxfs, 24)
    _write!(bw, _FLAC_SAMPLE_RATE, 20)
    _write!(bw, nsig - 1, 3)
    _write!(bw, bps - 1, 5)
    _write!(bw, total >> 32, 4)
    _write!(bw, total & 0xffffffff, 32)
    append!(out, md5)
    out
end

"""
    FlacEncoder(nsig, bps, spf)

Encoder for a signal group of `nsig` signals with `spf` samples per frame
and `bps` (8, 16 or 24) bits per sample. Use [`flac_header!`](@ref),
[`flac_put!`](@ref), [`flac_finish!`](@ref), [`flac_streaminfo`](@ref).
"""
mutable struct FlacEncoder
    nsig::Int32
    bps::Int32
    spf::Int32
    chans::Vector{Vector{Int32}}
    pending::Vector{Int32}
    frame_no::UInt64
    total::UInt64
    minfs::UInt32
    maxfs::UInt32
    have_minfs::Bool
    md5::Md5
end

function FlacEncoder(nsig::Integer, bps::Integer, spf::Integer)
    pending = Int32[]
    sizehint!(pending, max(nsig, 0) * max(spf, 0))
    FlacEncoder(nsig, bps, spf, [Int32[] for _ in 1:max(nsig, 0)], pending, 0, 0, 0, 0, false,
                Md5())
end

"""
    flac_header!(enc) -> Vector{UInt8}

The stream header: `fLaC`, a STREAMINFO block with an unknown total number
of samples, and a VORBIS_COMMENT block (vendor `wfdb-x <version>`). The
final STREAMINFO ([`flac_streaminfo`](@ref)) is written later at offset 8.
"""
function flac_header!(enc::FlacEncoder)
    vlen = length(_FLAC_VENDOR)
    vc = UInt8[(vlen >> (8i)) % UInt8 for i in 0:3]     # vendor length (little-endian)
    append!(vc, _FLAC_VENDOR)
    append!(vc, (0x00, 0x00, 0x00, 0x00))              # no comments
    hdr = Vector{UInt8}(b"fLaC")
    append!(hdr, (_FLAC_META_STREAMINFO, 0x00, 0x00, UInt8(_FLAC_STREAMINFO_LEN)))
    append!(hdr, _make_streaminfo(enc.have_minfs ? enc.minfs : UInt32(0), enc.maxfs, enc.nsig,
                                  enc.bps, _FLAC_UNKNOWN_TOTAL, zeros(UInt8, _MD5_LEN)))
    push!(hdr, _FLAC_META_LAST | _FLAC_META_VORBIS_COMMENT)
    push!(hdr, ((length(vc) >> 16) & 0xff) % UInt8)
    push!(hdr, ((length(vc) >> 8) & 0xff) % UInt8)
    push!(hdr, (length(vc) & 0xff) % UInt8)
    append!(hdr, vc)
    hdr
end

"""
    flac_put!(enc, v::Int32, out::Vector{UInt8})

Append one sample (in WFDB frame order: `spf` samples of signal 0, then
`spf` samples of signal 1, ...), wrapped to `bps` bits. Encoded frames, if
any, are appended to `out`.
"""
function flac_put!(enc::FlacEncoder, v::Int32, out::Vector{UInt8})
    if enc.bps >= 32
        mask, half = 0xffffffff, 0x80000000
    else
        mask, half = (UInt32(1) << enc.bps) - UInt32(1), UInt32(1) << (enc.bps - 1)
    end
    w = (Int64(((v % UInt32) + half) & mask) - Int64(half)) % Int32
    push!(enc.pending, w)
    spf = Int(enc.spf)
    if length(enc.pending) == Int(enc.nsig) * spf
        for (c, ch) in enumerate(enc.chans)
            append!(ch, view(enc.pending, (c-1)*spf+1:c*spf))
        end
        empty!(enc.pending)
        length(enc.chans[1]) >= FLAC_BLOCKSIZE && _write_block!(enc, FLAC_BLOCKSIZE, out)
    end
    nothing
end

"""
    flac_finish!(enc, out::Vector{UInt8})

Encode the remaining samples (appended to `out`).
"""
function flac_finish!(enc::FlacEncoder, out::Vector{UInt8})
    while !isempty(enc.chans) && !isempty(enc.chans[1])
        _write_block!(enc, min(length(enc.chans[1]), FLAC_BLOCKSIZE), out)
    end
    nothing
end

"""
    flac_streaminfo(enc) -> Vector{UInt8}

The final 34-byte STREAMINFO block body (after [`flac_finish!`](@ref)).
"""
function flac_streaminfo(enc::FlacEncoder)
    digest = md5_digest!(copy(enc.md5))
    _make_streaminfo(enc.have_minfs ? enc.minfs : UInt32(0), enc.maxfs, enc.nsig, enc.bps,
                     enc.total, digest)
end

function _write_block!(enc::FlacEncoder, n::Int, out::Vector{UInt8})
    block = Vector{Int32}[]
    for c in enc.chans
        push!(block, c[1:n])
        deleteat!(c, 1:n)
    end
    # MD5 of the interleaved samples
    nb = (Int(enc.bps) + 7) ÷ 8
    inter = UInt8[]
    sizehint!(inter, n * nb * length(block))
    for i in 1:n
        for c in block
            _put_le!(inter, c[i], nb)
        end
    end
    md5_update!(enc.md5, inter)

    frame = UInt8[]
    bsc = n == FLAC_BLOCKSIZE ? _FLAC_BSC_4096 : n <= 256 ? _FLAC_BSC_8BIT : _FLAC_BSC_16BIT
    hb = _BitWriter(frame)
    _write!(hb, _FLAC_SYNC15, 15)
    _write!(hb, 0, 1)                   # fixed block size
    _write!(hb, bsc, 4)
    _write!(hb, _FLAC_RATE_CODE_96K, 4)
    _write!(hb, enc.nsig - 1, 4)        # independent channels
    ssc = enc.bps == 8 ? 1 : enc.bps == 16 ? 4 : enc.bps == 24 ? 6 : 0
    _write!(hb, ssc, 3)
    _write!(hb, 0, 1)
    _put_utf8!(frame, enc.frame_no)
    if bsc == _FLAC_BSC_8BIT
        push!(frame, (n - 1) % UInt8)
    elseif bsc == _FLAC_BSC_16BIT
        push!(frame, ((n - 1) >> 8) % UInt8)
        push!(frame, (n - 1) % UInt8)
    end
    push!(frame, _crc8(frame, 1, length(frame)) % UInt8)
    bw = _BitWriter(frame)
    for c in block
        _encode_subframe!(bw, c, Int(enc.bps))
    end
    _bw_align!(bw)
    c16 = _crc16(frame, 1, length(frame))
    push!(frame, (c16 >> 8) % UInt8)
    push!(frame, (c16 & 0xff) % UInt8)
    append!(out, frame)
    enc.frame_no += 1
    enc.total += n
    fs = length(frame) % UInt32
    if !enc.have_minfs || fs < enc.minfs
        enc.minfs = fs
    end
    enc.have_minfs = true
    fs > enc.maxfs && (enc.maxfs = fs)
    nothing
end

# Precompilation workload: encode and decode short streams of each FLAC
# signal format (8, 16 and 24 bits), with constant, verbatim and fixed
# predictor subframes.
register_workload("flac") do
    for (bps, nsig) in ((8, 1), (16, 2), (24, 3))
        enc = FlacEncoder(nsig, bps, 1)
        out = flac_header!(enc)
        for i in 1:FLAC_BLOCKSIZE+300, s in 1:nsig
            v = s == 1 ? Int32(7) : s == 2 ? (i % 97 - 48) % Int32 : ((i * 7919) % 1000) % Int32
            flac_put!(enc, v, out)
        end
        flac_finish!(enc, out)
        si = flac_streaminfo(enc)
        out[9:8+length(si)] = si
        d = flac_decode(out, nsig, bps)
        flac_samples_md5(d.chans, d.bps)
        flac_decode(out[1:end-3], nsig, bps)
    end
end

export FlacStatus, FLAC_OK, FLAC_SYNC, FLAC_HEADER, FLAC_CRC, FLAC_UNPARSEABLE,
       FLAC_META, FLAC_WFDB
export FlacDecoded, flac_decode, flac_samples_md5, FlacEncoder, flac_header!, flac_put!,
       flac_finish!, flac_streaminfo, FLAC_MAX_CHANNELS, FLAC_BLOCKSIZE
