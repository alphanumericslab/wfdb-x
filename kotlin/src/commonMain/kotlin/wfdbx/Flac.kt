// FLAC decoder and encoder for the FLAC signal formats 508, 516 and 524
// (port of rust/src/flac.rs, itself a port of cpp/src/flac.cpp).
//
// The C library uses libFLAC for these formats; wfdb-x implements, without
// external libraries, a complete FLAC decoder (all subframe types, fixed and
// LPC predictors, Rice and Rice2 partitions with escape codes, wasted bits,
// stereo decorrelation, variable block sizes, CRC verification) and a
// lossless encoder (fixed predictors and Rice coding). The encoder writes
// exactly the bytes written by the Python, C++ and Rust implementations of
// wfdb-x (standard FLAC streams; their compressed bytes differ from those
// written by libFLAC, whose output depends on its version, but the decoded
// samples are identical).
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

/** Decoding status (the libFLAC error that would have been reported). */
internal enum class FlacStatus {
    /** No error. */
    OK,

    /** Lost sync. */
    SYNC,

    /** Invalid frame header. */
    HEADER,

    /** Frame CRC mismatch. */
    CRC,

    /** Unsupported format. */
    UNPARSEABLE,

    /** Unexpected end of stream. */
    EOF,

    /** Error in the stream header or metadata. */
    META,

    /** Wrong number of channels or resolution (see [FlacDecoded.errorMessage]). */
    WFDB,
}

/** The result of [flacDecode]. */
internal class FlacDecoded {
    /** Decoding status. */
    var status = FlacStatus.OK

    /** Number of channels, from STREAMINFO. */
    var channels = 0

    /** Bits per sample, from STREAMINFO. */
    var bps = 0

    /** Samples, one array per channel (empty on error). */
    var chans: Array<IntArray> = emptyArray()

    /** The end of each frame (FLAC block), in samples per channel. */
    var blockEnds: LongArray = LongArray(0)

    /** Is there a STREAMINFO block (with an MD5 signature)? */
    var hasMd5 = false

    /** MD5 signature from STREAMINFO. */
    var md5 = ByteArray(FLAC_MD5_LEN)

    /** With status WFDB: the message that the C library reports with wfdb_error (the caller prints it). */
    var errorMessage: ByteArray? = null
}

/** A decoding error (the status that ends decoding). */
private class FlacError(val status: FlacStatus) : Exception()

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

/** A growable array of 64-bit values. */
private class LongVec(capacity: Int) {
    var a = LongArray(if (capacity < 1) 1 else capacity)
    var size = 0

    fun add(v: Long) {
        if (size == a.size) a = a.copyOf(a.size * 2)
        a[size++] = v
    }
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
            if (n < 0) throw FlacError(FlacStatus.UNPARSEABLE)
            return 0
        }
        if (pos + n > end) throw FlacError(FlacStatus.EOF)
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
            if (b >= d.size) throw FlacError(FlacStatus.EOF)
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

    fun align() {
        pos = (pos + 7) and 7L.inv()
    }

    fun bytePos(): Int = (pos ushr 3).toInt()
}

private fun readUtf8(bits: Bits): Long {
    val x = bits.read(8)
    if (x < 0x80) return x
    var v: Long
    val n: Int
    if ((x and 0xE0) == 0xC0L) {
        v = x and 0x1F; n = 1
    } else if ((x and 0xF0) == 0xE0L) {
        v = x and 0x0F; n = 2
    } else if ((x and 0xF8) == 0xF0L) {
        v = x and 0x07; n = 3
    } else if ((x and 0xFC) == 0xF8L) {
        v = x and 0x03; n = 4
    } else if ((x and 0xFE) == 0xFCL) {
        v = x and 0x01; n = 5
    } else if (x == 0xFEL) {
        v = 0; n = 6
    } else {
        throw FlacError(FlacStatus.HEADER)
    }
    for (i in 0 until n) {
        val y = bits.read(8)
        if ((y and 0xC0) != 0x80L) throw FlacError(FlacStatus.HEADER)
        v = (v shl 6) or (y and 0x3F)
    }
    return v
}

private fun unfold(u: Long): Long = if (u and 1L != 0L) -(u ushr 1) - 1 else u ushr 1

