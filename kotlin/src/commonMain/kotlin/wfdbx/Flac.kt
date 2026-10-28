// FLAC decoder and encoder for the FLAC signal formats 508, 516 and 524
// (port of rust/src/flac.rs, itself a port of cpp/src/flac.cpp).
//
// The C library uses libFLAC for these formats; WFDB-x implements, without
// external libraries, a complete FLAC decoder (all subframe types, fixed and
// LPC predictors, Rice and Rice2 partitions with escape codes, wasted bits,
// stereo decorrelation, variable block sizes, CRC verification) and a
// lossless encoder (fixed predictors and Rice coding). The encoder writes
// exactly the bytes written by the Python, C++ and Rust implementations of
// WFDB-x (standard FLAC streams; their compressed bytes differ from those
// written by libFLAC, whose output depends on its version, but the decoded
// samples are identical).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// Its FLAC decoder is a Kotlin translation of the stream decoder of libFLAC
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

package wfdbx

import wfdbx.cstd.ByteVec
import wfdbx.cstd.latin1

/** `FLAC__MAX_CHANNELS`. */
internal const val FLAC_MAX_CHANNELS: Int = 8

/** Samples per channel in each frame written by the encoder. */
internal const val FLAC_BLOCKSIZE: Int = 4096

private val VENDOR = "wfdb-x".latin1()

// Constants of the FLAC stream format (RFC 9639).

/** The marker that begins a FLAC stream. */
private val MARKER = "fLaC".latin1()

/** Size of a metadata block header (last-block flag and type, 24-bit length). */
private const val METADATA_HEADER_LEN = 4

/** Last-block flag of a metadata block header. */
private const val METADATA_LAST = 0x80

/** Metadata block types. */
private const val METADATA_STREAMINFO = 0
private const val METADATA_SEEKTABLE = 3
private const val METADATA_VORBIS_COMMENT = 4

/** Length of the body of a STREAMINFO block. */
private const val STREAMINFO_LEN = 34

/** Offset of the MD5 signature in a STREAMINFO block body. */
private const val STREAMINFO_MD5_POS = 18

/** Length of an MD5 signature. */
internal const val FLAC_MD5_LEN: Int = 16

/** Offset of the STREAMINFO block body in the streams written by [FlacEncoder]. */
internal const val FLAC_STREAMINFO_POS: Long = 8L // MARKER + METADATA_HEADER_LEN

/** Total number of samples written in the preliminary STREAMINFO block (the largest 36-bit value). */
private const val TOTAL_UNKNOWN: Long = (1L shl 36) - 1

/** Sample rate recorded by the encoder (nominal), and its frame header code. */
private const val SAMPLE_RATE: Long = 96000
private const val SAMPLE_RATE_CODE: Long = 11

/** The first 15 bits of a frame header: the 14-bit sync code and a reserved 0 bit. */
private const val FRAME_SYNC: Long = 0x7FFC

/** Frame header block size codes. */
private const val BLOCKSIZE_CODE_8BIT = 6
private const val BLOCKSIZE_CODE_16BIT = 7
private const val BLOCKSIZE_CODE_4096 = 12

/** Frame header channel assignments (stereo decorrelation modes). */
private const val CHANNELS_LEFT_SIDE = 8
private const val CHANNELS_SIDE_RIGHT = 9
private const val CHANNELS_MID_SIDE = 10

/** Subframe types. */
private const val SUBFRAME_CONSTANT = 0
private const val SUBFRAME_VERBATIM = 1
private const val SUBFRAME_FIXED = 8
private const val SUBFRAME_LPC = 32

/** Largest fixed predictor order, and largest LPC order. */
private const val MAX_FIXED_ORDER = 4
private const val MAX_LPC_ORDER = 32

/** Width of the Rice parameters of coding methods 0 (Rice) and 1 (Rice2). */
private const val RICE_PARAM_BITS = 4
private const val RICE2_PARAM_BITS = 5

/** Width of the partition order of residual coding. */
private const val PARTITION_ORDER_BITS = 4

/** An error reported to [FlacClient.error] (libFLAC's `FLAC__StreamDecoderErrorStatus`); decoding goes on after it. */
internal enum class FlacDecodeError {
    /** Lost sync. */
    LOST_SYNC,

    /** Invalid frame header. */
    BAD_HEADER,

    /** Frame CRC mismatch. */
    CRC_MISMATCH,

    /** Unsupported format. */
    UNPARSEABLE,
}

/** The state of a [FlacStreamDecoder] (libFLAC's `FLAC__StreamDecoderState`). */
internal enum class FlacState {
    SEARCH_FOR_METADATA,
    READ_METADATA,
    SEARCH_FOR_FRAME_SYNC,
    READ_FRAME,
    END_OF_STREAM,
    SEEK_ERROR,
    ABORTED,
}

/** The header of a decoded frame (FLAC block). */
internal data class FlacFrameHeader(
    /** Samples per channel. */
    var blocksize: Int = 0,
    var sampleRate: Int = 0,
    var channels: Int = 0,
    var bitsPerSample: Int = 0,
    /** The number of the first sample (per channel). */
    var sampleNumber: Long = 0,
)

/** The receiver of the results of a [FlacStreamDecoder] (the error and write callbacks of libFLAC). */
internal interface FlacClient {
    /** An error in the stream (decoding goes on). */
    fun error(e: FlacDecodeError)

    /**
     * A decoded frame: the samples of each channel, `chans[c][off until
     * off + h.blocksize]`. Returns false to abort decoding.
     */
    fun write(h: FlacFrameHeader, chans: Array<IntArray>, off: Int): Boolean
}

/**
 * Why a read within a frame stopped: the end of the stream (error null;
 * libFLAC's read callback then sets the end-of-stream state), or an error
 * in it.
 */
private class FlacFail(val error: FlacDecodeError?) : Exception()

// ---------------------------------------------------------------------------
// CRC tables

private val CRC8: IntArray = IntArray(256).also { t ->
    for (i in 0 until 256) {
        var c = i
        for (k in 0 until 8) c = if (c and 0x80 != 0) ((c shl 1) xor 0x07) and 0xFF else (c shl 1) and 0xFF
        t[i] = c
    }
}

private val CRC16: IntArray = IntArray(256).also { t ->
    for (i in 0 until 256) {
        var c = i shl 8
        for (k in 0 until 8) c = if (c and 0x8000 != 0) ((c shl 1) xor 0x8005) and 0xFFFF else (c shl 1) and 0xFFFF
        t[i] = c
    }
}

private fun crc8(p: ByteArray, from: Int, to: Int): Int {
    var c = 0
    for (i in from until to) c = CRC8[c xor (p[i].toInt() and 0xff)]
    return c
}

private fun crc16(p: ByteArray, from: Int, to: Int): Int {
    var c = 0
    for (i in from until to) c = ((c shl 8) and 0xFFFF) xor CRC16[(c ushr 8) xor (p[i].toInt() and 0xff)]
    return c
}

private fun bitLength(x: Long): Int = 64 - x.countLeadingZeroBits()

/** Unsigned comparison of two 64-bit values: a < b. */
private fun ult(a: Long, b: Long): Boolean = (a xor Long.MIN_VALUE) < (b xor Long.MIN_VALUE)

/** 8 bytes at p, big-endian. */
private fun load8(d: ByteArray, p: Int): Long {
    var w = 0L
    for (i in 0 until 8) w = (w shl 8) or (d[p + i].toLong() and 0xff)
    return w
}

/** A growable array of 32-bit values. */
private class IntVec(capacity: Int) {
    var a = IntArray(if (capacity < 1) 1 else capacity)
    var size = 0

    fun ensure(n: Int) {
        if (n > a.size) {
            var m = a.size * 2
            if (m < n) m = n
            a = a.copyOf(m)
        }
    }

    fun add(v: Int) {
        if (size == a.size) a = a.copyOf(a.size * 2)
        a[size++] = v
    }

    /** Removes the first n values. */
    fun drop(n: Int) {
        a.copyInto(a, 0, n, size)
        size -= n
    }

    fun toArray(): IntArray = a.copyOf(size)
}

// ---------------------------------------------------------------------------
// Decoder

/** MSB-first bit reader over a byte array. */
private class Bits(val d: ByteArray, bytepos: Int) {
    var pos: Long = bytepos.toLong() * 8
    val end: Long = d.size.toLong() * 8

