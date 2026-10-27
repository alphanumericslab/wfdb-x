// Tests of the bulk path of getvecs (Signal.kt; port of rust/tests/bulk.rs):
// for records in every format it handles, with invalid samples, several
// signal groups, frames that cross the end of the input buffers, the frame
// at which the checksums are verified, truncated files and seeks, getvecs
// returns exactly what the per-frame path returns (the same samples,
// statuses, messages and input position), and leaves the same state behind
// (the frames read afterwards, frame by frame, are the same too); readRecord
// gives the same with the bulk path on and off for multi-frequency records
// (low and high resolution), multi-segment records of fixed and variable
// layout, and every record of tests/data.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It tests WFDB-x; it has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

import wfdbx.cstd.latin1
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class BulkTest {
    /** A small deterministic random number generator. */
    private class Rng(var s: Long) {
        fun next(): Long {
            s = s * 6364136223846793005L + 1442695040888963407L
            return s ushr 33
        }

        fun below(n: Long): Long = next() % n

        fun range(lo: Long, hi: Long): Long = lo + Math.floorMod(next(), hi - lo + 1)
    }

    private object Math {
        fun floorMod(a: Long, b: Long): Long {
            val r = a % b
            return if (r != 0L && ((r xor b) < 0)) r + b else r
        }
    }

    /** The range of the samples of a format (the lowest value is the code of an invalid sample, except in format 8). */
    private fun range(fmt: Int): Pair<Long, Long> = when (fmt) {
        80 -> Pair(-128L, 127L)
        310, 311 -> Pair(-512L, 511L)
        212 -> Pair(-2048L, 2047L)
        16, 61, 160 -> Pair(-32768L, 32767L)
        24 -> Pair(-(1L shl 23), (1L shl 23) - 1)
        else -> Pair(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong())
    }

    /**
     * Writes record [name]: groups of signals (one signal file per group, in
     * the format of the group), [n] frames of random samples, about 5% of
     * them invalid (format 8: a random walk, without invalid samples).
     */
    private fun writeRec(w: Wfdb, rng: Rng, name: String, groups: List<Pair<Int, Int>>, n: Int) {
        val si = ArrayList<Siginfo>()
        for ((g, gr) in groups.withIndex()) {
            for (k in 0 until gr.second) {
                si.add(
                    Siginfo(
                        fname = "${name}_$g.dat".latin1(), desc = "s$g.$k".latin1(), group = g, fmt = gr.first,
                        gain = 200.0, adcres = 16, units = "mV".latin1(),
                    ),
                )
            }
        }
        val nsig = si.size
        val r = w.osigfopen(si.toTypedArray(), nsig)
        assertEquals(nsig, r, "$name: ${w.wfdberror().latin1()}")
        w.setsampfreq(100.0)
        val prev = LongArray(nsig)
        val v = IntArray(nsig)
        for (i in 0 until n) {
            for (s in 0 until nsig) {
                val fmt = si[s].fmt
                v[s] = if (fmt == 8) {
                    prev[s] = (prev[s] + rng.range(-60, 60)).coerceIn(-2000, 2000)
                    prev[s].toInt()
                } else if (rng.below(20) == 0L) {
                    if (fmt == 32 && rng.below(2) == 0L) Int.MIN_VALUE else WFDB_INVALID_SAMPLE
                } else {
                    val (lo, hi) = range(fmt)
                    // (mostly small values, some extreme ones)
                    when (rng.below(10)) {
                        0L -> lo.toInt()
                        1L -> hi.toInt()
                        else -> rng.range(maxOf(lo, -3000), minOf(hi, 3000)).toInt()
                    }
                }
            }
            assertTrue(w.putvec(v) >= 0)
        }
        assertEquals(0, w.newheader(name))
        w.wfdbquit()
    }

    /**
     * Everything observable about a read: the result of each getvecs call,
     * the samples, the last error message and the input position after each
     * call, and the frames read frame by frame (with getvec) afterwards.
     */
    private data class Trace(val calls: List<List<Any>>, val samples: List<Int>, val after: List<Pair<Int, List<Int>>>)

    /**
     * Reads record [name] with getvecs (bulk path on or off), in calls of the
     * sizes of [chunks] (repeated), after seeking to each time of [seeks] in
     * turn (no seek if empty), then reads up to 50 more frames with getvec.
     */
    private fun trace(w: Wfdb, name: String, bulk: Boolean, mode: Int, ibsize: Int, chunks: LongArray, seeks: LongArray): Trace {
        w.setibsize(ibsize)
        val nsig = w.isigopen(name, null, 0)
        assertEquals(nsig, w.isigopen(name, Array(nsig) { Siginfo() }, nsig))
        w.wfdbx_bulk_read(bulk)
        w.setgvmode(mode)
        val calls = ArrayList<List<Any>>()
        val samples = ArrayList<Int>()
        val after = ArrayList<Pair<Int, List<Int>>>()
        val buf = IntArray(20000 * nsig)
        val passes = if (seeks.isEmpty()) 1 else seeks.size
        for (p in 0 until passes) {
            if (p < seeks.size) {
                val r = w.isigsettime(seeks[p])
                calls.add(listOf(-100L, r, w.strtim("i"), w.wfdberror().latin1()))
            }
            var i = 0
            while (true) {
                val n = chunks[i % chunks.size]
                i++
                val res = w.getvecs_status(buf, n)
                val got = res.count
                val stat = res.status
                calls.add(listOf(got, stat, w.strtim("i"), w.wfdberror().latin1()))
                var k = maxOf(got, 0L).toInt()
                if (stat < 0 && stat != -1 && got < n) k++ // (the frame of a negative status: also compared)
                for (j in 0 until k * nsig) samples.add(buf[j])
                if (got < n || (seeks.isNotEmpty() && i > 3)) break
            }
        }
        val v = IntArray(nsig)
        for (j in 0 until 50) {
            val r = w.getvec(v)
            after.add(Pair(r, v.toList()))
            if (r < 0) break
        }
        w.wfdbx_bulk_read(true)
        w.wfdbquit()
        w.setibsize(0)
        return Trace(calls, samples, after)
    }

    /** Compares the bulk and the per-frame paths on record [name]. */
    private fun check(w: Wfdb, rng: Rng, name: String, nframes: Long) {
        val modes = intArrayOf(WFDB_LOWRES, WFDB_LOWRES or WFDB_GVPAD)
        for (mode in modes) {
            for (ibsize in intArrayOf(0, 7, 100, 1000)) {
                val chunkSets = listOf(
                    longArrayOf(nframes + 10),
                    longArrayOf(nframes),
                    longArrayOf(1, 333, 2, 1000, 5),
                    longArrayOf(rng.range(1, 2000), rng.range(1, 50), rng.range(1, 5000)),
                )
                for (chunks in chunkSets) {
                    val a = trace(w, name, true, mode, ibsize, chunks, LongArray(0))
                    val b = trace(w, name, false, mode, ibsize, chunks, LongArray(0))
                    assertEquals(b, a, "$name mode $mode ibsize $ibsize chunks ${chunks.toList()}")
                    assertTrue(a.samples.isNotEmpty() || nframes == 0L)
                }
                // seeks, then reads
                val seeks = LongArray(6) { rng.range(0, nframes + 2) } + longArrayOf(nframes - 1, 0, 1, 2)
                val chunks = longArrayOf(rng.range(1, 3000), rng.range(1, 7))
                val a = trace(w, name, true, mode, ibsize, chunks, seeks)
                val b = trace(w, name, false, mode, ibsize, chunks, seeks)
                assertEquals(b, a, "$name mode $mode ibsize $ibsize seeks ${seeks.toList()}")
            }
        }
    }

    @Test
    fun bulkEqualsPerFrame() {
        val dir = makeTempDir("bulk")
        val w = Wfdb()
        w.wfdbx_set_input_dir(dir)
        w.wfdbx_set_output_dir(dir)
        w.wfdbquiet()
        val rng = Rng(20261026)
        val cases = ArrayList<Pair<String, List<Pair<Int, Int>>>>()
        for (fmt in intArrayOf(8, 80, 16, 61, 160, 24, 32, 212, 310, 311)) {
            for (nn in 1..5) cases.add(Pair("r${fmt}_$nn", listOf(Pair(fmt, nn))))
        }
        // several groups (files), in the same or different formats
        cases.add(Pair("g1", listOf(Pair(212, 3), Pair(16, 2))))
        cases.add(Pair("g2", listOf(Pair(310, 1), Pair(311, 2), Pair(212, 1))))
        cases.add(Pair("g3", listOf(Pair(16, 1), Pair(16, 1), Pair(8, 2), Pair(24, 1))))
        cases.add(Pair("g4", listOf(Pair(80, 2), Pair(32, 1), Pair(160, 3), Pair(61, 1))))
        for ((name, groups) in cases) {
            val n = rng.range(2000, 6000)
            writeRec(w, rng, name, groups, n.toInt())
            // as written (correct checksums)
            check(w, rng, name, n)
            val files = groups.indices.map { "$dir/${name}_$it.dat" }
            val orig = files.map { readFile(it)!! }
            // a checksum error (one byte changed, in the middle of the file)
            val d = orig[0].copyOf()
            val k = d.size / 2
            d[k] = (d[k].toInt() xor 0x11).toByte()
            writeFile(files[0], d)
            check(w, rng, name, n)
            // a truncated file (the end of a frame, and the middle of one)
            val last = files.size - 1
            for (cut in intArrayOf(orig[last].size / 3, orig[last].size - 1)) {
                writeFile(files[0], orig[0])
                writeFile(files[last], orig[last].copyOf(cut))
                check(w, rng, name, n)
            }
            writeFile(files[last], orig[last])
        }
        // a record whose header gives no number of samples (no checksums)
        writeRec(w, rng, "nolen", listOf(Pair(16, 2)), 3000)
        val h = readFile("$dir/nolen.hea")!!.latin1().replaceFirst("nolen 2 100 3000", "nolen 2 100")
        writeFile("$dir/nolen.hea", h)
        check(w, rng, "nolen", 3000)
        removeTree(dir)
    }

    /**
     * Writes the random multi-frequency record [name] ([spf]: samples per
     * frame of each signal; [n] frames), with about 1% invalid samples (also
     * at the start; format 8: a random walk).
     */
    private fun mfRecord(
        w: Wfdb, name: String, rng: Rng, fmt: Int, spf: IntArray, n: Int,
        gains: DoubleArray = doubleArrayOf(200.0), names: List<String>? = null,
    ) {
        val cols = spf.sum()
        val x = IntArray(n * cols)
        if (fmt == 8) {
            for (c in 0 until cols) {
                var v = 0L
                for (i in 0 until n) {
                    v += rng.range(-60, 60)
                    x[i * cols + c] = v.toInt()
                }
            }
        } else {
            val (lo, hi) = range(fmt)
            for (i in x.indices) x[i] = if (rng.below(1000) < 10) WFDB_INVALID_SAMPLE else rng.range(lo + 1, hi).toInt()
            x[0] = WFDB_INVALID_SAMPLE
            x[cols] = WFDB_INVALID_SAMPLE
        }
        w.writeRecord(
            name, x, spf.size, 250.0, fmt = fmt, gains = gains, adcres = intArrayOf(16), units = listOf("mV"),
            names = names, sampsPerFrame = spf,
        )
    }

    /** A reading mode of the multi-frequency tests. */
    private data class Mode(
        val highres: Boolean = false, val pad: Boolean = false, val physical: Boolean = false,
        val from: Long? = null, val to: Long? = null, val channels: List<String>? = null,
    )

    private val mfModes = listOf(
        Mode(), Mode(pad = true), Mode(highres = true), Mode(highres = true, pad = true), Mode(physical = true),
        Mode(from = 1234), Mode(from = 7, to = 15000), Mode(highres = true, from = 3, to = 9001),
        Mode(channels = listOf("1", "0", "1")),
    )

    /** What readRecord returns (or the message of its exception), with the bulk path on or off. */
    private fun readMode(w: Wfdb, rec: String, m: Mode, bulk: Boolean): Any {
        val prev = w.wfdbx_bulk_read(bulk)
        try {
            return w.readRecord(
                rec, channels = m.channels, from = m.from?.let { TimeSpec(it) }, to = m.to?.let { TimeSpec(it) },
                physical = m.physical, highres = m.highres, pad = m.pad, checksumWarning = false,
            )
        } catch (e: WfdbException) {
            return e.message!!
        } finally {
            w.wfdbx_bulk_read(prev)
        }
    }

    /** readRecord gives the same with and without the bulk path. */
    private fun sameRead(w: Wfdb, rec: String, m: Mode) {
        assertEquals(readMode(w, rec, m, false), readMode(w, rec, m, true), "$rec: $m")
    }

    /**
     * Checks that almost all the vectors of a read of [rec] are read in
     * blocks (at least 99%, and all but a few frames of [per] vectors in
     * short records): all but those of a few frames per input buffer (whose
     * last frame is read frame by frame) and per segment, and near the end.
     */
    private fun mostlyBulk(w: Wfdb, rec: String, highres: Boolean, per: Long) {
        val before = w.wfdbxBulkVectors()
        val rows = w.readRecord(rec, highres = highres).nsamples.toLong()
        val bulk = w.wfdbxBulkVectors() - before
        assertTrue((rows - bulk) * 100 <= rows + 100 * 6 * per, "$rec highres $highres: $bulk of $rows vectors read in blocks")
    }

    /**
     * Writes the segments name_1, name_2, ... (one per length) and returns
     * the lines of the master header naming them, and their total length.
     */
    private fun writeSegments(
        w: Wfdb, name: String, rng: Rng, fmt: Int, spf: IntArray, lens: IntArray, gains: DoubleArray,
        names: List<String>,
    ): Pair<String, Int> {
        val lines = StringBuilder()
        for ((k, len) in lens.withIndex()) {
            val seg = "${name}_${k + 1}"
            mfRecord(w, seg, rng, fmt, spf, len, gains, names)
            lines.append("$seg $len\n")
        }
        return Pair(lines.toString(), lens.sum())
    }

    private val formats = intArrayOf(8, 80, 16, 61, 160, 24, 32, 212, 310, 311)

    @Test
    fun bulkReadMultifrequency() {
        // Records of several sampling frequencies are read in blocks: the
        // same samples as frame by frame, in low- and high-resolution modes.
        val dir = makeTempDir("bulkmf")
        val w = Wfdb()
        w.wfdbx_set_input_dir(dir)
        w.wfdbx_set_output_dir(dir)
        w.wfdbquiet()
        val spfs = listOf(intArrayOf(4, 1, 1, 1), intArrayOf(2, 3), intArrayOf(1, 2), intArrayOf(8, 1), intArrayOf(3, 3, 1))
        for (fmt in formats) {
            val rng = Rng(fmt + 1L)
            for (spf in spfs) {
                val n = rng.range(16000, 23999).toInt()
                mfRecord(w, "m", rng, fmt, spf, n)
                for (m in mfModes) sameRead(w, "m", m)
                mostlyBulk(w, "m", true, spf.max().toLong())
                mostlyBulk(w, "m", false, 1)
            }
        }
        removeTree(dir)
    }

    @Test
    fun bulkReadMultisegment() {
        // Multi-segment records, of fixed and of variable layout (with
        // signals missing from some segments, other gains, and a null
        // segment), are read in blocks: the same samples as frame by frame.
        val dir = makeTempDir("bulkms")
        val w = Wfdb()
        w.wfdbx_set_input_dir(dir)
        w.wfdbx_set_output_dir(dir)
        w.wfdbquiet()
        val rng = Rng(11)
        val names = listOf("ECG", "ABP", "RESP")
        // fixed layout
        val (segs, total) = writeSegments(
            w, "fx", rng, 212, intArrayOf(4, 1, 1), intArrayOf(9000, 7001, 12000), doubleArrayOf(200.0), names,
        )
        writeFile("$dir/fx.hea", "fx/3 3 250 $total\n$segs")
        val modes = mfModes + Mode(from = 8999, to = 16002)
        for (m in modes) sameRead(w, "fx", m)
        assertEquals(28001, w.readRecord("fx").nsamples)
        mostlyBulk(w, "fx", false, 3)
        mostlyBulk(w, "fx", true, 3 * 4)
        // variable layout
        writeFile(
            "$dir/vl_0.hea",
            "vl_0 3 250 0\n~ 0x4 400(10)/mV 12 0 0 0 0 ECG\n~ 0 100/mV 16 0 0 0 0 ABP\n~ 0 50/mV 16 0 0 0 0 RESP\n",
        )
        val (s1, t1) = writeSegments(
            w, "va", rng, 16, intArrayOf(4, 1, 1), intArrayOf(5000), doubleArrayOf(400.0, 100.0, 50.0), names,
        )
        val (s2, t2) = writeSegments(
            w, "vb", rng, 16, intArrayOf(1, 4), intArrayOf(6003), doubleArrayOf(25.0, 200.0), listOf("RESP", "ECG"),
        )
        val (s3, t3) = writeSegments(w, "vc", rng, 212, intArrayOf(1), intArrayOf(4000), doubleArrayOf(100.0), listOf("ABP"))
        writeFile("$dir/vl.hea", "vl/5 3 250 ${2500 + t1 + t2 + t3}\nvl_0 0\n$s1~ 2500\n$s2$s3")
        for (m in modes.dropLast(1) + Mode(from = 4990, to = 9000)) sameRead(w, "vl", m)
        mostlyBulk(w, "vl", false, 6)
        mostlyBulk(w, "vl", true, 6 * 4)
        val r = w.readRecord("vl", physical = true)
        assertEquals(17503, r.nsamples)
        for (i in 5000 until 7500) for (s in 0 until 3) assertTrue(r.physical!![i * 3 + s].isNaN())
        removeTree(dir)
    }

    @Test
    fun bulkReadAllTestRecords() {
        // Every record of tests/data (but those read from the standard input,
        // 8 and 16): the same in blocks as frame by frame, in five reading
        // modes (or the same error).
        val data = testDataDir()
        val recs = listFiles(data).filter { it.endsWith(".hea") }.map { it.removeSuffix(".hea") }
            .filter { it != "8" && it != "16" }.sorted()
        assertTrue(recs.size > 20)
        val w = Wfdb()
        w.wfdbx_set_input_dir(data)
        w.wfdbquiet()
        val modes = listOf(Mode(), Mode(pad = true), Mode(highres = true), Mode(highres = true, pad = true), Mode(from = 3))
        for (rec in recs) for (m in modes) sameRead(w, rec, m)
    }

    @Test
    fun bulkMultifrequencyInterleaved() {
        // getvecs (bulk) mixed with getvec and isigsettime on a
        // multi-frequency record, in high resolution also from the middle of
        // a frame: the same vectors, statuses and library state as frame by
        // frame.
        val dir = makeTempDir("bulkil")
        val w = Wfdb()
        w.wfdbx_set_input_dir(dir)
        w.wfdbx_set_output_dir(dir)
        w.wfdbquiet()
        mfRecord(w, "mf", Rng(5), 212, intArrayOf(4, 1, 3), 20001)
        val steps = listOf(
            Pair('f', 999L), Pair('v', 3L), Pair('f', 4097L), Pair('t', 17L), Pair('v', 1L), Pair('f', 9001L),
            Pair('v', 2L), Pair('t', 30L), Pair('f', 200000L),
        )
        for (hr in listOf(false, true)) {
            val out = ArrayList<String>()
            for (bulk in listOf(true, false)) {
                val t = StringBuilder()
                w.wfdbx_bulk_read(bulk)
                assertEquals(3, w.isigopen("mf", Array(3) { Siginfo() }, 3))
                w.setgvmode((if (hr) WFDB_HIGHRES else WFDB_LOWRES) or WFDB_GVPAD)
                for ((op, k) in steps) {
                    when (op) {
                        'f' -> {
                            val buf = IntArray(k.toInt() * 3)
                            val r = w.getvecs_status(buf, k)
                            t.append("getvecs ${r.count} ${r.status}: ${buf.copyOf(maxOf(r.count, 0L).toInt() * 3).toList()}")
                        }
                        'v' -> for (j in 0 until k) {
                            val v = IntArray(3)
                            val r = w.getvec(v)
                            t.append("getvec $r: ${v.toList()}\n")
                        }
                        else -> t.append("isigsettime ${w.isigsettime(k)}")
                    }
                    t.append("\n${w.wfdbxInputState()}\n")
                }
                w.wfdbquit()
                out.add(t.toString())
            }
            w.wfdbx_bulk_read(true)
            assertEquals(out[1], out[0], "highres $hr")
        }
        removeTree(dir)
    }
}
