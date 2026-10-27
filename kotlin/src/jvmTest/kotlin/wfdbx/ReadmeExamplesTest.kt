// The examples of kotlin/README.md, run as tests: each test holds the code
// of one example (with the directories of a scratch copy of tests/data, and
// a local HTTP server in place of PhysioNet), and checks what the README
// says it gives. Keep them in step with the README.
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

import com.sun.net.httpserver.HttpServer
import wfdbx.cstd.latin1
import java.io.File
import java.net.InetSocketAddress
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ReadmeExamplesTest {
    /** Runs [f] in a new thread (a fresh default instance), with the input and output directories in a copy of tests/data. */
    private fun example(f: (DataDir) -> Unit) {
        var failure: Throwable? = null
        val t = Thread {
            val d = DataDir("readme")
            try {
                wfdbxSetInputDir(d.dir)
                wfdbxSetOutputDir(d.dir)
                f(d)
            } catch (e: Throwable) {
                failure = e
            } finally {
                wfdbquit()
                d.remove()
            }
        }
        t.start()
        t.join()
        failure?.let { throw it }
    }

    private val out = StringBuilder()

    private fun println(s: Any?) {
        out.append(s).append('\n')
    }

    @Test
    fun quickStart() = example { d ->
        val rec = readRecord("100s", physical = true) // samples in ADC and physical units
        println("${rec.fs} ${rec.names} ${rec.nsamples}") // 360.0 [MLII, V5] 21600

        val hdr = readHeader("100s") // the header only, no samples
        println("${hdr.nsig} ${hdr.nsamples}") // 2 21600

        val ann = readAnnotations("100s", "atr") // beat annotations
        println("${ann.size} ${ann.symbols.take(3)} ${ann.samples.take(3)}") // 75 [+, N, N] [18, 77, 370]

        // Write the first 10 seconds as a new record in the current directory.
        val x = readRecord("100s", to = TimeSpec("0:10")) // ADC units
        writeRecord(
            "copy", x.samples, x.nsig, x.fs, fmt = 16, gains = x.gains.toDoubleArray(),
            baselines = x.baselines.toIntArray(), adcres = intArrayOf(11), units = listOf("mV"),
            names = x.names,
        )
        assertEquals("360.0 [MLII, V5] 21600\n2 21600\n75 [+, N, N] [18, 77, 370]\n", out.toString())
        assertEquals(x.samples.toList(), readRecord("copy").samples.toList())
        assertTrue(d.read("copy.hea")!!.latin1().startsWith("copy 2 360 3600"))
    }

    @Test
    fun readingSignalsHeadersAnnotations() = example { _ ->
        val rec = readRecord("100s", channels = listOf("MLII"), from = TimeSpec("0:10"), to = TimeSpec("0:20"), physical = true)
        assertEquals(3600, rec.nsamples) // 10 s of lead MLII
        assertEquals((rec.samples[0] - 1024) / 200.0, rec.physical!![0]) // its first sample, in mV

        val hdr = readHeader("100s")
        for (s in hdr.siginfo) {
            println("${s.desc?.latin1()} ${s.fmt} ${s.gain} ${s.units?.latin1()}") // MLII 212 200.0 null
        }
        assertEquals("MLII 212 200.0 null\nV5 212 200.0 null\n", out.toString())

        val ann = readAnnotations("100s", "atr", from = TimeSpec("0:10"), to = TimeSpec("0:30"))
        val beats = (0 until ann.size).filter { isqrs(ann.codes[it]) != 0 }.map { ann.samples[it] }
        assertTrue(beats.isNotEmpty() && beats.all { it in 3600 until 10800 })
    }

    @Test
    fun writing() = example { d ->
        val rnd = java.util.Random(1)
        val x = DoubleArray(3600 * 2) { rnd.nextGaussian() } // 3600 frames of 2 signals, in mV
        writeRecord(
            "rand", x, nsig = 2, fs = 360.0, fmt = 16, gains = doubleArrayOf(1000.0),
            adcres = intArrayOf(16), units = listOf("mV"), names = listOf("A", "B"),
        )
        writeAnnotations("rand", "qrs", longArrayOf(100, 460, 820), symbols = listOf("N", "N", "V"))
        val ann = readAnnotations("rand", "qrs")
        writeAnnotations("rand", "atr2", ann)
        assertEquals(listOf("N", "N", "V"), readAnnotations("rand", "atr2").symbols)
        val r = readRecord("rand", physical = true)
        assertEquals(3600, r.nsamples)
        assertTrue(r.physical!!.indices.all { kotlin.math.abs(r.physical!![it] - x[it]) <= 0.0005 })
        assertTrue(File(d.path("rand.dat")).length() == 3600L * 2 * 2)
    }

    @Test
    fun checking() = example { _ ->
        val report = checkRecord("100s", listOf("atr"))
        println(report)
        assertEquals("warning: signal 0: the units are not specified\nwarning: signal 1: the units are not specified\n", out.toString())
    }

    @Test
    fun directories() = example { d ->
        // (the README's /data/mitdb: a directory holding a record 100)
        val mitdb = d.path("data/mitdb")
        val s = readRecord("100s")
        writeRecord("100", s.samples, s.nsig, s.fs, fmt = 212, gains = s.gains.toDoubleArray(), baselines = s.baselines.toIntArray(), adcres = intArrayOf(11), units = listOf("mV"), dir = d.dir)
        writeFile("$mitdb/100.hea", d.read("100.hea")!!)
        writeFile("$mitdb/100.dat", d.read("100.dat")!!)
        writeFile(d.path("out/.keep"), "")
        wfdbxSetOutputDir(d.dir)

        wfdbxSetInputDir(mitdb)
        val rec = readRecord("100") // reads /data/mitdb/100.hea and 100.dat
        writeAnnotations("100", "qrs", longArrayOf(100, 460), symbols = listOf("N", "N"), dir = d.path("out")) // writes out/100.qrs
        assertEquals(s.samples.toList(), rec.samples.toList())
        assertTrue(fileExists(d.path("out/100.qrs")))
    }

    @Test
    fun physionet() {
        // (a local server in place of https://physionet.org/files/mitdb/1.0.0/)
        val data = testDataDir()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/files/mitdb/1.0.0/") { ex ->
            val f = File(data, ex.requestURI.path.substringAfterLast('/').replace("100.", "100s."))
            if (f.isFile) {
                val body = if (f.name == "100s.hea") f.readText(Charsets.ISO_8859_1).replace("100s", "100").toByteArray(Charsets.ISO_8859_1) else f.readBytes()
                ex.sendResponseHeaders(200, body.size.toLong())
                ex.responseBody.use { it.write(body) }
            } else {
                ex.sendResponseHeaders(404, -1)
                ex.close()
            }
        }
        server.start()
        try {
            val url = "http://127.0.0.1:${server.address.port}/files/mitdb/1.0.0/"
            val rec = Wfdb().readRecord("100", inputDir = url, network = true)
            assertEquals(21600, rec.nsamples)
        } finally {
            server.stop(0)
        }
    }

    @Test
    fun libraryFunctions() = example { d ->
        val w = Wfdb() // the library state
        w.wfdbx_set_input_dir(d.dir)
        val si = Array(2) { Siginfo() }
        val nsig = w.isigopen("100s", si, 2) // open 2 signals; si receives their specifications
        val v = IntArray(nsig)
        var n = 0
        while (w.getvec(v) > 0) { // v receives one sample per signal
            n++
        }

        val a = Annotation()
        w.annopen("100s", arrayOf(Anninfo("atr", WFDB_READ)), 1)
        while (w.getann(0, a) == 0) {
            println("${a.time} ${w.annstr(a.anntyp).latin1()}")
        }
        w.wfdbquit()
        assertEquals(21600, n)
        assertTrue(out.toString().startsWith("18 +\n77 N\n370 N\n"))
    }
}