    /** 8 bytes starting at b, big-endian, zero-padded beyond the end. */
    fun load(b: Int): Long {
        if (b + 8 <= d.size) return load8(d, b)
        var w = 0L
        for (i in 0 until 8) w = (w shl 8) or (if (b + i < d.size) d[b + i].toLong() and 0xff else 0L)
        return w
    }

    /** Read n bits (0 <= n <= 57) as an unsigned value. */
    fun read(n: Int): Long {
        if (n <= 0) {
            if (n < 0) throw FlacFail(FlacDecodeError.UNPARSEABLE)
            return 0
        }
        if (pos + n > end) throw FlacFail(null)
        val b = (pos ushr 3).toInt()
        val off = (pos and 7).toInt()
        val w = load(b) shl off
        pos += n
        return w ushr (64 - n)
    }

    /** Read n bits (0 <= n <= 64) as an unsigned value. */
    fun readLong(n: Int): Long {
        if (n <= 32) return read(n)
        val hi = read(n - 32)
        return (hi shl 32) or read(32)
    }

    fun readSigned(n: Int): Long {
        if (n > 57) {
            var v = readLong(n)
            if (n < 64 && (v ushr (n - 1)) and 1L != 0L) v -= (1L shl n)
            return v
        }
        val v = read(n)
        if (n > 0 && (v ushr (n - 1)) and 1L != 0L) return v - (1L shl n)
        return v
    }

    /** Count zero bits up to (and consume) the next one bit. */
    fun unary(): Long {
        var b = (pos ushr 3).toInt()
        var off = (pos and 7).toInt()
        var count = 0L
        while (true) {
            if (b >= d.size) throw FlacFail(null)
            val w = load(b) shl off
            if (w != 0L) {
                val z = w.countLeadingZeroBits().toLong()
                pos = (b.toLong() shl 3) + off + z + 1
                return count + z
            }
            count += (64 - off).toLong()
            b += 8
            off = 0
        }
    }

    /** A Rice-coded value with parameter k (0 <= k <= 30): unary quotient, then k bits. */
    fun rice(k: Int): Long {
        val b = (pos ushr 3).toInt()
        if (b + 8 <= d.size) {
            val off = (pos and 7).toInt()
            val w = load8(d, b) shl off
            if (w != 0L) {
                val z = w.countLeadingZeroBits()
                if (z + 1 + k <= 64 - off) {
                    pos += (z + 1 + k).toLong()
                    if (k == 0) return z.toLong()
                    return (z.toLong() shl k) or ((w shl (z + 1)) ushr (64 - k))
                }
            }
        }
        val q = unary()
        return (q shl k) or read(k)
    }

    fun bytePos(): Int = (pos ushr 3).toInt()
}

/** Bits per sample of the frame header sample size codes (0: as in STREAMINFO; 3: reserved). */
private val BPS_TABLE = intArrayOf(0, 8, 12, 0, 16, 20, 24, 32)

/** Sample rates of the frame header sample rate codes 1 to 11. */
private val SAMPLE_RATES = intArrayOf(0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000)

/** The block size given by a frame header block size code (other than 0, 6 and 7). */
private fun blockSizeCode(bsc: Int): Long = when (bsc) {
    1 -> 192
    2 -> 576
    3 -> 1152
    4 -> 2304
    5 -> 4608
    else -> 256L shl (bsc - 8) // 8 .. 15
}

private fun unfold(u: Long): Long = if (u and 1L != 0L) -(u ushr 1) - 1 else u ushr 1

/**
 * The residual of a subframe (`read_residual_partitioned_rice_`), after its
 * coding method and partition order, into out from position at; returns
 * the new position.
 */
private fun readResidual(bits: Bits, blocksize: Int, order: Int, out: LongArray, at: Int): Int {
    var k0 = at
    val method = bits.read(2)
    if (method > 1) throw FlacFail(FlacDecodeError.UNPARSEABLE)
    val porder = bits.read(PARTITION_ORDER_BITS).toInt()
    if ((blocksize ushr porder) < order || blocksize % (1 shl porder) > 0) throw FlacFail(FlacDecodeError.LOST_SYNC)
    val pbits = if (method == 0L) RICE_PARAM_BITS else RICE2_PARAM_BITS
    val esc = (1L shl pbits) - 1
    val psize = blocksize ushr porder
    for (part in 0 until (1 shl porder)) {
        val first = if (part == 0) order else 0
        val k = bits.read(pbits)
        if (k < esc) {
            val kk = k.toInt()
            val start = bits.pos
            for (i in first until psize) {
                val v = bits.rice(kk)
                // (a quotient too large for a 32-bit residual is an invalid
                // symbol: libFLAC is then back at the start of the block)
                if (kk > 0 && (v ushr 32) != 0L) {
                    bits.pos = start
                    throw FlacFail(FlacDecodeError.LOST_SYNC)
                }
                out[k0++] = unfold(v and 0xffffffffL)
            }
        } else {
            val nb = bits.read(5).toInt()
            if (nb == 0) {
                for (i in first until psize) out[k0++] = 0
            } else {
                for (i in first until psize) out[k0++] = bits.readSigned(nb)
            }
        }
    }
    return k0
}

/** A subframe of blocksize samples of bps bits (`read_subframe_`). */
private fun readSubframe(bits: Bits, blocksize: Int, bps0: Int): LongArray {
    val x = bits.read(8).toInt()
    var bps = bps0
    var wasted = 0
    if (x and 1 != 0) {
        val u = bits.unary()
        if (u + 1 >= bps) throw FlacFail(FlacDecodeError.LOST_SYNC)
        wasted = u.toInt() + 1
        bps -= wasted
    }
    val t = x and 0xfe
    val bs = blocksize
    val s: LongArray
    if (t and 0x80 != 0) {
        // (the zero bit before the subframe type)
        throw FlacFail(FlacDecodeError.LOST_SYNC)
    } else if (t == SUBFRAME_CONSTANT shl 1) {
        val v = bits.readSigned(bps)
        s = LongArray(bs) { v }
    } else if (t == SUBFRAME_VERBATIM shl 1) {
        s = LongArray(bs)
        for (i in 0 until bs) s[i] = bits.readSigned(bps)
    } else if (t < SUBFRAME_FIXED shl 1) {
        throw FlacFail(FlacDecodeError.UNPARSEABLE)
    } else if (t <= (SUBFRAME_FIXED + MAX_FIXED_ORDER) shl 1) {
        val order = (t shr 1) and 7
        if (bs <= order) throw FlacFail(FlacDecodeError.LOST_SYNC)
        s = LongArray(bs)
        for (i in 0 until order) s[i] = bits.readSigned(bps)
        val n = readResidual(bits, blocksize, order, s, order)
        // (s[order until n] holds the residuals; reconstruct in place)
        when (order) {
            0 -> {}
            1 -> for (i in order until n) s[i] = s[i - 1] + s[i]
            2 -> for (i in order until n) s[i] = 2 * s[i - 1] - s[i - 2] + s[i]
            3 -> for (i in order until n) s[i] = 3 * s[i - 1] - 3 * s[i - 2] + s[i - 3] + s[i]
            else -> for (i in order until n) s[i] = 4 * s[i - 1] - 6 * s[i - 2] + 4 * s[i - 3] - s[i - 4] + s[i]
        }
    } else if (t < SUBFRAME_LPC shl 1) {
        throw FlacFail(FlacDecodeError.UNPARSEABLE)
    } else {
        val order = ((t shr 1) and 31) + 1
        if (bs <= order) throw FlacFail(FlacDecodeError.LOST_SYNC)
        s = LongArray(bs)
        for (i in 0 until order) s[i] = bits.readSigned(bps)
        val prec = bits.read(4).toInt()
        // (precision code 15, all ones, is invalid)
        if (prec == 15) throw FlacFail(FlacDecodeError.LOST_SYNC)
        val shift = bits.readSigned(5).toInt()
        if (shift < 0) throw FlacFail(FlacDecodeError.LOST_SYNC)
        val coefs = LongArray(MAX_LPC_ORDER)
        for (j in 0 until order) coefs[j] = bits.readSigned(prec + 1)
        val n = readResidual(bits, blocksize, order, s, order)
        for (i in order until n) {
            var acc = 0L
            // coefs[0] applies to the most recent sample
            for (j in 0 until order) acc += coefs[j] * s[i - 1 - j]
            s[i] = s[i] + (acc shr shift)
        }
    }
    if (wasted != 0) for (i in s.indices) s[i] = s[i] shl wasted
    return s
}

