// Tests of the FLAC decoder and encoder (port of the unit tests of
// rust/src/flac.rs): the test records of tests/data decode to the samples
// libFLAC gives, and the encoder writes exactly the bytes written by the
// Python, C++ and Rust implementations (expected sizes and MD5 digests
// computed by the Python script that generated the test signals).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It tests wfdb-x; it has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

import wfdbx.cstd.ByteVec
import wfdbx.cstd.indexOf
import wfdbx.cstd.latin1
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class FlacTest {
    private fun md5Hex(data: ByteArray): String {
        val m = Md5()
        m.update(data)
        return hex(m.digest())
    }

    /** MD5 of the samples interleaved, each as a 32-bit little-endian integer. */
    private fun samplesDigest(chans: Array<IntArray>): String {
        val m = Md5()
        val n = if (chans.isEmpty()) 0 else chans[0].size
        val b = ByteArray(4)
        for (i in 0 until n) for (c in chans) {
            for (k in 0 until 4) b[k] = (c[i] ushr (8 * k)).toByte()
            m.update(b)
        }
        return hex(m.digest())
    }

    private class RecordCase(val name: String, val channels: Int, val bps: Int, val nsamp: Int, val digest: String, val first: IntArray, val last: Int)

    private val records = listOf(
        RecordCase("flac8", 2, 8, 5000, "505da209b1473fbc46a21feb7833b00d", intArrayOf(-31, -42, -13), -86),
        RecordCase("flac16", 3, 16, 9000, "c7031b07326efeaf5de0938839eccfd4", intArrayOf(-31, -58, -28), 1335),
        RecordCase("flac24", 1, 24, 4500, "009556de1b80833f7f1d21d99c817729", intArrayOf(-17, -4, 29), 8388435),
        RecordCase("flacmf", 2, 16, 8642, "76ee297c139a1538a9fd7f43d5398659", intArrayOf(-300, 700, -297), 2979),
    )

    /** Test signals for the encoder (the same as those of the Python script that computed the expected digests). */
    private fun gen(vid: Int, nsig: Int, bps: Int, spf: Int, nframes: Int, kinds: IntArray): IntArray {
        var state = (12345 + vid).toUInt()
        val out = IntArray(nsig * spf * nframes)
        var o = 0
        val half = 1L shl (bps - 1)
        for (f in 0 until nframes) for (s in 0 until nsig) for (k in 0 until spf) {
            state = state * 1664525u + 1013904223u
            val t = f.toLong() * spf + k
            val v: Long = when (kinds[s]) {
                0 -> {
                    val p = 397L
                    val m = t % p - p / 2
                    val tri = if (m < 0) -m else m
                    tri * (half / 256) - half / 2 + ((state shr 20) % 7u).toLong() - 3
                }
                1 -> ((state shr 8) and ((1u shl bps) - 1u)).toLong() - half
                2 -> if (t < 5000) 17 else (t - 5000) * 3 - 100
                else -> state.toInt().toLong()
            }
            out[o++] = v.toInt()
        }
        return out
    }

    private class EncoderCase(
        val vid: Int, val nsig: Int, val bps: Int, val spf: Int, val nframes: Int, val kinds: IntArray,
        val size: Int, val digest: String, val sum: UInt,
    )

    private val encoderCases = listOf(
        EncoderCase(0, 2, 16, 1, 10000, intArrayOf(0, 1), 26203, "5495badb24f7c490c5484be5441c2f76", 4257896572u),
        EncoderCase(1, 1, 24, 2, 6000, intArrayOf(0), 11846, "40596f848ca112518ce4d7c573aa9622", 1739685865u),
        EncoderCase(2, 3, 8, 1, 7000, intArrayOf(2, 0, 1), 11704, "0efb1695c22420deb64837c433e39c61", 5422484u),
        EncoderCase(3, 1, 16, 1, 100, intArrayOf(0), 130, "109b65398fce5e82b3817c267a879467", 262406u),
        EncoderCase(4, 1, 16, 1, 300, intArrayOf(3), 671, "459bc9a342c66d4d1c720002dd7670e2", 3379252398u),
        EncoderCase(5, 2, 24, 3, 3000, intArrayOf(1, 2), 27782, "25779b07efedeaadef4350bbb5148b01", 4163323067u),
    )

    /** Encode a complete stream as the WFDB library writes it (the final STREAMINFO block replaces the provisional one at offset 8). */
    private fun encode(nsig: Int, bps: Int, spf: Int, x: IntArray): ByteArray {
        val enc = FlacEncoder(nsig, bps, spf)
        val out = ByteVec()
        out.addAll(enc.header())
        for (v in x) enc.put(v, out)
        enc.finish(out)
        val b = out.toByteArray()
        val si = enc.streaminfo()
        si.copyInto(b, 8)
        return b
    }

    private fun wrap(v: Int, bps: Int): Int {
        val mask = (1L shl bps) - 1
        val half = 1L shl (bps - 1)
        return ((((v.toLong() and 0xFFFFFFFFL) + half) and mask) - half).toInt()
    }

    @Test
    fun md5Vectors() {
        assertEquals("d41d8cd98f00b204e9800998ecf8427e", md5Hex(ByteArray(0)))
        assertEquals("900150983cd24fb0d6963f7d28e17f72", md5Hex("abc".latin1()))
        val v = ByteArray(5 * 256) { it.toByte() }
        assertEquals("82829f1f3f2bb0f18b25f278e5bba8bd", md5Hex(v))
        // the same data in pieces of various sizes
        val m = Md5()
        var pos = 0
        var step = 1
        while (pos < v.size) {
            val k = minOf(step, v.size - pos)
            m.update(v, pos, k)
            pos += k
            step = step * 3 + 1
        }
        assertEquals("82829f1f3f2bb0f18b25f278e5bba8bd", hex(m.digest()))
    }

    @Test
    fun flacDecodeRecords() {
        for (rc in records) {
            val data = readFile("${testDataDir()}/${rc.name}.dat")!!
            val d = flacDecode(data, 0, 0)
            assertEquals(FlacStatus.OK, d.status, rc.name)
            assertEquals(rc.channels, d.channels)
            assertEquals(rc.bps, d.bps)
            assertEquals(rc.channels, d.chans.size)
            assertEquals(rc.nsamp, d.chans[0].size)
            assertEquals(rc.digest, samplesDigest(d.chans))
            assertContentEquals(rc.first, d.chans[0].copyOf(3))
            assertEquals(rc.last, d.chans.last().last())
            // The MD5 signature in STREAMINFO matches the decoded samples.
            assertTrue(d.hasMd5)
            assertContentEquals(d.md5, flacSamplesMd5(d.chans, d.bps))
            // Decoding with the expected numbers of signals and bits
            val d2 = flacDecode(data, rc.channels, rc.bps)
            assertEquals(FlacStatus.OK, d2.status)
            for (c in d.chans.indices) assertContentEquals(d.chans[c], d2.chans[c])
            // Trailing zero bytes are ignored.
            val d3 = flacDecode(data.copyOf(data.size + 100), 0, 0)
            assertEquals(FlacStatus.OK, d3.status)
            for (c in d.chans.indices) assertContentEquals(d.chans[c], d3.chans[c])
            // A truncated stream cannot be decoded.
            assertNotEquals(FlacStatus.OK, flacDecode(data.copyOf(data.size - 3), 0, 0).status)
            // Neither can a stream with a corrupted frame.
            val bad = data.copyOf()
            val mid = bad.size / 2
            bad[mid] = (bad[mid].toInt() xor 0x10).toByte()
            assertNotEquals(FlacStatus.OK, flacDecode(bad, 0, 0).status)
            // nor something that is not a FLAC stream.
            assertEquals(FlacStatus.META, flacDecode(data.copyOfRange(1, data.size), 0, 0).status)
        }
    }

    @Test
    fun flacEncoderMatchesPython() {
        for (ec in encoderCases) {
            val x = gen(ec.vid, ec.nsig, ec.bps, ec.spf, ec.nframes, ec.kinds)
            var sum = 0u
            for (v in x) sum += v.toUInt()
            assertEquals(ec.sum, sum)
            val bytes = encode(ec.nsig, ec.bps, ec.spf, x)
            assertEquals(ec.size, bytes.size, "case ${ec.vid}")
            assertEquals(ec.digest, md5Hex(bytes), "case ${ec.vid}")
            assertTrue(bytes.indexOf("wfdb-x".latin1()) >= 0)

            // Round trip
            val d = flacDecode(bytes, ec.nsig, ec.bps)
            assertEquals(FlacStatus.OK, d.status)
            assertEquals(ec.nsig, d.channels)
            assertEquals(ec.bps, d.bps)
            assertEquals(ec.nsig, d.chans.size)
            val nper = ec.nframes * ec.spf
            for (s in 0 until ec.nsig) {
                assertEquals(nper, d.chans[s].size)
                for (f in 0 until ec.nframes) for (k in 0 until ec.spf) {
                    val i = (f * ec.nsig + s) * ec.spf + k
                    assertEquals(wrap(x[i], ec.bps), d.chans[s][f * ec.spf + k])
                }
            }
            assertTrue(d.hasMd5)
            assertContentEquals(d.md5, flacSamplesMd5(d.chans, d.bps))
        }
    }

    @Test
    fun flacEncoderIncompleteFrame() {
        // Samples of an incomplete frame (fewer than nsig*spf) are not
        // written.
        val enc = FlacEncoder(2, 16, 1)
        val out = ByteVec()
        out.addAll(enc.header())
        for (i in 0 until 9) enc.put(i * 100, out)
        enc.finish(out)
        val b = out.toByteArray()
        enc.streaminfo().copyInto(b, 8)
        val d = flacDecode(b, 0, 0)
        assertEquals(FlacStatus.OK, d.status)
        assertEquals(2, d.chans.size)
        assertEquals(4, d.chans[0].size)
        assertEquals(700, d.chans[1][3])
        // The wrong number of signals is detected when expected.
        val d2 = flacDecode(b, 3, 16)
        assertEquals(FlacStatus.WFDB, d2.status)
        assertEquals("getvec: wrong number of signals in FLAC signal file\n", d2.errorMessage?.latin1())
        val d3 = flacDecode(b, 2, 8)
        assertEquals(FlacStatus.WFDB, d3.status)
        assertEquals("getvec: wrong sample resolution in FLAC signal file\n", d3.errorMessage?.latin1())
    }
}