/** Reads the residuals of a subframe into out, from position at; returns the new position. */
private fun readResidual(bits: Bits, blocksize: Long, order: Int, out: LongArray, at: Int): Int {
    var k0 = at
    val method = bits.read(2).toInt()
    if (method > 1) throw FlacError(FlacStatus.UNPARSEABLE)
    val pbits = if (method == 0) RICE_PARAM_BITS else RICE2_PARAM_BITS
    val esc = (1L shl pbits) - 1
    val porder = bits.read(PARTITION_ORDER_BITS).toInt()
    val nparts = 1L shl porder
    if (blocksize % nparts != 0L) throw FlacError(FlacStatus.UNPARSEABLE)
    val psize = blocksize shr porder
    if (porder > 0 && psize < order) throw FlacError(FlacStatus.UNPARSEABLE)
    for (part in 0 until nparts) {
        val n = if (part == 0L) psize - order else psize
        val k = bits.read(pbits)
        if (k == esc) {
            val nb = bits.read(5).toInt()
            var i = 0L
            while (i < n) {
                out[k0++] = bits.readSigned(nb)
                i++
            }
        } else {
            val kk = k.toInt()
            var i = 0L
            while (i < n) {
                out[k0++] = unfold(bits.rice(kk))
                i++
            }
        }
    }
    return k0
}

private fun decodeSubframe(bits: Bits, blocksize: Long, bps0: Int): LongArray {
    var bps = bps0
    if (bits.read(1) != 0L) throw FlacError(FlacStatus.UNPARSEABLE)
    val t = bits.read(6).toInt()
    var wasted = 0
    if (bits.read(1) != 0L) {
        wasted = bits.unary().toInt() + 1
        bps -= wasted
    }
    val bs = if (blocksize < 0) 0 else blocksize.toInt()
    val s: LongArray
    if (t == SUBFRAME_CONSTANT) {
        val v = bits.readSigned(bps)
        s = LongArray(bs) { v }
    } else if (t == SUBFRAME_VERBATIM) {
        s = LongArray(bs)
        for (i in 0 until bs) s[i] = bits.readSigned(bps)
    } else if (t >= SUBFRAME_FIXED && t <= SUBFRAME_FIXED + MAX_FIXED_ORDER) {
        val order = t - SUBFRAME_FIXED
        s = LongArray(maxOf(bs, order))
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
    } else if (t >= SUBFRAME_LPC) {
        val order = t - SUBFRAME_LPC + 1
        s = LongArray(maxOf(bs, order))
        for (i in 0 until order) s[i] = bits.readSigned(bps)
        val prec = bits.read(4).toInt() + 1
        if (prec == 16) throw FlacError(FlacStatus.UNPARSEABLE) // (precision code 15 is invalid)
        val shift = bits.readSigned(5).toInt()
        val coefs = LongArray(MAX_LPC_ORDER)
        for (j in 0 until order) coefs[j] = bits.readSigned(prec)
        val n = readResidual(bits, blocksize, order, s, order)
        if (shift < 0) throw FlacError(FlacStatus.UNPARSEABLE)
        for (i in order until n) {
            var acc = 0L
            // coefs[0] applies to the most recent sample
            for (j in 0 until order) acc += coefs[j] * s[i - 1 - j]
            s[i] = s[i] + (acc shr shift)
        }
    } else {
        throw FlacError(FlacStatus.UNPARSEABLE)
    }
    if (wasted != 0) for (i in s.indices) s[i] = s[i] shl wasted
    return s
}

/** Bits per sample of the frame header sample size codes (0: as in STREAMINFO; 3: reserved). */
private val BPS_TABLE = intArrayOf(0, 8, 12, 0, 16, 20, 24, 32)

/** The block size given by a frame header block size code (other than 0, 6 and 7). */
private fun blockSizeCode(bsc: Int): Long = when (bsc) {
    1 -> 192
    2 -> 576
    3 -> 1152
    4 -> 2304
    5 -> 4608
    else -> 256L shl (bsc - 8) // 8 .. 15
}

private class Frame(val chans: Array<LongArray>, val bps: Int, val next: Int)