/** The body of a frame read by [frameBody]. */
private class FrameBody {
    /** The errors found, in order. */
    val errors = ArrayList<FlacDecodeError>()

    /** Did the data end within the frame? */
    var eof = false

    /** The samples of each channel (null if the frame is not valid). */
    var chans: Array<IntArray>? = null

    /** The offset of the end of the frame (if valid). */
    var end = 0
}

/**
 * The subframes and footer of a frame that starts at start, from pos
 * (after its header), as `read_frame_` reads them.
 */
private fun frameBody(data: ByteArray, start: Int, pos: Int, h: FlacFrameHeader, assignment: Int): FrameBody {
    val body = FrameBody()
    body.end = pos
    val bits = Bits(data, pos)
    val subframes = ArrayList<LongArray>(h.channels)
    var ok = true
    for (c in 0 until h.channels) {
        // (the side channel has one bit more)
        val side = when (assignment) {
            CHANNELS_LEFT_SIDE, CHANNELS_MID_SIDE -> c == 1
            CHANNELS_SIDE_RIGHT -> c == 0
            else -> false
        }
        try {
            subframes.add(readSubframe(bits, h.blocksize, h.bitsPerSample + if (side) 1 else 0))
        } catch (e: FlacFail) {
            val err = e.error
            if (err == null) {
                body.eof = true
                return body
            }
            body.errors.add(err)
            ok = false
            break
        }
    }
    // The zero padding to a byte boundary.
    val n = ((8 - bits.pos % 8) % 8).toInt()
    if (n > 0) {
        val padding = try {
            bits.read(n)
        } catch (e: FlacFail) {
            -1L
        }
        if (padding != 0L) {
            body.errors.add(FlacDecodeError.LOST_SYNC)
            return body
        }
    }
    if (!ok) return body
    val fend = bits.bytePos()
    val c16 = try {
        bits.read(16).toInt()
    } catch (e: FlacFail) {
        body.eof = true
        return body
    }
    if (crc16(data, start, fend) != c16) {
        body.errors.add(FlacDecodeError.CRC_MISMATCH)
        return body
    }
    // Undo the stereo decorrelation.
    val bs = h.blocksize
    val chans: Array<IntArray>
    when (assignment) {
        CHANNELS_LEFT_SIDE -> {
            val a = subframes[0]
            val sd = subframes[1]
            chans = arrayOf(IntArray(bs) { a[it].toInt() }, IntArray(bs) { (a[it] - sd[it]).toInt() })
        }
        CHANNELS_SIDE_RIGHT -> {
            val sd = subframes[0]
            val b = subframes[1]
            chans = arrayOf(IntArray(bs) { (sd[it] + b[it]).toInt() }, IntArray(bs) { b[it].toInt() })
        }
        CHANNELS_MID_SIDE -> {
            val mid = subframes[0]
            val sd = subframes[1]
            val le = IntArray(bs)
            val ri = IntArray(bs)
            for (i in 0 until bs) {
                val x = (mid[i] shl 1) or (sd[i] and 1L)
                le[i] = ((x + sd[i]) shr 1).toInt()
                ri[i] = ((x - sd[i]) shr 1).toInt()
            }
            chans = arrayOf(le, ri)
        }
        else -> chans = Array(subframes.size) { c -> val s = subframes[c]; IntArray(bs) { s[it].toInt() } }
    }
    // The decoded samples must fit in bits_per_sample bits.
    val shift = 32 - h.bitsPerSample
    val lo = Int.MIN_VALUE shr shift
    val hi = Int.MAX_VALUE shr shift
    for (c in chans) for (v in c) {
        if (v < lo || v > hi) {
            body.errors.add(FlacDecodeError.CRC_MISMATCH)
            return body
        }
    }
    body.chans = chans
    body.end = bits.bytePos()
    return body
}

/** A seek point of a SEEKTABLE metadata block. */
private class SeekPoint(val sampleNumber: ULong, val streamOffset: ULong, val frameSamples: Int)

/** The first bytes of an ID3v2 tag. */
private val ID3V2_TAG = "ID3".latin1()

/** Value of a placeholder seek point. */
private const val SEEKPOINT_PLACEHOLDER: ULong = ULong.MAX_VALUE

/** Length of a seek point. */
private const val SEEKPOINT_LEN = 18

/** The value of [FlacStreamDecoder.readUtf8] for an invalid coding. */
private const val UTF8_INVALID = -1L

/** The value of [FlacStreamDecoder.readUtf8] at the end of the stream. */
private const val UTF8_EOF = -2L

/**
 * A FLAC stream decoder that decodes as libFLAC's stream decoder does, frame
 * by frame, with the same results, errors and states, from a stream held in
 * memory: it finds the metadata (after an ID3v2 tag, if any), reads
 * STREAMINFO and SEEKTABLE, then decodes one frame (FLAC block) at a time;
 * a damaged frame is reported to the client and skipped (decoding goes on
 * at the next frame sync code), and [seekAbsolute] seeks as libFLAC does (a
 * bisection on the stream). The client receives the errors and the decoded
 * frames ([FlacClient]). Made with `FLAC__stream_decoder_init_stream`, at
 * the start of [data]; [seekable]: can the stream seek (C: the signal
 * group's `seek`)?
 */
internal class FlacStreamDecoder(private val data: ByteArray, private val seekable: Boolean, md5Checking: Boolean) {
    /** The offset of the next byte to read. */
    private var pos = 0
    var state = FlacState.SEARCH_FOR_METADATA
        private set

    /** The two bytes of the frame sync code of the frame being read, and the offset that follows them. */
    private val warmup = IntArray(2)
    private var framesync = 0
    private var hasStreamInfo = false
    private var minBlocksize = 0
    private var maxBlocksize = 0
    private var minFramesize = 0L
    private var maxFramesize = 0L
    private var siSampleRate = 0
    internal var siChannels = 0
        private set
    internal var siBps = 0
        private set
    private var totalSamples0 = 0L
    internal val md5sum = ByteArray(FLAC_MD5_LEN)
    private var seekTable: Array<SeekPoint>? = null
    private var firstFrameOffset = 0L
    private var fixedBlockSize = 0
    private var nextFixedBlockSize = 0
    private var samplesDecoded = 0L

    /** Channels and bits per sample of the last frame decoded (0: none). */
    private var channels = 0
    private var bps = 0
    private var lastFrame = FlacFrameHeader()
    private var lastFrameIsSet = false
    private var isSeeking = false
    private var targetSample: ULong = 0u
    private var doMd5Checking = md5Checking
    private val md5ctx = Md5()

    /** The channel assignment of the frame being read. */
    private var assignment = 0

    /** Is there a STREAMINFO block? */
    internal val hasMd5: Boolean get() = hasStreamInfo

    /** The total number of samples (per channel) given by STREAMINFO (0 if unknown). */
    fun totalSamples(): Long = if (hasStreamInfo) totalSamples0 else 0

    /**
     * `FLAC__stream_decoder_finish`: false if the MD5 signature of the
     * decoded samples was checked and differs from that of STREAMINFO.
     */
    fun finish(): Boolean {
        val computed = md5ctx.digest()
        return !(doMd5Checking && !computed.contentEquals(md5sum))
    }

    /** `FLAC__stream_decoder_flush`. */
    fun flush() {
        samplesDecoded = 0
        doMd5Checking = false
        lastFrameIsSet = false
        state = FlacState.SEARCH_FOR_FRAME_SYNC
    }

    private fun sendError(client: FlacClient, e: FlacDecodeError) {
        // (not reported while seeking)
        if (!isSeeking) client.error(e)
    }

    /** The next byte (-1 at the end of the stream, which ends decoding). */
    private fun byte(): Int {
        if (pos < data.size) return data[pos++].toInt() and 0xff
        state = FlacState.END_OF_STREAM
        return -1
    }

    /** Skips n bytes (false at the end of the stream). */
    private fun skip(n: Int): Boolean {
        if (n > data.size - pos) {
            pos = data.size
            state = FlacState.END_OF_STREAM
            return false
        }
        pos += n
        return true
    }

    /** The big-endian value of the next n bytes (null at the end of the stream). */
    private fun bytes(n: Int): Long? {
        var v = 0L
        for (i in 0 until n) {
            val x = byte()
            if (x < 0) return null
            v = (v shl 8) or x.toLong()
        }
        return v
    }

