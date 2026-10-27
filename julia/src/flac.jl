# flac.jl: FLAC decoder and encoder for the FLAC signal formats 508, 516 and
# 524 (a translation of rust/src/flac.rs, itself a translation of
# cpp/src/flac.cpp and python/src/wfdbx/_flac.py).
#
# The C library uses libFLAC for these formats; WFDB-x implements, without
# external libraries, a complete FLAC decoder (all subframe types, fixed and
# LPC predictors, Rice and Rice2 partitions with escape codes, wasted bits,
# stereo decorrelation, variable block sizes, CRC verification) and a
# lossless encoder (fixed predictors and Rice coding). The encoder writes
# exactly the bytes written by the Python, C++ and Rust implementations of
# WFDB-x (standard FLAC streams; their compressed bytes differ from those
# written by libFLAC, whose output depends on its version, but the decoded
# samples are identical).
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
# has no counterpart in the original package: it is WFDB-x's own implementation
# of the FLAC format, which the original package reads and writes with libFLAC.
#
# Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

"`FLAC__MAX_CHANNELS`: the largest number of channels of a FLAC stream."
const FLAC_MAX_CHANNELS = 8
"Samples per channel in each frame written by the encoder."
const FLAC_BLOCKSIZE = 4096

# Vendor string of the VORBIS_COMMENT block written by the encoder.
const _FLAC_VENDOR = b"wfdb-x"
# Length of the body of a STREAMINFO metadata block.
const _FLAC_STREAMINFO_LEN = 34
# Offset of the MD5 signature in a STREAMINFO block (after its 4-byte header).
const _FLAC_MD5_OFFSET = 18
# Metadata block types and flags.
const _FLAC_META_STREAMINFO = 0x00
const _FLAC_META_VORBIS_COMMENT = 0x04
const _FLAC_META_LAST = 0x80
const _FLAC_META_TYPE_MASK = 0x7f
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
# Sample size codes of a frame header (0: from STREAMINFO).
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
`FLAC_EOF` (unexpected end of stream), `FLAC_META` (bad stream header or
metadata), `FLAC_WFDB` (wrong number of channels or resolution).
"""
@enum FlacStatus begin
    FLAC_OK             # no error
    FLAC_SYNC           # lost sync
    FLAC_HEADER         # invalid frame header
    FLAC_CRC            # frame CRC mismatch
    FLAC_UNPARSEABLE    # unsupported format
    FLAC_EOF            # unexpected end of stream
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
    block_ends::Vector{Int64}       # end of each frame (FLAC block), in samples per channel
    has_md5::Bool
    md5::Vector{UInt8}
    error_message::Union{Nothing,Vector{UInt8}}
end
FlacDecoded() = FlacDecoded(FLAC_OK, 0, 0, Vector{Int32}[], Int64[], false, zeros(UInt8, _MD5_LEN),
                            nothing)

# ---------------------------------------------------------------------------
# CRC tables

# (One entry per byte value.)
function _make_crc8()
    t = zeros(UInt8, 256)
    for i in 0:255
        c = UInt32(i)
        for _ in 1:8
            c = (c & 0x80) != 0 ? ((c << 1) ⊻ 0x07) & 0xff : (c << 1) & 0xff
        end
        t[i+1] = c % UInt8
    end
    t
end

function _make_crc16()
    t = zeros(UInt16, 256)
    for i in 0:255
        c = UInt32(i) << 8
        for _ in 1:8
            c = (c & 0x8000) != 0 ? ((c << 1) ⊻ 0x8005) & 0xffff : (c << 1) & 0xffff
        end
        t[i+1] = c % UInt16
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
    UInt32(c)
end

# CRC-16 (polynomial 0x8005) of d[a:b].
function _crc16(d::AbstractVector{UInt8}, a::Int, b::Int)
    c = UInt32(0)
    @inbounds for i in a:b
        c = ((c << 8) & 0xffff) ⊻ UInt32(_CRC16[((c >> 8) ⊻ d[i])+1])
    end
    c
end

_bit_length(x::UInt64) = 64 - leading_zeros(x)

# ---------------------------------------------------------------------------
# Decoder

struct FlacError <: Exception
    status::FlacStatus
end

@noinline _flac_fail(s::FlacStatus) = throw(FlacError(s))

# MSB-first bit reader over a byte array (positions in bits, from 0).
mutable struct _Bits
    d::Vector{UInt8}
    pos::Int
    nbits::Int
end
_Bits(d::Vector{UInt8}, bytepos::Int) = _Bits(d, bytepos * 8, length(d) * 8)

# 8 bytes starting at (0-based) byte b, big-endian, zero-padded beyond the end.
@inline function _load(bt::_Bits, b::Int)
    d = bt.d
    if b + 8 <= length(d)
        w = UInt64(0)
        @inbounds for i in 1:8
            w = (w << 8) | d[b+i]
        end
        return w
    end
    w = UInt64(0)
    for i in 1:8
        w = (w << 8) | (b + i <= length(d) ? UInt64(d[b+i]) : UInt64(0))
    end
    w
end

# Read n bits (0 <= n <= 57) as an unsigned value.
@inline function _read(bt::_Bits, n::Integer)
    n = Int(n)
    if n <= 0
        n < 0 && _flac_fail(FLAC_UNPARSEABLE)
        return UInt64(0)
    end
    bt.pos + n > bt.nbits && _flac_fail(FLAC_EOF)
    w = _load(bt, bt.pos >> 3) << (bt.pos & 7)
    bt.pos += n
    w >> (64 - n)
end

# Read n bits (0 <= n <= 64) as an unsigned value.
function _read_long(bt::_Bits, n::Int)
    n <= 32 && return _read(bt, n)
    hi = _read(bt, n - 32)
    (hi << 32) | _read(bt, 32)
end

function _read_signed(bt::_Bits, n::Int)
    if n > 57
        v = _read_long(bt, n)
        if n < 64 && (v >> (n - 1)) & 1 != 0
            v -= UInt64(1) << n
        end
        return v % Int64
    end
    v = _read(bt, n)
    if n > 0 && (v >> (n - 1)) & 1 != 0
        return (v % Int64) - (Int64(1) << n)
    end
    v % Int64
end

# Count zero bits up to (and consume) the next one bit.
function _unary(bt::_Bits)
    b = bt.pos >> 3
    off = bt.pos & 7
    count = 0
    while true
        b >= length(bt.d) && _flac_fail(FLAC_EOF)
        w = _load(bt, b) << off
        if w != 0
            z = leading_zeros(w)
            bt.pos = (b << 3) + off + z + 1
            return UInt64(count + z)
        end
        count += 64 - off
        b += 8
        off = 0
    end
end

# A Rice-coded value with parameter k (0 <= k <= 30): unary quotient, then
# k bits.
@inline function _rice(bt::_Bits, k::Int)
    b = bt.pos >> 3
    if b + 8 <= length(bt.d)
        off = bt.pos & 7
        w = _load(bt, b) << off
        if w != 0
            z = leading_zeros(w)
            if z + 1 + k <= 64 - off
                bt.pos += z + 1 + k
                k == 0 && return UInt64(z)
                return (UInt64(z) << k) | ((w << (z + 1)) >> (64 - k))
            end
        end
    end
    q = _unary(bt)
    (q << k) | _read(bt, k)
end

_align!(bt::_Bits) = (bt.pos = (bt.pos + 7) & ~7; nothing)
_byte_pos(bt::_Bits) = bt.pos >> 3

# The frame (or sample) number, UTF-8-like coded.
function _read_utf8(bt::_Bits)
    x = _read(bt, 8)
    x < 0x80 && return x
    if (x & 0xe0) == 0xc0
        v, n = x & 0x1f, 1
    elseif (x & 0xf0) == 0xe0
        v, n = x & 0x0f, 2
    elseif (x & 0xf8) == 0xf0
        v, n = x & 0x07, 3
    elseif (x & 0xfc) == 0xf8
        v, n = x & 0x03, 4
    elseif (x & 0xfe) == 0xfc
        v, n = x & 0x01, 5
    elseif x == 0xfe
        v, n = UInt64(0), 6
    else
        _flac_fail(FLAC_HEADER)
    end
    for _ in 1:n
        y = _read(bt, 8)
        (y & 0xc0) != 0x80 && _flac_fail(FLAC_HEADER)
        v = (v << 6) | (y & 0x3f)
    end
    v
end

# Fold back a zigzag-coded residual.
@inline _unfold(u::UInt64) = (u & 1) != 0 ? -((u >> 1) % Int64) - 1 : (u >> 1) % Int64

function _read_residual!(out::Vector{Int64}, bt::_Bits, blocksize::Int, order::Int)
    method = Int(_read(bt, 2))
    method > 1 && _flac_fail(FLAC_UNPARSEABLE)
    pbits = method == 0 ? 4 : 5
    esc = method == 0 ? _FLAC_RICE_ESCAPE : _FLAC_RICE2_ESCAPE
    porder = Int(_read(bt, 4))
    nparts = 1 << porder
    blocksize % nparts != 0 && _flac_fail(FLAC_UNPARSEABLE)
    psize = blocksize >> porder
    (porder > 0 && psize < order) && _flac_fail(FLAC_UNPARSEABLE)
    for part in 0:nparts-1
        n = part == 0 ? psize - order : psize
        k = Int(_read(bt, pbits))
        if k == esc
            nb = Int(_read(bt, 5))
            for _ in 1:n
                push!(out, _read_signed(bt, nb))
            end
        else
            for _ in 1:n
                push!(out, _unfold(_rice(bt, k)))
            end
        end
    end
    nothing
end

@inline _shl(x::Int64, n::Integer) = ((x % UInt64) << n) % Int64

function _decode_subframe(bt::_Bits, blocksize::Int, bps::Int)
    _read(bt, 1) != 0 && _flac_fail(FLAC_UNPARSEABLE)
    t = Int(_read(bt, 6))
    wasted = 0
    if _read(bt, 1) != 0
        wasted = Int(_unary(bt)) + 1
        bps -= wasted
    end
    bs = max(blocksize, 0)
    local s::Vector{Int64}
    if t == _FLAC_SUBFRAME_CONSTANT
        s = fill(_read_signed(bt, bps), bs)
    elseif t == _FLAC_SUBFRAME_VERBATIM
        s = Vector{Int64}(undef, 0)
        sizehint!(s, bs)
        for _ in 1:blocksize
            push!(s, _read_signed(bt, bps))
        end
    elseif _FLAC_SUBFRAME_FIXED <= t <= _FLAC_SUBFRAME_FIXED + _FLAC_MAX_FIXED_ORDER
        order = t - _FLAC_SUBFRAME_FIXED
        s = Vector{Int64}(undef, 0)
        sizehint!(s, max(bs, order))
        for _ in 1:order
            push!(s, _read_signed(bt, bps))
        end
        res = Vector{Int64}(undef, 0)
        sizehint!(res, bs)
        _read_residual!(res, bt, blocksize, order)
        if order == 0
            append!(s, res)
        elseif order == 1
            x = s[end]
            for r in res
                x += r
                push!(s, x)
            end
        elseif order == 2
            a, b = s[end-1], s[end]
            for r in res
                a, b = b, 2b - a + r
                push!(s, b)
            end
        elseif order == 3
            a, b, c = s[end-2], s[end-1], s[end]
            for r in res
                a, b, c = b, c, 3c - 3b + a + r
                push!(s, c)
            end
        else
            a, b, c, d = s[end-3], s[end-2], s[end-1], s[end]
            for r in res
                a, b, c, d = b, c, d, 4d - 6c + 4b - a + r
                push!(s, d)
            end
        end
    elseif t >= _FLAC_SUBFRAME_LPC
        order = t - _FLAC_SUBFRAME_LPC + 1
        s = Vector{Int64}(undef, 0)
        sizehint!(s, max(bs, order))
        for _ in 1:order
            push!(s, _read_signed(bt, bps))
        end
        prec = Int(_read(bt, 4)) + 1
        prec == 16 && _flac_fail(FLAC_UNPARSEABLE)     # (invalid precision code 15)
        shift = Int(_read_signed(bt, 5))
        coefs = zeros(Int64, order)
        for j in 1:order
            coefs[j] = _read_signed(bt, prec)
        end
        res = Vector{Int64}(undef, 0)
        sizehint!(res, bs)
        _read_residual!(res, bt, blocksize, order)
        shift < 0 && _flac_fail(FLAC_UNPARSEABLE)
        for r in res
            base = length(s) - order
            acc = Int64(0)
            # coefs[1] applies to the most recent sample
            @inbounds for j in 1:order
                acc += coefs[j] * s[base+order+1-j]
            end
            push!(s, r + (acc >> shift))
        end
    else
        _flac_fail(FLAC_UNPARSEABLE)
    end
    if wasted != 0
        for i in eachindex(s)
            s[i] = _shl(s[i], wasted)
        end
    end
    s
end

function _block_size_code(bsc::Int)
    bsc == 1 && return 192
    bsc == 2 && return 576
    bsc == 3 && return 1152
    bsc == 4 && return 2304
    bsc == 5 && return 4608
    256 << (bsc - 8)                # 8 .. 15
end

# Decode one frame at (0-based) byte offset pos; returns the channels, the
# bits per sample and the offset of the next frame.
function _decode_frame(data::Vector{UInt8}, pos::Int, si_bps::Int)
    n = length(data)
    if pos + 2 > n || data[pos+1] != 0xff || (data[pos+2] & 0xfe) != 0xf8
        _flac_fail(FLAC_SYNC)
    end
    bt = _Bits(data, pos)
    _read(bt, 15)
    _read(bt, 1)                    # blocking strategy
    bsc = Int(_read(bt, 4))
    src = Int(_read(bt, 4))
    chc = Int(_read(bt, 4))
    ssc = Int(_read(bt, 3))
    _read(bt, 1) != 0 && _flac_fail(FLAC_HEADER)
    _read_utf8(bt)
    blocksize = if bsc == 0
        _flac_fail(FLAC_HEADER)
    elseif bsc == _FLAC_BSC_8BIT
        Int(_read(bt, 8)) + 1
    elseif bsc == _FLAC_BSC_16BIT
        Int(_read(bt, 16)) + 1
    else
        _block_size_code(bsc)
    end
    if src == 12                    # sample rate in kHz (8 bits)
        _read(bt, 8)
    elseif src == 13 || src == 14   # sample rate in Hz or tens of Hz (16 bits)
        _read(bt, 16)
    elseif src == 15
        _flac_fail(FLAC_HEADER)
    end
    bps = if ssc == 0
        si_bps
    elseif _FLAC_BPS_TABLE[ssc+1] != 0
        _FLAC_BPS_TABLE[ssc+1]
    else
        _flac_fail(FLAC_HEADER)
    end
    hend = _byte_pos(bt)
    crc = UInt32(_read(bt, 8))
    _crc8(data, pos + 1, hend) != crc && _flac_fail(FLAC_HEADER)
    chans = Vector{Int64}[]
    if chc < _FLAC_LEFT_SIDE
        for _ in 0:chc
            push!(chans, _decode_subframe(bt, blocksize, bps))
        end
    elseif chc == _FLAC_LEFT_SIDE
        a = _decode_subframe(bt, blocksize, bps)
        sd = _decode_subframe(bt, blocksize, bps + 1)
        push!(chans, a)
        push!(chans, [x - y for (x, y) in zip(a, sd)])
    elseif chc == _FLAC_RIGHT_SIDE
        sd = _decode_subframe(bt, blocksize, bps + 1)
        b = _decode_subframe(bt, blocksize, bps)
        push!(chans, [x + y for (x, y) in zip(sd, b)])
        push!(chans, b)
    elseif chc == _FLAC_MID_SIDE
        mid = _decode_subframe(bt, blocksize, bps)
        sd = _decode_subframe(bt, blocksize, bps + 1)
        m = min(length(mid), length(sd))
        le = Vector{Int64}(undef, m)
        ri = Vector{Int64}(undef, m)
        for i in 1:m
            x = _shl(mid[i], 1) | (sd[i] & 1)
            y = sd[i]
            le[i] = (x + y) >> 1
            ri[i] = (x - y) >> 1
        end
        push!(chans, le)
        push!(chans, ri)
    else
        _flac_fail(FLAC_HEADER)
    end
    _align!(bt)
    fend = _byte_pos(bt)
    c16 = UInt32(_read(bt, 16))
    _crc16(data, pos + 1, fend) != c16 && _flac_fail(FLAC_CRC)
    (chans, bps, _byte_pos(bt))
end

function _all_zero(data::Vector{UInt8}, pos::Int)
    @inbounds for i in pos+1:length(data)
        data[i] != 0 && return false
    end
    true
end

function _flac_decode_inner!(result::FlacDecoded, data::Vector{UInt8}, expect_nsig::Int,
                             expect_bps::Int)
    n = length(data)
    # Errors in the stream header and metadata are reported by libFLAC
    # without invoking its error callback ('meta' status).
    (n < 4 || view(data, 1:4) != b"fLaC") && _flac_fail(FLAC_META)
    pos = 4
    si_bps = 0
    si_ch = 0
    while true
        pos + 4 > n && _flac_fail(FLAC_META)
        hb = data[pos+1]
        ln = (Int(data[pos+2]) << 16) | (Int(data[pos+3]) << 8) | Int(data[pos+4])
        pos + 4 + ln > n && _flac_fail(FLAC_META)
        if (hb & _FLAC_META_TYPE_MASK) == _FLAC_META_STREAMINFO
            ln < _FLAC_STREAMINFO_LEN && _flac_fail(FLAC_META)
            b = _Bits(data, pos + 4)
            _read(b, 16)            # minimum block size
            _read(b, 16)            # maximum block size
            _read(b, 24)            # minimum frame size
            _read(b, 24)            # maximum frame size
            _read(b, 20)            # sample rate
            si_ch = Int(_read(b, 3)) + 1
            si_bps = Int(_read(b, 5)) + 1
            _read(b, 36)            # total samples
            result.has_md5 = true
            result.md5 = data[pos+4+_FLAC_MD5_OFFSET+1:pos+4+_FLAC_MD5_OFFSET+_MD5_LEN]
        end
        pos += 4 + ln
        (hb & _FLAC_META_LAST) != 0 && break
    end
    result.channels = si_ch
    result.bps = si_bps
    result.chans = [Int32[] for _ in 1:max(si_ch, 1)]
    while pos < n
        local fr, bps, newpos
        try
            fr, bps, newpos = _decode_frame(data, pos, si_bps)
        catch e
            e isa FlacError || rethrow()
            # Trailing zero bytes after the last frame are ignored.
            (e.status == FLAC_SYNC && _all_zero(data, pos)) && break
            rethrow()
        end
        pos = newpos
        if expect_nsig > 0 && length(fr) != expect_nsig
            result.error_message = Vector{UInt8}(b"getvec: wrong number of signals in FLAC signal file\n")
            _flac_fail(FLAC_WFDB)
        end
        if expect_nsig > 0 && bps > expect_bps
            result.error_message = Vector{UInt8}(b"getvec: wrong sample resolution in FLAC signal file\n")
            _flac_fail(FLAC_WFDB)
        end
        for (dst, src) in zip(result.chans, fr)
            k = length(dst)
            resize!(dst, k + length(src))
            @inbounds for i in eachindex(src)
                dst[k+i] = src[i] % Int32
            end
        end
        isempty(fr) || push!(result.block_ends, length(result.chans[1]))
    end
    nothing
end

"""
    flac_decode(data, expect_nsig, expect_bps) -> FlacDecoded

Decode a complete FLAC stream.

If `expect_nsig > 0`, a frame with a different number of channels, or with
more than `expect_bps` bits per sample, ends decoding with status
`FLAC_WFDB` and the message the C library reports (`getvec: wrong number of
signals in FLAC signal file`, `getvec: wrong sample resolution in FLAC
signal file`) in `error_message`; the caller reports it. Other errors are
not reported (the status says what happened). Trailing zero bytes after the
last frame are ignored.
"""
function flac_decode(data::Vector{UInt8}, expect_nsig::Integer, expect_bps::Integer)
    result = FlacDecoded()
    try
        _flac_decode_inner!(result, data, Int(expect_nsig), Int(expect_bps))
    catch e
        e isa FlacError || rethrow()
        result.status = e.status
        empty!(result.chans)
    end
    result
end

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

export FlacStatus, FLAC_OK, FLAC_SYNC, FLAC_HEADER, FLAC_CRC, FLAC_UNPARSEABLE, FLAC_EOF,
       FLAC_META, FLAC_WFDB
export FlacDecoded, flac_decode, flac_samples_md5, FlacEncoder, flac_header!, flac_put!,
       flac_finish!, flac_streaminfo, FLAC_MAX_CHANNELS, FLAC_BLOCKSIZE