/** Decode one frame at byte offset pos. */
private fun decodeFrame(data: ByteArray, pos: Int, siBps: Int): Frame {
    val n = data.size
    if (pos + 2 > n || (((data[pos].toInt() and 0xff) shl 8 or (data[pos + 1].toInt() and 0xff)) ushr 1).toLong() != FRAME_SYNC) {
        throw FlacError(FlacStatus.SYNC)
    }
    val bits = Bits(data, pos)
    bits.read(15) // FRAME_SYNC
    bits.read(1) // blocking strategy
    val bsc = bits.read(4).toInt()
    val src = bits.read(4).toInt()
    val chc = bits.read(4).toInt()
    val ssc = bits.read(3).toInt()
    if (bits.read(1) != 0L) throw FlacError(FlacStatus.HEADER)
    readUtf8(bits)
    val blocksize = when (bsc) {
        0 -> throw FlacError(FlacStatus.HEADER)
        BLOCKSIZE_CODE_8BIT -> bits.read(8) + 1
        BLOCKSIZE_CODE_16BIT -> bits.read(16) + 1
        else -> blockSizeCode(bsc)
    }
    // Sample rate codes 12 to 14: the rate follows in 8 or 16 bits; 15 is invalid.
    if (src == 12) {
        bits.read(8)
    } else if (src == 13 || src == 14) {
        bits.read(16)
    } else if (src == 15) {
        throw FlacError(FlacStatus.HEADER)
    }
    val bps = if (ssc == 0) siBps else if (BPS_TABLE[ssc] != 0) BPS_TABLE[ssc] else throw FlacError(FlacStatus.HEADER)
    val hend = bits.bytePos()
    val crc = bits.read(8).toInt()
    if (crc8(data, pos, hend) != crc) throw FlacError(FlacStatus.HEADER)
    val chans: Array<LongArray>
    if (chc < CHANNELS_LEFT_SIDE) {
        chans = Array(chc + 1) { LongArray(0) }
        for (c in 0..chc) chans[c] = decodeSubframe(bits, blocksize, bps)
    } else if (chc <= CHANNELS_MID_SIDE) {
        if (chc == CHANNELS_LEFT_SIDE) {
            // left/side
            val a = decodeSubframe(bits, blocksize, bps)
            val sd = decodeSubframe(bits, blocksize, bps + 1)
            val m = minOf(a.size, sd.size)
            val b = LongArray(m) { a[it] - sd[it] }
            chans = arrayOf(a, b)
        } else if (chc == CHANNELS_SIDE_RIGHT) {
            // side/right
            val sd = decodeSubframe(bits, blocksize, bps + 1)
            val b = decodeSubframe(bits, blocksize, bps)
            val m = minOf(sd.size, b.size)
            val a = LongArray(m) { sd[it] + b[it] }
            chans = arrayOf(a, b)
        } else {
            // mid/side
            val mid = decodeSubframe(bits, blocksize, bps)
            val sd = decodeSubframe(bits, blocksize, bps + 1)
            val m = minOf(mid.size, sd.size)
            val le = LongArray(m)
            val ri = LongArray(m)
            for (i in 0 until m) {
                val x = (mid[i] shl 1) or (sd[i] and 1L)
                val y = sd[i]
                le[i] = (x + y) shr 1
                ri[i] = (x - y) shr 1
            }
            chans = arrayOf(le, ri)
        }
    } else {
        throw FlacError(FlacStatus.HEADER)
    }
    bits.align()
    val fend = bits.bytePos()
    val c16 = bits.read(16).toInt()
    if (crc16(data, pos, fend) != c16) throw FlacError(FlacStatus.CRC)
    return Frame(chans, bps, bits.bytePos())
}