    /** `FLAC__stream_decoder_get_decode_position` (-1: not available). */
    private fun decodePosition(): Long = if (seekable) pos.toLong() else -1

    /**
     * `FLAC__stream_decoder_process_single`: decodes one metadata block or
     * one frame; false on a fatal error (the state tells which).
     */
    fun processSingle(client: FlacClient): Boolean {
        while (true) {
            when (state) {
                FlacState.SEARCH_FOR_METADATA -> if (!findMetadata(client)) return false
                FlacState.READ_METADATA -> return readMetadata()
                FlacState.SEARCH_FOR_FRAME_SYNC -> if (!frameSync(client)) return true
                FlacState.READ_FRAME -> {
                    val r = readFrame(client)
                    if (r < 0) return false
                    if (r > 0) return true
                }
                FlacState.END_OF_STREAM, FlacState.ABORTED -> return true
                FlacState.SEEK_ERROR -> return false
            }
        }
    }

    /** `FLAC__stream_decoder_process_until_end_of_metadata`. */
    private fun processUntilEndOfMetadata(client: FlacClient): Boolean {
        while (true) {
            when (state) {
                FlacState.SEARCH_FOR_METADATA -> if (!findMetadata(client)) return false
                FlacState.READ_METADATA -> if (!readMetadata()) return false
                FlacState.SEARCH_FOR_FRAME_SYNC, FlacState.READ_FRAME, FlacState.END_OF_STREAM,
                FlacState.ABORTED -> return true
                FlacState.SEEK_ERROR -> return false
            }
        }
    }

    /** `find_metadata_`: the `fLaC` marker (after an ID3v2 tag, if any), or a frame sync code. */
    private fun findMetadata(client: FlacClient): Boolean {
        var i = 0
        var id = 0
        var first = true
        while (i < MARKER.size) {
            val x = byte()
            if (x < 0) return false
            if (x == MARKER[i].toInt() and 0xff) {
                first = true
                i++
                id = 0
                continue
            }
            if (id >= ID3V2_TAG.size) return false
            if (x == ID3V2_TAG[id].toInt() and 0xff) {
                id++
                i = 0
                if (id == ID3V2_TAG.size && !skipId3v2Tag()) return false
                continue
            }
            id = 0
            if (x == 0xff) {
                warmup[0] = x
                val y = byte()
                if (y < 0) return false
                if (y == 0xff) {
                    pos-- // (it may begin a sync code)
                } else if (y shr 1 == 0x7c) {
                    warmup[1] = y
                    framesync = pos
                    state = FlacState.READ_FRAME
                    return true
                }
            }
            i = 0
            if (first) {
                sendError(client, FlacDecodeError.LOST_SYNC)
                first = false
            }
        }
        state = FlacState.READ_METADATA
        return true
    }

    /** `skip_id3v2_tag_`. */
    private fun skipId3v2Tag(): Boolean {
        // the version and flags, then the size (7 bits per byte)
        if (bytes(3) == null) return false
        var n = 0
        for (i in 0 until 4) {
            val x = byte()
            if (x < 0) return false
            n = (n shl 7) or (x and 0x7f)
        }
        return skip(n)
    }

    /** `read_metadata_`: one metadata block. Blocks other than STREAMINFO and SEEKTABLE are skipped. */
    private fun readMetadata(): Boolean {
        val hdr = bytes(METADATA_HEADER_LEN) ?: return false
        val isLast = hdr and 0x80000000L != 0L
        val kind = ((hdr ushr 24) and 0x7f).toInt()
        val length = (hdr and 0xffffff).toInt()
        if (kind == METADATA_STREAMINFO) {
            if (pos + STREAMINFO_LEN > data.size) {
                skip(STREAMINFO_LEN)
                return false
            }
            val r = Bits(data, pos)
            minBlocksize = r.read(16).toInt()
            maxBlocksize = r.read(16).toInt()
            minFramesize = r.read(24)
            maxFramesize = r.read(24)
            siSampleRate = r.read(20).toInt()
            siChannels = r.read(3).toInt() + 1
            siBps = r.read(5).toInt() + 1
            totalSamples0 = r.readLong(36)
            data.copyInto(md5sum, 0, pos + STREAMINFO_MD5_POS, pos + STREAMINFO_MD5_POS + FLAC_MD5_LEN)
            pos += STREAMINFO_LEN
            if (length < STREAMINFO_LEN || !skip(length - STREAMINFO_LEN)) return false
            hasStreamInfo = true
            if (md5sum.all { it == 0.toByte() }) doMd5Checking = false
        } else if (kind == METADATA_SEEKTABLE) {
            seekTable = null
            if (length > 0) {
                if (length % SEEKPOINT_LEN != 0) return false
                val points = ArrayList<SeekPoint>(length / SEEKPOINT_LEN)
                for (k in 0 until length / SEEKPOINT_LEN) {
                    val sampleNumber = bytes(8) ?: return false
                    val streamOffset = bytes(8) ?: return false
                    val frameSamples = bytes(2) ?: return false
                    points.add(SeekPoint(sampleNumber.toULong(), streamOffset.toULong(), frameSamples.toInt()))
                }
                seekTable = points.toTypedArray()
            }
        } else if (!skip(length)) {
            return false
        }
        if (isLast) {
            val p = decodePosition()
            firstFrameOffset = if (p < 0) 0 else p
            state = FlacState.SEARCH_FOR_FRAME_SYNC
        }
        return true
    }

    /** `frame_sync_`: finds the next frame sync code (false at the end of the stream). */
    private fun frameSync(client: FlacClient): Boolean {
        var first = true
        while (true) {
            val x = byte()
            if (x < 0) return false
            if (x == 0xff) {
                warmup[0] = x
                val y = byte()
                if (y < 0) return false
                if (y == 0xff) {
                    pos-- // (it may begin a sync code)
                } else if (y shr 1 == 0x7c) {
                    warmup[1] = y
                    framesync = pos
                    state = FlacState.READ_FRAME
                    return true
                }
            }
            if (first) {
                sendError(client, FlacDecodeError.LOST_SYNC)
                first = false
            }
        }
    }

    /** The header bytes read so far (for its CRC). */
    private val raw = ByteArray(16)
    private var rawLen = 0

    private fun rawAdd(x: Int) {
        raw[rawLen++] = x.toByte()
    }

    /**
     * `FLAC__bitreader_read_utf8_uint32` (wide: `_uint64`): the frame or
     * sample number of a frame header (UTF8_EOF at the end of the stream;
     * UTF8_INVALID if the coding is invalid).
     */
    private fun readUtf8(wide: Boolean): Long {
        val x = byte()
        if (x < 0) return UTF8_EOF
        rawAdd(x)
        var v: Long
        val n: Int
        if (x and 0x80 == 0) {
            v = x.toLong(); n = 0
        } else if (x and 0xc0 != 0 && x and 0x20 == 0) {
            v = (x and 0x1f).toLong(); n = 1
        } else if (x and 0xe0 != 0 && x and 0x10 == 0) {
            v = (x and 0x0f).toLong(); n = 2
        } else if (x and 0xf0 != 0 && x and 0x08 == 0) {
            v = (x and 0x07).toLong(); n = 3
        } else if (x and 0xf8 != 0 && x and 0x04 == 0) {
            v = (x and 0x03).toLong(); n = 4
        } else if (x and 0xfc != 0 && x and 0x02 == 0) {
            v = (x and 0x01).toLong(); n = 5
        } else if (wide && x and 0xfe != 0 && x and 0x01 == 0) {
            v = 0; n = 6
        } else {
            return UTF8_INVALID
        }
        for (i in 0 until n) {
            val y = byte()
            if (y < 0) return UTF8_EOF
            rawAdd(y)
            if (y and 0x80 == 0 || y and 0x40 != 0) return UTF8_INVALID
            v = (v shl 6) or (y and 0x3f).toLong()
        }
        return v
    }

    /** A bad frame header: undo puts back the last byte read (libFLAC's lookahead byte). */
    private fun badHeader(client: FlacClient, undo: Boolean): FlacFrameHeader? {
        if (undo) pos--
        sendError(client, FlacDecodeError.BAD_HEADER)
        state = FlacState.SEARCH_FOR_FRAME_SYNC
        return null
    }

