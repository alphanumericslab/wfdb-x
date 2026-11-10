// Tests of the corrections of WFDB-x 1.2.2 (ports of the 1.2.2 tests of
// python/tests/test_signals.py and test_annotations.py): truncated records in
// the high-level readers, the memory used by readRecord, the checks of the
// writers before any file is touched, the writers' temporary files, the
// arguments of readAnnotations, and the record line of getinfo.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It tests WFDB-x; it has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation, either version 2.1 of the License, or (at
// your option) any later version. See LICENSE.

package wfdbx

import wfdbx.cstd.Platform
import wfdbx.cstd.getenv
import wfdbx.cstd.latin1
import wfdbx.cstd.setenv
import wfdbx.cstd.unsetenv
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CorrectionsTest {
    private fun withData(name: String, f: (DataDir, Wfdb) -> Unit) {
        val d = DataDir(name)
        val w = d.wfdb()
        try {
            f(d, w)
        } finally {
            w.wfdbquit()
            d.remove()
        }
    }

    private fun failsContaining(part: String, f: () -> Unit): WfdbException {
        val e = assertFailsWith<WfdbException> { f() }
        assertTrue(e.message!!.contains(part), "'${e.message}' does not contain '$part'")
        return e
    }

    /** An argument error (WfdbArgumentException) whose message contains [part]. */
    private fun argFails(part: String, f: () -> Unit) {
        val e = assertFailsWith<WfdbArgumentException> { f() }
        assertTrue(e.message!!.contains(part), "'${e.message}' does not contain '$part'")
    }

    /** Legacy mode reads from the WFDB path, not from the input directory: the WFDB path of [w] is set to [d]. */
    private fun legacyPath(w: Wfdb, d: DataDir) {
        val saved = getenv("WFDB")
        w.wfdbx_set_legacy(1)
        w.setwfdb(d.dir)
        w.wfdbx_set_legacy(0)
        if (saved == null) unsetenv("WFDB") else setenv("WFDB", saved)
    }

    /** The contents of every file of the directory (hidden files included). */
    private fun files(d: DataDir): Map<String, List<Byte>> = listFiles(d.dir).associateWith { d.read(it)!!.asList() }

    private fun noTemporaryFiles(d: DataDir) = assertEquals(emptyList(), listFiles(d.dir).filter { it.endsWith(".tmp") })

    /** The library state after a failed read: no open signals or annotators, the read flag clear. */
    private fun stateClean(w: Wfdb): Boolean =
        w.sig.nisig == 0 && w.sig.nosig == 0 && !w.sig.readFailed && !w.sig.cksumQuiet &&
            w.ann.iad.isEmpty() && w.ann.oad.isEmpty() && w.io.staging == null

    private fun int16le(vararg v: Int): ByteArray {
        val b = ByteArray(2 * v.size)
        for ((i, x) in v.withIndex()) {
            b[2 * i] = x.toByte()
            b[2 * i + 1] = (x shr 8).toByte()
        }
        return b
    }

    @Test
    fun truncatedFrameWithChecksum() = withData("trunc") { d, w ->
        // A format-16 file holding the samples 1 and 2, whose header gives 3
        // samples: getvec reports the unexpected end of file (-3), and then
        // the checksum error (-4) of the frame at which the checksum is
        // verified, whose status replaces -3. readRecord throws the read
        // error, and never returns the incomplete frame.
        w.wfdbquiet()
        writeFile(d.path("tr.dat"), int16le(1, 2))
        writeFile(d.path("tr.hea"), "tr 1 250 3\ntr.dat 16 200 16 0 1 0 0 s\n")
        failsContaining("can't read signal data of record tr (getvec status -3)") { w.readRecord("tr") }
        assertTrue(stateClean(w))
        // the C-style getvec keeps the C behavior: -4 for the incomplete frame
        assertEquals(1, w.isigopen("tr", Array(1) { Siginfo() }, 1))
        val v = IntArray(1)
        assertEquals(listOf(1, 1), listOf(w.getvec(v), v[0]))
        assertEquals(listOf(1, 2), listOf(w.getvec(v), v[0]))
        assertEquals(-4, w.getvec(v))
        w.wfdbquit()
        // in high-resolution mode as well
        failsContaining("(getvec status -3)") { w.readRecord("tr", highres = true) }
        // the library still reports the end of the file
        w.wfdb_error("sentinel\n")
        failsContaining("(getvec status -3)") { w.readRecord("tr", to = TimeSpec(3)) }
        assertTrue(w.wfdberror().latin1().startsWith("getvec: "))
        // the frames before it are read when `to` stops before it
        assertEquals(listOf(1, 2), w.readRecord("tr", to = TimeSpec(2)).samples.toList())
        // checkRecord reports the short file, not a checksum error
        val rep = w.checkRecord("tr")
        assertEquals(listOf("length_short"), rep.issues.filter { it.severity == Severity.ERROR }.map { it.code })
        assertTrue(rep.toString().contains("the signal files end after 2 frames, before the 3 given in the header"))
        assertTrue(stateClean(w))
        // a checksum error alone (all samples read) is still a warning
        writeFile(d.path("tr.hea"), "tr 1 250 2\ntr.dat 16 200 16 0 1 0 0 s\n")
        val warnings = ArrayList<String>()
        val r = w.readRecord("tr", onWarning = { warnings.add(it) })
        assertEquals(listOf(1, 2), r.samples.toList())
        assertFalse(r.checksumOk)
        assertEquals(1, warnings.size)
        assertTrue(warnings[0].startsWith("checksum error in record tr"))
    }

    @Test
    fun boundedAllocation() = withData("bigalloc") { d, w ->
        // A header that gives 10^12 samples for a signal file of 4 bytes: the
        // reader allocates no more than 2^26 values in advance, and reports
        // the short file as a read error.
        w.wfdbquiet()
        writeFile(d.path("big.dat"), unhex("01000200"))
        writeFile(d.path("big.hea"), "big 1 250 1000000000000\nbig.dat 16 200 16 0 0 0 0 s\n")
        failsContaining("getvec status -3") { w.readRecord("big") }
        assertEquals(listOf(1, 2), w.readRecord("big", to = TimeSpec(2)).samples.toList())
        failsContaining("getvec status -3") { w.readRecord("big", to = TimeSpec(1000000000000L)) }
        // a long record is still read whole, growing the array
        val x = IntArray(300000) { it % 30000 }
        w.writeRecord("long", x, 3, 100.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(16), units = listOf("mV"))
        val h = d.read("long.hea")!!.latin1()
        assertTrue(h.startsWith("long 3 100 100000"))
        writeFile(d.path("long.hea"), h.replace("long 3 100 100000", "long 3 100")) // (no length)
        assertContentEquals(x, w.readRecord("long").samples)
    }

    /** Writes the record r (100 frames of 100s, 2 signals). */
    private fun write100sCopy(w: Wfdb) {
        val s = w.readRecord("100s", to = TimeSpec(100)).samples
        w.writeRecord(
            "r", s, 2, 360.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(11), units = listOf("mV"),
            names = listOf("a", "b"),
        )
    }

    @Test
    fun writeRecordChecksBeforeWriting() = withData("wrchecks") { d, w ->
        // Each invalid argument is refused before any file is touched: the
        // existing record is unchanged, and no temporary file is left.
        write100sCopy(w)
        val before = files(d)
        val x = IntArray(10)
        val bad: List<Pair<String, () -> Unit>> = listOf(
            "writeRecord: units 'μV' has a character that is not Latin-1 (one byte per character)" to {
                w.writeRecord("r", x, 2, 360.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("μV"))
            },
            "writeRecord: signal name 'μ' has a character that is not Latin-1 (one byte per character)" to {
                w.writeRecord(
                    "r", x, 2, 360.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("mV"),
                    names = listOf("a", "μ"),
                )
            },
            "writeRecord: comment 'μ' has a character that is not Latin-1 (one byte per character)" to {
                w.writeRecord(
                    "r", x, 2, 360.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("mV"),
                    comments = listOf("ok", "μ"),
                )
            },
            "writeRecord: ADC resolution(s) must be specified" to {
                w.writeRecord("r", x, 2, 360.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12, 0), units = listOf("mV"))
            },
            "writeRecord: ADC resolution(s) must be specified" to {
                // (before the units)
                w.writeRecord("r", x, 2, 360.0, gains = doubleArrayOf(200.0))
            },
            "writeRecord: gains must be finite" to {
                w.writeRecord(
                    "r", x, 2, 360.0, gains = doubleArrayOf(200.0, Double.POSITIVE_INFINITY), adcres = intArrayOf(12),
                    units = listOf("mV"),
                )
            },
            "writeRecord: record name 'rμ' has a character that is not Latin-1 (one byte per character)" to {
                w.writeRecord("rμ", x, 2, 360.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("mV"))
            },
            "writeRecord: units 'μV'" to {
                w.writeRecord(
                    "r", DoubleArray(10), 2, 360.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12),
                    units = listOf("μV"),
                )
            },
        )
        for ((msg, f) in bad) {
            val e = assertFailsWith<WfdbArgumentException> { f() }
            assertEquals(msg, e.message!!.take(msg.length))
            assertEquals(before, files(d), msg)
        }
        noTemporaryFiles(d)
    }

    @Test
    fun writeRecordFailureLeavesFiles() = withData("wrfail") { d, w ->
        // A failure while writing (the header cannot be created, or the
        // samples cannot be written) leaves the existing files intact: both
        // are written to temporary files, renamed over them at the end.
        write100sCopy(w)
        val before = files(d)
        val x = IntArray(20) { it }
        fun write(rec: String = "r") =
            w.writeRecord(rec, x, 2, 250.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("mV"))
        w.io.testNewheader = { -1 }
        try {
            failsContaining("can't create header for record r") { write() }
        } finally {
            w.io.testNewheader = null
        }
        assertEquals(before, files(d))
        w.io.testPutframes = { _, _ -> throw IllegalStateException("disk on fire") }
        try {
            val e = assertFailsWith<IllegalStateException> { write() }
            assertEquals("disk on fire", e.message)
        } finally {
            w.io.testPutframes = null
        }
        assertEquals(before, files(d))
        assertTrue(stateClean(w))
        // a directory in the way of the header: the signal file is not replaced
        writeFile(d.path("q.hea/.keep"), "")
        w.wfdbquiet()
        failsContaining("can't create header for record q") { write("q") }
        w.wfdbverbose()
        assertFalse(fileExists(d.path("q.dat")))
        noTemporaryFiles(d)
        // success: the files are those written in place before
        write()
        assertContentEquals(x, w.readRecord("r").samples)
        noTemporaryFiles(d)
        // in legacy mode too
        w.writeRecord("r", x, 2, 250.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("mV"), legacy = true)
        noTemporaryFiles(d)
        // in a missing directory (created, as before)
        w.writeRecord("sub/dir/r", x, 2, 250.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("mV"))
        assertContentEquals(x, w.readRecord("sub/dir/r").samples)
        assertEquals(listOf("r.dat", "r.hea"), listFiles(d.path("sub/dir")))
    }

    @Test
    fun writeAnnotationsChecksBeforeWriting() = withData("wachecks") { d, w ->
        // Each invalid argument is refused before the existing annotation
        // file is touched (the reserved codes 59-63 corrupted it; the times
        // -2^63 and 2^63 - 1 were dropped, with putann's "time overflow"
        // message, and success reported).
        w.writeAnnotations("100s", "qrs", longArrayOf(10, 20, 30), symbols = listOf("N", "N", "N"))
        val before = files(d)
        val n3 = listOf("N", "N", "N")
        val t = longArrayOf(1, 2, 3)
        val bad = ArrayList<Pair<String, () -> Unit>>()
        bad.add(
            "writeAnnotations: annotation time -9223372036854775808 cannot be written (annotation times must be " +
                "integers from -9223372036854775807 to 9223372036854775806)" to {
                    w.writeAnnotations("100s", "qrs", longArrayOf(Long.MIN_VALUE, 5, 6), symbols = n3)
                },
        )
        bad.add(
            "writeAnnotations: annotation time 9223372036854775807 cannot be written" to {
                w.writeAnnotations("100s", "qrs", longArrayOf(1, 5, Long.MAX_VALUE), symbols = n3)
            },
        )
        bad.add(
            "writeAnnotations: annotation code -1 is out of range (0 to 58)" to {
                w.writeAnnotations("100s", "qrs", t, codes = intArrayOf(-1, -1, -1))
            },
        )
        bad.add(
            "writeAnnotations: annotation code 64 is out of range (0 to 58)" to {
                w.writeAnnotations("100s", "qrs", t, codes = intArrayOf(1, 64, 1))
            },
        )
        bad.add(
            "writeAnnotations: aux text 'μ' has a character that is not Latin-1 (one byte per character)" to {
                w.writeAnnotations("100s", "qrs", t, symbols = n3, aux = listOf(null, "μ", null))
            },
        )
        for (c in 59..63) {
            bad.add(
                "writeAnnotations: annotation code $c is reserved (59 to 63 are the control codes of the annotation " +
                    "file format)" to { w.writeAnnotations("100s", "qrs", t, codes = intArrayOf(1, c, 1)) },
            )
        }
        w.wfdb_error("sentinel\n")
        for ((msg, f) in bad) {
            val e = assertFailsWith<WfdbArgumentException> { f() }
            assertEquals(msg, e.message!!.take(msg.length))
            assertEquals(before, files(d), msg)
        }
        assertEquals("sentinel\n", w.wfdberror().latin1()) // (nothing printed)
        // code 58, and a time far from the previous one (SKIPs), can be written
        w.writeAnnotations("100s", "ext", longArrayOf(0, 1L shl 33), codes = intArrayOf(58, 1))
        val a = w.readAnnotations("100s", "ext")
        assertEquals(listOf(0L, 1L shl 33), a.samples.toList())
        assertEquals(listOf(58, 1), a.codes.toList())
        noTemporaryFiles(d)
    }

    @Test
    fun writeAnnotationsFailureLeavesFile() = withData("wafail") { d, w ->
        // An error that putann reports is an error (it was ignored), and a
        // failure leaves the existing file intact: the file is written to a
        // temporary file, renamed over it when complete.
        w.writeAnnotations("100s", "qrs", longArrayOf(10, 20, 30), symbols = listOf("N", "N", "N"))
        val before = files(d)
        w.io.testPutanns = { -1 }
        try {
            val e = failsContaining("write error on annotator qrs for record 100s") {
                w.writeAnnotations("100s", "qrs", longArrayOf(1, 2), symbols = listOf("V", "V"))
            }
            assertEquals("write error on annotator qrs for record 100s", e.message)
        } finally {
            w.io.testPutanns = null
        }
        assertEquals(before, files(d))
        w.io.testPutanns = { throw IllegalStateException("disk on fire") }
        try {
            assertFailsWith<IllegalStateException> {
                w.writeAnnotations("100s", "qrs", longArrayOf(1, 2), symbols = listOf("V", "V"))
            }
        } finally {
            w.io.testPutanns = null
        }
        assertEquals(before, files(d))
        assertTrue(stateClean(w))
        // out of order: sorted (in this process, and in legacy mode by the
        // sortann program), then renamed over the existing file
        w.wfdbquiet()
        for (legacy in listOf(false, true)) {
            w.writeAnnotations("100s", "qrs", longArrayOf(30, 10, 20), symbols = listOf("N", "N", "N"), legacy = legacy)
            assertEquals(listOf(10L, 20L, 30L), w.readAnnotations("100s", "qrs").samples.toList(), "legacy $legacy")
            noTemporaryFiles(d)
        }
    }

    @Test
    fun readAnnotationsArguments() = withData("raargs") { d, w ->
        // `from` is checked as readRecord checks it, before the file is
        // opened, and the file is closed on every path.
        val ref = w.readAnnotations("100s", "atr", from = TimeSpec(100), to = TimeSpec(2000))
        assertTrue(ref.size > 0)
        argFails("readAnnotations: from must not be negative") {
            w.readAnnotations("100s", "nosuch", from = TimeSpec(-1))
        }
        argFails("readAnnotations: fs must be > 0") { w.readAnnotations("100s", "nosuch", fs = Double.NaN) }
        // the annotators are closed after an error
        assertTrue(Platform.remove(d.path("100s.hea").latin1())) // (no sampling frequency)
        failsContaining("sampling frequency") { w.readAnnotations("100s", "atr", to = TimeSpec("0:1")) }
        assertTrue(w.ann.iad.isEmpty())
        writeFile(d.path("cut.atr"), d.read("100s.atr")!!.copyOf(101))
        w.wfdbquiet()
        failsContaining("getann status -3") { w.readAnnotations("cut", "atr", fs = 360.0) }
        assertTrue(w.ann.iad.isEmpty())
        assertTrue(stateClean(w))
    }

    @Test
    fun getinfoRecordLine() = withData("recline") { d, w ->
        // The record line is found as readheader finds it: the first line
        // with a token (separated by spaces, tabs, CRs and LFs) that does
        // not begin with '#'. A comment before it is not an info string,
        // even after an empty or blank first line (C's getinfo took the
        // empty line for the record line); in legacy mode, the C rule
        // applies.
        legacyPath(w, d)
        val sig = "fmt16.dat 16 200 12 0 0 0 0 a\n"
        val cases = listOf(
            listOf("le", "\n# Age: 40\nle 1 250 10\n" + sig + "# Age: 63\n", listOf(" Age: 63"), listOf(" Age: 40", " Age: 63")),
            listOf(
                "lw", " \t\r\n# Age: 40\r\nlw 1 250 10\r\n" + sig.replace("\n", "\r\n") + "# Age: 63\r\n",
                listOf(" Age: 63"), listOf(" Age: 40", " Age: 63"),
            ),
            listOf(
                "lc", "# first\n\n# Age: 40\n \t\n  # indented\nlc 1 250 10\n" + sig + "# Age: 63\n#last\n",
                listOf(" Age: 63", "last"), listOf(" Age: 40", " Age: 63", "last"),
            ),
            listOf("ln", "# only\n\n# comments\n", listOf<String>(), listOf(" comments")),
        )
        for (c in cases) {
            val name = c[0] as String
            writeFile(d.path("$name.hea"), c[1] as String)
            val normal = c[2]
            val legacy = c[3]
            for ((mode, want) in listOf(0 to normal, 1 to legacy)) {
                val previous = w.wfdbx_set_legacy(mode)
                val got = ArrayList<String>()
                try {
                    var s = w.getinfo(name)
                    while (s != null) {
                        got.add(s.latin1())
                        s = w.getinfo(null as ByteArray?)
                    }
                } finally {
                    w.wfdbx_set_legacy(previous)
                }
                assertEquals(want, got, "$name, legacy $mode")
                w.wfdbquit()
            }
            if (name != "ln") {
                assertEquals(normal, w.readHeader(name).comments)
                assertEquals(legacy, w.readHeader(name, legacy = true).comments)
                assertEquals(listOf("Age" to "63"), w.readHeader(name).metadata)
                assertEquals(listOf("Age" to "63"), w.readHeader(name, legacy = true).metadata)
                assertEquals(legacy, w.readRecord(name, legacy = true, checksumWarning = false).comments)
            }
        }
    }
}