private fun decodeInner(data: ByteArray, expectNsig: Int, expectBps: Int, result: FlacDecoded) {
    val n = data.size
    // Errors in the stream header and metadata are reported by libFLAC
    // without invoking its error callback ('meta' status).
    if (n < MARKER.size || !data.copyOf(MARKER.size).contentEquals(MARKER)) throw FlacError(FlacStatus.META)
    var pos = MARKER.size
    var siBps = 0
    var siCh = 0
    while (true) {
        if (pos + METADATA_HEADER_LEN > n) throw FlacError(FlacStatus.META)
        val hb = data[pos].toInt() and 0xff
        val ln = ((data[pos + 1].toInt() and 0xff) shl 16) or ((data[pos + 2].toInt() and 0xff) shl 8) or
            (data[pos + 3].toInt() and 0xff)
        val body = pos + METADATA_HEADER_LEN
        if (body.toLong() + ln > n) throw FlacError(FlacStatus.META)
        if ((hb and METADATA_LAST.inv()) == METADATA_STREAMINFO) {
            if (ln < STREAMINFO_LEN) throw FlacError(FlacStatus.META)
            val b = Bits(data, body)
            b.read(16)
            b.read(16)
            b.read(24)
            b.read(24)
            b.read(20)
            siCh = b.read(3).toInt() + 1
            siBps = b.read(5).toInt() + 1
            b.read(36)
            result.hasMd5 = true
            val md5 = body + STREAMINFO_MD5_POS
            data.copyInto(result.md5, 0, md5, md5 + FLAC_MD5_LEN)
        }
        pos = body + ln
        if (hb and METADATA_LAST != 0) break
    }
    result.channels = siCh
    result.bps = siBps
    val nch = maxOf(siCh, 1)
    val chans = Array(nch) { IntVec(1024) }
    val ends = LongVec(16)
    while (pos < n) {
        val fr: Frame
        try {
            fr = decodeFrame(data, pos, siBps)
        } catch (e: FlacError) {
            if (e.status == FlacStatus.SYNC) {
                var allZero = true
                for (i in pos until n) if (data[i] != 0.toByte()) {
                    allZero = false
                    break
                }
                if (allZero) break
            }
            throw e
        }
        pos = fr.next
        if (expectNsig > 0 && fr.chans.size != expectNsig) {
            result.errorMessage = "getvec: wrong number of signals in FLAC signal file\n".latin1()
            throw FlacError(FlacStatus.WFDB)
        }
        if (expectNsig > 0 && fr.bps > expectBps) {
            result.errorMessage = "getvec: wrong sample resolution in FLAC signal file\n".latin1()
            throw FlacError(FlacStatus.WFDB)
        }
        val m = minOf(nch, fr.chans.size)
        for (c in 0 until m) {
            val src = fr.chans[c]
            val dst = chans[c]
            dst.ensure(dst.size + src.size)
            for (x in src) dst.a[dst.size++] = x.toInt()
        }
        if (fr.chans.isNotEmpty()) ends.add(chans[0].size.toLong())
    }
    result.chans = Array(nch) { chans[it].toArray() }
    result.blockEnds = ends.a.copyOf(ends.size)
}

/**
 * Decode a complete FLAC stream.
 *
 * If [expectNsig] > 0, a frame with a different number of channels, or with
 * more than [expectBps] bits per sample, ends decoding with status WFDB and
 * the message the C library reports in errorMessage; the caller reports it.
 * Other errors are not reported (the status says what happened). Trailing
 * zero bytes after the last frame are ignored.
 */
internal fun flacDecode(data: ByteArray, expectNsig: Int, expectBps: Int): FlacDecoded {
    val result = FlacDecoded()
    try {
        decodeInner(data, expectNsig, expectBps, result)
    } catch (e: FlacError) {
        result.status = e.status
        result.chans = emptyArray()
    }
    return result
}

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

/**
 * The MD5 signature of decoded samples, as computed by libFLAC: the samples
 * interleaved, each stored in (bps+7)/8 little-endian bytes.
 */
internal fun flacSamplesMd5(chans: Array<IntArray>, bps: Int): ByteArray {
    val chunk = 1 shl 16 // bytes passed to the digest at a time
    val md5 = Md5()
    val nb = (bps + 7) / 8
    val n = if (chans.isEmpty()) 0 else chans[0].size
    val buf = ByteArray(chunk + nb * chans.size)
    var k = 0
    for (i in 0 until n) {
        for (c in chans) {
            val v = c[i]
            for (j in 0 until nb) buf[k++] = (v ushr (8 * j)).toByte()
        }
        if (k >= chunk) {
            md5.update(buf, 0, k)
            k = 0
        }
    }
    md5.update(buf, 0, k)
    return md5.digest()
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