    /**
     * `read_frame_header_`: the header of a frame, and its channel
     * assignment in [assignment] (null if the header is not valid;
     * [HEADER_EOF] at the end of the stream).
     */
    private fun readFrameHeader(client: FlacClient): FlacFrameHeader? {
        rawLen = 0
        rawAdd(warmup[0])
        rawAdd(warmup[1])
        val h = FlacFrameHeader()
        // (the reserved bit after the sync code)
        var unparseable = warmup[1] and 0x02 != 0
        for (i in 0 until 2) {
            val x = byte()
            if (x < 0) return HEADER_EOF
            // (a sync code cannot appear in a header)
            if (x == 0xff) return badHeader(client, true)
            rawAdd(x)
        }
        val r2 = raw[2].toInt() and 0xff
        val r3 = raw[3].toInt() and 0xff
        val bsc = r2 shr 4
        var blocksizeHint = 0
        when (bsc) {
            0 -> unparseable = true
            BLOCKSIZE_CODE_8BIT, BLOCKSIZE_CODE_16BIT -> blocksizeHint = bsc
            else -> h.blocksize = blockSizeCode(bsc).toInt()
        }
        val src = r2 and 0x0f
        var sampleRateHint = 0
        when (src) {
            0 -> if (hasStreamInfo) h.sampleRate = siSampleRate else unparseable = true
            in 1..11 -> h.sampleRate = SAMPLE_RATES[src]
            in 12..14 -> sampleRateHint = src
            else -> return badHeader(client, false)
        }
        val chc = r3 shr 4
        assignment = chc
        if (chc and 8 != 0) {
            h.channels = 2
            if (chc > CHANNELS_MID_SIDE) unparseable = true
        } else {
            h.channels = chc + 1
        }
        val ssc = (r3 and 0x0e) shr 1
        if (ssc == 0) {
            if (hasStreamInfo) h.bitsPerSample = siBps else unparseable = true
        } else if (BPS_TABLE[ssc] != 0) {
            h.bitsPerSample = BPS_TABLE[ssc]
        } else {
            unparseable = true
        }
        if (r3 and 0x01 != 0) unparseable = true
        // The frame number, or the sample number (variable block size).
        val variable = warmup[1] and 0x01 != 0 || (hasStreamInfo && minBlocksize != maxBlocksize)
        val number = readUtf8(variable)
        if (number == UTF8_EOF) return HEADER_EOF
        if (number == UTF8_INVALID || (!variable && number == 0xffffffffL)) return badHeader(client, true)
        if (blocksizeHint != 0) {
            var x = byte()
            if (x < 0) return HEADER_EOF
            rawAdd(x)
            if (blocksizeHint == BLOCKSIZE_CODE_16BIT) {
                val y = byte()
                if (y < 0) return HEADER_EOF
                rawAdd(y)
                x = (x shl 8) or y
            }
            h.blocksize = x + 1
            if (h.blocksize > 65535) return badHeader(client, true)
        }
        if (sampleRateHint != 0) {
            var x = byte()
            if (x < 0) return HEADER_EOF
            rawAdd(x)
            if (sampleRateHint != 12) {
                val y = byte()
                if (y < 0) return HEADER_EOF
                rawAdd(y)
                x = (x shl 8) or y
            }
            h.sampleRate = when (sampleRateHint) {
                12 -> x * 1000
                13 -> x
                else -> x * 10
            }
        }
        val crc = byte()
        if (crc < 0) return HEADER_EOF
        if (crc8(raw, 0, rawLen) != crc) return badHeader(client, false)
        nextFixedBlockSize = 0
        if (variable) {
            h.sampleNumber = number
        } else if (fixedBlockSize != 0) {
            h.sampleNumber = fixedBlockSize.toLong() * number
        } else if (hasStreamInfo) {
            if (minBlocksize == maxBlocksize) {
                h.sampleNumber = minBlocksize.toLong() * number
                nextFixedBlockSize = maxBlocksize
            } else {
                unparseable = true
            }
        } else if (number == 0L) {
            h.sampleNumber = 0
            nextFixedBlockSize = h.blocksize
        } else {
            h.sampleNumber = h.blocksize.toLong() * number
        }
        if (unparseable) {
            sendError(client, FlacDecodeError.UNPARSEABLE)
            state = FlacState.SEARCH_FOR_FRAME_SYNC
            return null
        }
        return h
    }

    /**
     * `read_frame_`: one frame, after its sync code. 1 if a frame was
     * decoded (and given to the client), 0 if not (the decoder searches for
     * the next frame), -1 on a fatal error.
     */
    private fun readFrame(client: FlacClient): Int {
        val start = framesync - 2
        val h = readFrameHeader(client) ?: return 0
        if (h === HEADER_EOF) return -1
        val body = frameBody(data, start, pos, h, assignment)
        for (e in body.errors) sendError(client, e)
        var got = false
        val chans = body.chans
        if (body.eof) {
            state = FlacState.END_OF_STREAM
        } else if (chans != null) {
            pos = body.end
            // Missing frames are replaced by silence.
            if (lastFrameIsSet && !isSeeking) {
                val last = lastFrame
                val end = last.sampleNumber + last.blocksize
                if (end < h.sampleNumber && last.sampleRate == h.sampleRate && last.channels == h.channels &&
                    last.bitsPerSample == h.bitsPerSample && last.blocksize >= 16
                ) {
                    var need = h.sampleNumber - end
                    need = minOf(need, 5L * last.sampleRate, 50L * last.blocksize)
                    val e = last.copy()
                    val zeros = IntArray(last.blocksize)
                    val z = Array(e.channels) { zeros }
                    while (need > 0) {
                        e.sampleNumber += e.blocksize
                        if (need < e.blocksize) e.blocksize = need.toInt()
                        need -= e.blocksize
                        samplesDecoded = e.sampleNumber + e.blocksize
                        if (!writeFrame(client, e.copy(), z, 0)) {
                            state = FlacState.ABORTED
                            return -1
                        }
                    }
                }
            }
            got = true
            if (nextFixedBlockSize != 0) fixedBlockSize = nextFixedBlockSize
            channels = h.channels
            bps = h.bitsPerSample
            samplesDecoded = h.sampleNumber + h.blocksize
            if (!writeFrame(client, h, chans, 0)) {
                state = FlacState.ABORTED
                return -1
            }
        }
        // Damaged frame: go back to just after its sync code.
        if (!got) pos = framesync + 1
        state = FlacState.SEARCH_FOR_FRAME_SYNC
        return if (got) 1 else 0
    }

    /** `write_audio_frame_to_client_`. */
    private fun writeFrame(client: FlacClient, h: FlacFrameHeader, chans: Array<IntArray>, off: Int): Boolean {
        lastFrame = h
        lastFrameIsSet = true
        if (isSeeking) {
            val thisSample = h.sampleNumber.toULong()
            val next = thisSample + h.blocksize.toULong()
            val target = targetSample
            if (thisSample <= target && target < next) {
                // the target frame: from the target sample on
                val delta = (target - thisSample).toInt()
                isSeeking = false
                val h2 = h.copy()
                h2.blocksize -= delta
                h2.sampleNumber += delta
                if (delta > 0) lastFrame = h2
                return client.write(h2, chans, off + delta)
            }
            return true
        }
        if (!hasStreamInfo) doMd5Checking = false
        if (doMd5Checking) {
            val nb = (h.bitsPerSample + 7) / 8
            val buf = ByteArray(h.blocksize * chans.size * nb)
            var k = 0
            for (i in 0 until h.blocksize) {
                for (c in chans) {
                    val v = c[off + i]
                    for (j in 0 until nb) buf[k++] = (v ushr (8 * j)).toByte()
                }
            }
            md5ctx.update(buf)
        }
        return client.write(h, chans, off)
    }

    /**
     * `FLAC__stream_decoder_seek_absolute`: seeks to sample [sample]
     * (unsigned); the client then receives the frame that holds it, from
     * that sample on.
     */
    fun seekAbsolute(sample: Long, client: FlacClient): Boolean {
        val target = sample.toULong()
        when (state) {
            FlacState.SEARCH_FOR_METADATA, FlacState.READ_METADATA, FlacState.SEARCH_FOR_FRAME_SYNC,
            FlacState.READ_FRAME, FlacState.END_OF_STREAM -> {}
            else -> return false
        }
        if (totalSamples() > 0 && target >= totalSamples().toULong()) return false
        isSeeking = true
        doMd5Checking = false
        if (!seekable) {
            isSeeking = false
            return false
        }
        if (state == FlacState.SEARCH_FOR_METADATA || state == FlacState.READ_METADATA) {
            if (!processUntilEndOfMetadata(client)) {
                isSeeking = false
                return false
            }
            if (totalSamples() > 0 && target >= totalSamples().toULong()) {
                isSeeking = false
                return false
            }
        }
        val ok = seekToSample(target, client)
        isSeeking = false
        return ok
    }

    /** `seek_to_absolute_sample_`: a bisection on the stream. */
    private fun seekToSample(target: ULong, client: FlacClient): Boolean {
        val streamLength = data.size.toULong()
        val total = totalSamples().toULong()
        val ch = if (channels == 0) siChannels else channels
        val bp = if (bps == 0) siBps else bps
        // (a 32-bit unsigned value)
        var approx: Long = if (maxFramesize > 0) {
            (maxFramesize + minFramesize) / 2 + 1
        } else if (minBlocksize == maxBlocksize && minBlocksize > 0) {
            minBlocksize.toLong() * ch * bp / 8 + 64
        } else {
            4096L * ch * bp / 8 + 64
        } and 0xffffffffL
        var lowerBound = firstFrameOffset.toULong()
        var lowerBoundSample: ULong = 0u
        var upperBound = streamLength
        var upperBoundSample = if (total > 0u) total else target
        if (state == FlacState.SEARCH_FOR_FRAME_SYNC && samplesDecoded != 0L) {
            val p = decodePosition()
            if (target < samplesDecoded.toULong()) {
                if (p >= 0) {
                    upperBound = p.toULong()
                    upperBoundSample = samplesDecoded.toULong()
                }
            } else if (p >= 0) {
                lowerBound = p.toULong()
                lowerBoundSample = samplesDecoded.toULong()
            }
        }
        val table = seekTable
        if (table != null) {
            fun usable(p: SeekPoint) =
                p.sampleNumber != SEEKPOINT_PLACEHOLDER && p.frameSamples > 0 && (total == 0uL || p.sampleNumber < total)
            var nlb = lowerBound
            var nub = upperBound
            var nlbs = lowerBoundSample
            var nubs = upperBoundSample
            val lo = table.lastOrNull { usable(it) && it.sampleNumber <= target }
            if (lo != null) {
                nlb = firstFrameOffset.toULong() + lo.streamOffset
                nlbs = lo.sampleNumber
            }
            val hi = table.firstOrNull { usable(it) && it.sampleNumber > target }
            if (hi != null) {
                nub = firstFrameOffset.toULong() + hi.streamOffset
                nubs = hi.sampleNumber
            }
            if (nub >= nlb) {
                lowerBound = nlb
                upperBound = nub
                lowerBoundSample = nlbs
                upperBoundSample = nubs
            }
        }
        if (upperBoundSample == lowerBoundSample) upperBoundSample++
        targetSample = target
        var firstSeek = true
        var seekFromLowerBound = false
        while (true) {
            if (state == FlacState.ABORTED) return false
            if (lowerBoundSample >= upperBoundSample || lowerBound > upperBound ||
                upperBound >= Long.MAX_VALUE.toULong()
            ) {
                state = FlacState.SEEK_ERROR
                return false
            }
            var p: Long = if (seekFromLowerBound) {
                lowerBound.toLong()
            } else {
                lowerBound.toLong() +
                    ((target - lowerBoundSample).toDouble() / (upperBoundSample - lowerBoundSample).toDouble() *
                        (upperBound - lowerBound).toDouble()).toLong() - approx
            }
            if (p >= upperBound.toLong()) p = upperBound.toLong() - 1
            if (p < lowerBound.toLong()) p = lowerBound.toLong()
            pos = minOf(p.toULong(), streamLength).toInt()
            flush()
            if (!processSingle(client) || state == FlacState.ABORTED || samplesDecoded == 0L) {
                // No frame could be decoded: at the end of the stream, try
                // once from the lower bound.
                if (state != FlacState.ABORTED && !seekFromLowerBound) {
                    seekFromLowerBound = true
                    continue
                }
                state = FlacState.SEEK_ERROR
                return false
            }
            seekFromLowerBound = false
            if (!isSeeking) return true
            val thisSample = lastFrame.sampleNumber.toULong()
            val bs = lastFrame.blocksize.toULong()
            if (thisSample + bs >= upperBoundSample && !firstSeek) {
                if (p == lowerBound.toLong()) {
                    state = FlacState.SEEK_ERROR
                    return false
                }
                approx = if (approx != 0L) (approx * 2) and 0xffffffffL else 16
                continue
            }
            firstSeek = false
            if (thisSample < lowerBoundSample) {
                state = FlacState.SEEK_ERROR
                return false
            }
            val here = pos.toULong()
            if (target < thisSample) {
                upperBoundSample = thisSample + bs
                upperBound = here
                approx = (2 * (upperBound.toLong() - p) / 3 + 16) and 0xffffffffL
            } else {
                lowerBoundSample = thisSample + bs
                lowerBound = here
                approx = (2 * (lowerBound.toLong() - p) / 3 + 16) and 0xffffffffL
            }
        }
    }
}

/** The result of [FlacStreamDecoder.readFrameHeader] at the end of the stream. */
private val HEADER_EOF = FlacFrameHeader()

// ---------------------------------------------------------------------------
// MD5 (RFC 1321)

private val MD5_K = intArrayOf(
    0xd76aa478.toInt(), 0xe8c7b756.toInt(), 0x242070db, 0xc1bdceee.toInt(), 0xf57c0faf.toInt(), 0x4787c62a,
    0xa8304613.toInt(), 0xfd469501.toInt(), 0x698098d8, 0x8b44f7af.toInt(), 0xffff5bb1.toInt(), 0x895cd7be.toInt(),
    0x6b901122, 0xfd987193.toInt(), 0xa679438e.toInt(), 0x49b40821, 0xf61e2562.toInt(), 0xc040b340.toInt(),
    0x265e5a51, 0xe9b6c7aa.toInt(), 0xd62f105d.toInt(), 0x02441453, 0xd8a1e681.toInt(), 0xe7d3fbc8.toInt(),
    0x21e1cde6, 0xc33707d6.toInt(), 0xf4d50d87.toInt(), 0x455a14ed, 0xa9e3e905.toInt(), 0xfcefa3f8.toInt(),
    0x676f02d9, 0x8d2a4c8a.toInt(), 0xfffa3942.toInt(), 0x8771f681.toInt(), 0x6d9d6122, 0xfde5380c.toInt(),
    0xa4beea44.toInt(), 0x4bdecfa9, 0xf6bb4b60.toInt(), 0xbebfbc70.toInt(), 0x289b7ec6, 0xeaa127fa.toInt(),
    0xd4ef3085.toInt(), 0x04881d05, 0xd9d4d039.toInt(), 0xe6db99e5.toInt(), 0x1fa27cf8, 0xc4ac5665.toInt(),
    0xf4292244.toInt(), 0x432aff97, 0xab9423a7.toInt(), 0xfc93a039.toInt(), 0x655b59c3, 0x8f0ccc92.toInt(),
    0xffeff47d.toInt(), 0x85845dd1.toInt(), 0x6fa87e4f, 0xfe2ce6e0.toInt(), 0xa3014314.toInt(), 0x4e0811a1,
    0xf7537e82.toInt(), 0xbd3af235.toInt(), 0x2ad7d2bb, 0xeb86d391.toInt(),
)

private val MD5_S = intArrayOf(
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9,
    14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15,
    21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
)

/** Size of an MD5 input block. */
private const val MD5_BLOCK = 64

/** MD5 message digest (RFC 1321). */
internal class Md5 {
    private var a = 0x67452301
    private var b = 0xefcdab89.toInt()
    private var c = 0x98badcfe.toInt()
    private var d = 0x10325476
    private var length = 0L
    private var buffer = ByteArray(MD5_BLOCK)
    private var buffered = 0
    private val m = IntArray(16)

    /** A copy of the computation so far. */
    fun copy(): Md5 {
        val r = Md5()
        r.a = a; r.b = b; r.c = c; r.d = d
        r.length = length
        r.buffer = buffer.copyOf()
        r.buffered = buffered
        return r
    }

    private fun transform(block: ByteArray, off: Int) {
        for (i in 0 until 16) {
            val p = off + 4 * i
            m[i] = (block[p].toInt() and 0xff) or ((block[p + 1].toInt() and 0xff) shl 8) or
                ((block[p + 2].toInt() and 0xff) shl 16) or ((block[p + 3].toInt() and 0xff) shl 24)
        }
        var a = this.a
        var b = this.b
        var c = this.c
        var d = this.d
        for (i in 0 until 64) {
            var f: Int
            val g: Int
            if (i < 16) {
                f = (b and c) or (b.inv() and d); g = i
            } else if (i < 32) {
                f = (d and b) or (d.inv() and c); g = (5 * i + 1) and 15
            } else if (i < 48) {
                f = b xor c xor d; g = (3 * i + 5) and 15
            } else {
                f = c xor (b or d.inv()); g = (7 * i) and 15
            }
            f = f + a + MD5_K[i] + m[g]
            a = d
            d = c
            c = b
            val s = MD5_S[i]
            b += (f shl s) or (f ushr (32 - s))
        }
        this.a += a
        this.b += b
        this.c += c
        this.d += d
    }

    /** Add len bytes of data from off. */
    fun update(data: ByteArray, off: Int = 0, len: Int = data.size - off) {
        var p = off
        var rem = len
        length += len.toLong()
        if (buffered > 0) {
            val k = minOf(MD5_BLOCK - buffered, rem)
            data.copyInto(buffer, buffered, p, p + k)
            buffered += k
            p += k
            rem -= k
            if (buffered < MD5_BLOCK) return
            transform(buffer, 0)
            buffered = 0
        }
        while (rem >= MD5_BLOCK) {
            transform(data, p)
            p += MD5_BLOCK
            rem -= MD5_BLOCK
        }
        if (rem > 0) {
            data.copyInto(buffer, 0, p, p + rem)
            buffered = rem
        }
    }

    /** Finish the computation and return the digest. */
    fun digest(): ByteArray {
        // Pad with a 1 bit and 0 bits up to 8 bytes before the end of a
        // block, then append the 64-bit message length in bits.
        val lenPos = MD5_BLOCK - 8
        val bits = length * 8
        val pad = ByteArray(MD5_BLOCK + 8)
        pad[0] = 0x80.toByte()
        val padlen = if (buffered < lenPos) lenPos - buffered else MD5_BLOCK + lenPos - buffered
        update(pad, 0, padlen)
        val lb = ByteArray(8) { (bits ushr (8 * it)).toByte() }
        update(lb)
        val out = ByteArray(FLAC_MD5_LEN)
        val v = intArrayOf(a, b, c, d)
        for (i in 0 until 4) for (k in 0 until 4) out[4 * i + k] = (v[i] ushr (8 * k)).toByte()
        return out
    }
}


// ---------------------------------------------------------------------------
// Encoder

private class BitWriter(val out: ByteVec) {
    private var acc = 0L
    private var nbits = 0

    /** Write the n (0 <= n <= 32) low bits of v. */
    fun write(v: Long, n: Int) {
        if (n == 0) return
        acc = (acc shl n) or (v and ((1L shl n) - 1))
        nbits += n
        while (nbits >= 8) {
            nbits -= 8
            out.add((acc ushr nbits).toInt())
        }
    }

    /** Write q zero bits followed by a one bit. */
    fun unary(q0: Long) {
        var q = q0
        while (!ult(q, 32)) {
            write(0, 32)
            q -= 32
        }
        write(1, q.toInt() + 1)
    }

    fun align() {
        if (nbits and 7 != 0) write(0, 8 - (nbits and 7))
    }
}

private fun putUtf8(out: ByteVec, v0: Long) {
    var v = v0
    if (v < 0x80) {
        out.add(v.toInt())
        return
    }
    val tn = intArrayOf(1, 2, 3, 4, 5, 6)
    val tlead = longArrayOf(0xC0, 0xE0, 0xF0, 0xF8, 0xFC, 0xFE)
    val tmax = longArrayOf(0x7FF, 0xFFFF, 0x1FFFFF, 0x3FFFFFF, 0x7FFFFFFF, 0xFFFFFFFFFL)
    for (t in 0 until 6) {
        if (v <= tmax[t]) {
            val n = tn[t]
            val b = ByteArray(7)
            for (i in n downTo 1) {
                b[i] = (0x80L or (v and 0x3F)).toByte()
                v = v ushr 6
            }
            b[0] = (tlead[t] or v).toByte()
            out.addAll(b, 0, n + 1)
            return
        }
    }
}

private class Partition(val cost: Long, val porder: Int, val params: IntArray)

/**
 * Choose a partition order and Rice parameters for folded residuals (as
 * `_best_partition()` in `_flac.py`). For each partition order, and each
 * partition, the parameter k is chosen among those near log2 of the mean,
 * with the cost (in bits) sum(u >> k) + n * (k + 1). Values are unsigned
 * 64-bit integers held in Longs.
 */
private fun bestPartition(u: LongArray, order: Int, blocksize: Long, maxk: Int): Partition {
    // The highest valid partition order
    var maxorder = 0
    for (porder in 1 until 7) {
        val nparts = 1L shl porder
        if (blocksize % nparts != 0L) break
        if ((blocksize shr porder) <= order) break
        maxorder = porder
    }
    val nk = 32 // k = 0 .. maxk (<= 30)
    val nfine = 1 shl maxorder
    val fsize = blocksize shr maxorder
    val sums = LongArray(nfine * nk)
    val counts = LongArray(nfine)
    var start = 0
    for (p in 0 until nfine) {
        var n = if (p == 0) fsize - order else fsize
        if (n < 0) n = 0
        val base = p * nk
        for (i in start until start + n.toInt()) {
            var v = u[i]
            var k = 0
            while (v != 0L && k <= maxk) {
                sums[base + k] += v
                k++
                v = v ushr 1
            }
        }
        counts[p] = n
        start += n.toInt()
    }

    var best: Partition? = null
    val acc = LongArray(nk)
    for (porder in 0..maxorder) {
        val nparts = 1 shl porder
        val group = 1 shl (maxorder - porder) // fine partitions per part
        var cost = 6L
        val params = IntArray(nparts)
        for (p in 0 until nparts) {
            var n = 0L
            acc.fill(0)
            for (q in p * group until (p + 1) * group) {
                n += counts[q]
                val base = q * nk
                for (k in 0..maxk) acc[k] += sums[base + k]
            }
            if (n == 0L) {
                params[p] = 0
                cost += 4
                continue
            }
            val mean = (acc[0].toULong() / n.toULong()).toLong()
            val k0 = if (mean != 0L) bitLength(mean) - 1 else 0
            val lo = minOf(maxOf(k0 - 1, 0), maxk)
            val hi = minOf(k0 + 2, maxk)
            var bk = -1
            var bc = 0L
            for (k in lo..hi) {
                val c = acc[k] + n * (k + 1)
                if (bk < 0 || ult(c, bc)) {
                    bk = k
                    bc = c
                }
            }
            params[p] = bk
            cost += 4 + bc
        }
        if (best == null || ult(cost, best.cost)) best = Partition(cost, porder, params)
    }
    return best!!
}

private fun encodeSubframe(bw: BitWriter, x: IntArray, n: Int, bps: Int) {
    var constant = true
    for (i in 1 until n) if (x[i] != x[0]) {
        constant = false
        break
    }
    // Each subframe header: a zero bit, the 6-bit type, the wasted-bits flag (0).
    if (constant) {
        bw.write(0, 1)
        bw.write(SUBFRAME_CONSTANT.toLong(), 6)
        bw.write(0, 1)
        bw.write(x[0].toLong(), bps)
        return
    }
    val maxk = (1 shl RICE2_PARAM_BITS) - 2 // the largest non-escape parameter
    var have = false
    var bestCost = 0L
    var bestOrder = 0
    var bestU = LongArray(0)
    var u = LongArray(n)
    var bestBp: Partition? = null
    val maxorder = minOf(n - 1, MAX_FIXED_ORDER)
    for (order in 0..maxorder) {
        var k = 0
        for (i in order until n) {
            val r: Long = when (order) {
                0 -> x[i].toLong()
                1 -> x[i].toLong() - x[i - 1]
                2 -> x[i].toLong() - 2L * x[i - 1] + x[i - 2]
                3 -> x[i].toLong() - 3L * x[i - 1] + 3L * x[i - 2] - x[i - 3]
                else -> x[i].toLong() - 4L * x[i - 1] + 6L * x[i - 2] - 4L * x[i - 3] + x[i - 4]
            }
            u[k++] = if (r >= 0) r shl 1 else ((-r) shl 1) - 1
        }
        val bp = bestPartition(u, order, n.toLong(), maxk)
        val cost = order.toLong() * bps + 2 + bp.cost
        if (!have || ult(cost, bestCost)) {
            have = true
            bestCost = cost
            bestOrder = order
            val t = bestU
            bestU = u
            u = if (t.size == n) t else LongArray(n)
            bestBp = bp
        }
    }
    if (!have || !ult(bestCost, n.toLong() * bps)) {
        bw.write(0, 1)
        bw.write(SUBFRAME_VERBATIM.toLong(), 6)
        bw.write(0, 1)
        for (i in 0 until n) bw.write(x[i].toLong(), bps)
        return
    }
    val bp = bestBp!!
    val order = bestOrder
    bw.write(0, 1)
    bw.write((SUBFRAME_FIXED + order).toLong(), 6)
    bw.write(0, 1)
    for (i in 0 until order) bw.write(x[i].toLong(), bps)
    var maxparam = 0
    for (k in bp.params) if (k > maxparam) maxparam = k
    val method: Int
    val pbits: Int
    if (maxparam < (1 shl RICE_PARAM_BITS) - 1) {
        method = 0; pbits = RICE_PARAM_BITS
    } else {
        method = 1; pbits = RICE2_PARAM_BITS
    }
    bw.write(method.toLong(), 2)
    bw.write(bp.porder.toLong(), PARTITION_ORDER_BITS)
    val psize = n.toLong() shr bp.porder
    var start = 0
    for (p in bp.params.indices) {
        val k = bp.params[p]
        val cnt = if (p == 0) psize - order else psize
        bw.write(k.toLong(), pbits)
        var i = 0
        while (i < cnt) {
            val v = bestU[start + i]
            bw.unary(v ushr k)
            if (k != 0) bw.write(v, k)
            i++
        }
        if (cnt > 0) start += cnt.toInt()
    }
}

private fun makeStreaminfo(minfs: Long, maxfs: Long, nsig: Int, bps: Int, total: Long, md5: ByteArray): ByteArray {
    val out = ByteVec(STREAMINFO_LEN)
    val bw = BitWriter(out)
    bw.write(FLAC_BLOCKSIZE.toLong(), 16)
    bw.write(FLAC_BLOCKSIZE.toLong(), 16)
    bw.write(minfs, 24)
    bw.write(maxfs, 24)
    bw.write(SAMPLE_RATE, 20)
    bw.write((nsig - 1).toLong(), 3)
    bw.write((bps - 1).toLong(), 5)
    bw.write(total ushr 32, 4)
    bw.write(total and 0xFFFFFFFFL, 32)
    out.addAll(md5)
    return out.toByteArray()
}

/**
 * Encoder for a signal group of [nsig] signals with [spf] samples per frame
 * and [bps] (8, 16 or 24) bits per sample.
 */
internal class FlacEncoder(private val nsig: Int, private val bps: Int, private val spf: Int) {
    private val chans = Array(maxOf(nsig, 0)) { IntVec(FLAC_BLOCKSIZE + 64) }
    private val pending = IntArray(maxOf(nsig, 0) * maxOf(spf, 0))
    private var npending = 0
    private var frameNo = 0L
    private var total = 0L
    private var minfs = 0L
    private var maxfs = 0L
    private var haveMinfs = false
    private val md5 = Md5()

    /**
     * The stream header: `fLaC`, a STREAMINFO block with an unknown total
     * number of samples, and a VORBIS_COMMENT block (vendor `wfdb-x`). The
     * final STREAMINFO ([streaminfo]) is written later at offset
     * [FLAC_STREAMINFO_POS].
     */
    fun header(): ByteArray {
        val vlen = VENDOR.size
        val vc = ByteVec(16)
        for (i in 0 until 4) vc.add(vlen ushr (8 * i))
        vc.addAll(VENDOR)
        vc.fill(0, 4)
        val hdr = ByteVec(64)
        hdr.addAll(MARKER)
        hdr.add(METADATA_STREAMINFO)
        hdr.add(0)
        hdr.add(0)
        hdr.add(STREAMINFO_LEN)
        hdr.addAll(makeStreaminfo(if (haveMinfs) minfs else 0, maxfs, nsig, bps, TOTAL_UNKNOWN, ByteArray(FLAC_MD5_LEN)))
        hdr.add(METADATA_LAST or METADATA_VORBIS_COMMENT)
        hdr.add((vc.size shr 16) and 0xFF)
        hdr.add((vc.size shr 8) and 0xFF)
        hdr.add(vc.size and 0xFF)
        hdr.addAll(vc.toByteArray())
        return hdr.toByteArray()
    }

    /**
     * Append one sample (in WFDB frame order: spf samples of signal 0, then
     * spf samples of signal 1, ...), wrapped to bps bits. Encoded frames, if
     * any, are appended to [out].
     */
    fun put(v: Int, out: ByteVec) {
        val w: Int = if (bps >= 32) {
            v
        } else {
            val mask = (1L shl bps) - 1
            val half = 1L shl (bps - 1)
            ((((v.toLong() and 0xFFFFFFFFL) + half) and mask) - half).toInt()
        }
        pending[npending++] = w
        if (npending == nsig * spf) {
            for (c in chans.indices) {
                val ch = chans[c]
                ch.ensure(ch.size + spf)
                pending.copyInto(ch.a, ch.size, c * spf, (c + 1) * spf)
                ch.size += spf
            }
            npending = 0
            if (chans[0].size >= FLAC_BLOCKSIZE) writeBlock(FLAC_BLOCKSIZE, out)
        }
    }

    /** Encode the remaining samples (appended to [out]). */
    fun finish(out: ByteVec) {
        while (chans.isNotEmpty() && chans[0].size > 0) {
            val n = minOf(chans[0].size, FLAC_BLOCKSIZE)
            writeBlock(n, out)
        }
    }

    /** The final 34-byte STREAMINFO block body (after [finish]). */
    fun streaminfo(): ByteArray {
        val digest = md5.copy().digest()
        return makeStreaminfo(if (haveMinfs) minfs else 0, maxfs, nsig, bps, total, digest)
    }

    private fun writeBlock(n: Int, out: ByteVec) {
        val block = Array(chans.size) { c -> chans[c].a.copyOf(n) }
        for (c in chans) c.drop(n)
        // MD5 of the interleaved samples
        val nb = (bps + 7) / 8
        val inter = ByteArray(n * nb * block.size)
        var k = 0
        for (i in 0 until n) {
            for (c in block) {
                val v = c[i]
                for (j in 0 until nb) inter[k++] = (v ushr (8 * j)).toByte()
            }
        }
        md5.update(inter)

        val frame = ByteVec(n * nb * block.size + 64)
        val bsc = if (n == FLAC_BLOCKSIZE) BLOCKSIZE_CODE_4096 else if (n <= 256) BLOCKSIZE_CODE_8BIT else BLOCKSIZE_CODE_16BIT
        val hb = BitWriter(frame)
        hb.write(FRAME_SYNC, 15)
        hb.write(0, 1) // fixed block size
        hb.write(bsc.toLong(), 4)
        hb.write(SAMPLE_RATE_CODE, 4)
        hb.write((nsig - 1).toLong(), 4) // independent channels
        val ssc = when (bps) { // index in BPS_TABLE
            8 -> 1L
            16 -> 4L
            24 -> 6L
            else -> 0L
        }
        hb.write(ssc, 3)
        hb.write(0, 1)
        putUtf8(frame, frameNo)
        if (bsc == BLOCKSIZE_CODE_8BIT) {
            frame.add(n - 1)
        } else if (bsc == BLOCKSIZE_CODE_16BIT) {
            frame.add(((n - 1) shr 8) and 0xFF)
            frame.add((n - 1) and 0xFF)
        }
        frame.add(crc8(frame.bytes, 0, frame.size))
        val bw = BitWriter(frame)
        for (c in block) encodeSubframe(bw, c, n, bps)
        bw.align()
        val c16 = crc16(frame.bytes, 0, frame.size)
        frame.add(c16 shr 8)
        frame.add(c16 and 0xFF)
        out.addAll(frame.bytes, 0, frame.size)
        frameNo++
        total += n.toLong()
        val fs = frame.size.toLong()
        if (!haveMinfs || fs < minfs) minfs = fs
        haveMinfs = true
        if (fs > maxfs) maxfs = fs
    }
}
