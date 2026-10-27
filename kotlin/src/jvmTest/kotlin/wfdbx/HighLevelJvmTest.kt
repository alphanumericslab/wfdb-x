// JVM tests of the high-level API: the top-level functions (on the default
// instance, in a thread of their own), the input options and network
// access against a local HTTP server (ports of the high-level parts of
// python/tests/test_files.py and rust/tests/network.rs), and the parts of
// python/tests/test_check.py that do not need the corpus.
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
import java.nio.file.Files
import java.nio.file.Paths
import java.util.Collections
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class HighLevelJvmTest {
    /** Runs [f] in a new thread (with a fresh default instance), rethrowing its failure. */
    private fun inThread(f: () -> Unit) {
        var failure: Throwable? = null
        val t = Thread {
            try {
                f()
            } catch (e: Throwable) {
                failure = e
            }
        }
        t.start()
        t.join()
        failure?.let { throw it }
    }

    @Test
    fun topLevelFunctions() = inThread {
        val d = DataDir("toplevel")
        try {
            assertEquals(null, wfdbxSetInputDir(d.dir))
            wfdbxSetOutputDir(d.dir)
            assertEquals(d.dir, wfdbxGetInputDir())
            assertEquals(d.dir, wfdbxGetOutputDir())
            assertFalse(wfdbxGetNetwork())
            assertFalse(wfdbxGetLegacy())
            assertEquals(2, readHeader("100s").nsig)
            val r = readRecord("100s", to = TimeSpec("0:10"), physical = true)
            assertEquals(3600, r.nsamples)
            assertEquals(75, readAnnotations("100s", "atr").size)
            writeRecord("dflt", r.samples, r.nsig, r.fs, gains = r.gains.toDoubleArray(), adcres = intArrayOf(12), units = listOf("mV"), names = r.names)
            assertEquals(r.samples.toList(), readRecord("dflt").samples.toList())
            writeRecord("dflp", r.physical!!, r.nsig, r.fs, gains = r.gains.toDoubleArray(), baselines = r.baselines.toIntArray(), adcres = intArrayOf(11), units = listOf("mV"))
            assertEquals(r.samples.toList(), readRecord("dflp").samples.toList())
            writeAnnotations("dflt", "a", longArrayOf(1, 2), symbols = listOf("N", "V"))
            writeAnnotations("dflt", "b", readAnnotations("dflt", "a"))
            assertEquals(listOf("N", "V"), readAnnotations("dflt", "b").symbols)
            assertEquals(listOf("warning: annotator 1: the annotator name consists only of digits", "error: annotator 1: the annotation file cannot be read"), checkRecord("dflt", listOf("1")).lines())
            assertTrue(checkRecord("dflt", listOf("a")).ok)
            assertFalse(wfdbxSetLegacy(true))
            assertTrue(wfdbxSetLegacy(false))
            assertFalse(wfdbxSetNetwork(true))
            assertTrue(wfdbxSetNetwork(false))
        } finally {
            wfdbquit()
            d.remove()
        }
    }

    /** Runs [f] with a fresh copy of the test data, where [target] is a link to /dev/full (on which every write fails); skipped without /dev/full. */
    private fun withFull(target: String, f: (DataDir, Wfdb) -> Unit) {
        if (!File("/dev/full").exists()) return
        val d = DataDir("wrerr")
        val w = d.wfdb()
        try {
            Files.createSymbolicLink(Paths.get(d.path(target)), Paths.get("/dev/full"))
            w.wfdbquiet()
            f(d, w)
        } finally {
            w.wfdbquit()
            d.remove()
        }
    }

    @Test
    fun writeRecordWriteError() {
        // A signal file or header that cannot be written throws an error, in
        // both modes, after the library's messages.
        for (target in listOf("full.dat", "full.hea")) {
            for (n in listOf(10, 100000)) {
                for (legacy in listOf(false, true)) {
                    withFull(target) { _, w ->
                        val before = wfdbx_write_errors()
                        val e = assertFailsWith<WfdbException> {
                            w.writeRecord("full", IntArray(2 * n), 2, 250.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(16), units = listOf("mV"), legacy = legacy)
                        }
                        assertEquals("write error on record full", e.message)
                        assertTrue(wfdbx_write_errors() > before)
                        assertTrue(w.wfdberror().latin1().startsWith("osigclose: write error"), w.wfdberror().latin1())
                    }
                }
            }
        }
    }

    @Test
    fun writeAnnotationsWriteError() {
        // An annotation file that cannot be written throws an error, in both
        // modes, after the library's message.
        for (n in listOf(3, 100000)) {
            for (legacy in listOf(false, true)) {
                withFull("100s.full") { _, w ->
                    val before = wfdbx_write_errors()
                    val e = assertFailsWith<WfdbException> {
                        w.writeAnnotations("100s", "full", LongArray(n) { it + 1L }, symbols = List(n) { "N" }, legacy = legacy)
                    }
                    assertEquals("write error on annotator full for record 100s", e.message)
                    assertTrue(wfdbx_write_errors() > before)
                    assertEquals("oannclose: write error on annotation file full\n", w.wfdberror().latin1())
                }
            }
        }
    }

    @Test
    fun noteWriteError() {
        val before = wfdbx_write_errors()
        wfdbx_note_write_error()
        assertEquals(before + 1, wfdbx_write_errors())
    }

    /** A local HTTP server serving the files of [dir] (and /redirect/X: a redirect to /X), logging the paths requested. */
    private class Server(dir: String) : AutoCloseable {
        val log: MutableList<String> = Collections.synchronizedList(ArrayList())
        private val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val url: String

        init {
            server.createContext("/") { ex ->
                val path = ex.requestURI.path
                log.add(path)
                val f = File(dir + path)
                when {
                    path.startsWith("/redirect/") -> {
                        ex.responseHeaders.add("Location", path.removePrefix("/redirect"))
                        ex.sendResponseHeaders(302, -1)
                        ex.close()
                    }
                    f.isFile -> {
                        val body = f.readBytes()
                        ex.sendResponseHeaders(200, body.size.toLong())
                        ex.responseBody.use { it.write(body) }
                    }
                    else -> {
                        ex.sendResponseHeaders(404, -1)
                        ex.close()
                    }
                }
            }
            server.start()
            url = "http://127.0.0.1:${server.address.port}/"
        }

        override fun close() = server.stop(0)
    }

    @Test
    fun networkAndInputOptions() {
        val d = DataDir("hlnet")
        val www = makeTempDir("hlnet-www")
        try {
            for (f in listOf("100s.hea", "100s.dat", "100s.atr")) writeFile("$www/$f", d.read(f)!!)
            writeFile("$www/sub/rec.hea", "rec 1 360 10\ndata/a.dat 16\n")
            writeFile("$www/sub/data/a.dat", d.read("fmt16.dat")!!)
            writeFile("$www/sub/bad.hea", "bad 1 360 10\n../100s.dat 16\n")
            Server(www).use { srv ->
                val w = Wfdb()
                w.wfdbquiet()
                w.wfdbxSetInputDir(d.path("elsewhere"))
                // network access is off by default
                assertFailsWith<WfdbException> { w.readRecord(srv.url + "100s", to = TimeSpec(3)) }
                assertTrue(srv.log.isEmpty())
                // network = true for one call
                val r = w.readRecord(srv.url + "100s", to = TimeSpec(3), network = true)
                assertEquals(listOf(995, 1011, 995, 1011, 995, 1011), r.samples.toList())
                assertFalse(w.wfdbxGetNetwork())
                w.wfdbxSetNetwork(true)
                assertEquals(75, w.readAnnotations(srv.url + "100s", "atr").size)
                // each URL is requested once (the .info file and its 8.3 form do not exist)
                assertEquals(listOf("/100s.hea", "/100s.dat", "/100s.info", "/100s.inf", "/100s.atr"), srv.log.toList())
                // the input directory as a URL; files named in a header are read from its directory
                assertEquals(1, w.readRecord("100s", to = TimeSpec(1), inputDir = srv.url).nsamples)
                assertEquals(5, srv.log.size) // (cached)
                assertEquals(listOf(-7, 32), w.readRecord("rec", to = TimeSpec(2), inputDir = srv.url + "sub").samples.toList())
                assertTrue("/sub/data/a.dat" in srv.log)
                assertFailsWith<WfdbException> { w.readRecord("bad", inputDir = srv.url + "sub") }
                assertFalse("/100s.dat" in srv.log.drop(5) || "/sub/../100s.dat" in srv.log)
                assertFailsWith<WfdbException> { w.readRecord("nosuch", inputDir = srv.url) } // 404
                // redirects are followed
                assertEquals(listOf(995, 1011), w.readRecord(srv.url + "redirect/100s", to = TimeSpec(1)).samples.toList())
                // network = false forbids it for the call; null keeps the setting
                assertFailsWith<WfdbException> { w.readHeader(srv.url + "100s", network = false) }
                assertTrue(w.wfdbxGetNetwork())
                assertEquals(2, w.readHeader(srv.url + "100s").nsig)
                assertEquals(d.path("elsewhere"), w.wfdbxGetInputDir()) // restored
                // also on errors
                w.wfdbxSetNetwork(false)
                assertFailsWith<WfdbException> { w.readRecord("nosuch", inputDir = d.dir, network = true) }
                assertEquals(Pair(d.path("elsewhere"), false), Pair(w.wfdbxGetInputDir(), w.wfdbxGetNetwork()))
                // checkRecord takes the same options
                assertEquals(
                    listOf("warning: signal 0: the units are not specified", "warning: signal 1: the units are not specified"),
                    w.checkRecord("100s", listOf("atr"), inputDir = srv.url, network = true).lines(),
                )
                // a URL cannot be written; the output directory and the input directory are independent
                assertFailsWith<WfdbException> { w.writeAnnotations(srv.url + "x", "a", longArrayOf(1), codes = intArrayOf(1)) }
                w.writeAnnotations("w1", "q", longArrayOf(1, 2), symbols = listOf("N", "N"), dir = d.dir)
                assertEquals(2, w.readAnnotations("w1", "q", inputDir = d.dir, fs = 100.0).size)
                // legacy mode reads no remote files
                assertFailsWith<WfdbException> { w.readRecord(srv.url + "100s", network = true, legacy = true) }
            }
        } finally {
            removeTree(www)
            d.remove()
        }
    }

    @Test
    fun checkArgumentsAndSampleRecord() {
        val w = Wfdb()
        assertFailsWith<WfdbException> { w.checkRecord("") }
        // the sample record: its header gives no units (as in the MIT-BIH
        // Arrhythmia Database), which is all that is reported
        val r = w.checkRecord("100s", listOf("atr"), inputDir = testDataDir())
        assertTrue(r.ok)
        assertEquals(listOf("warning: signal 0: the units are not specified", "warning: signal 1: the units are not specified"), r.lines())
        assertEquals("100s", r.record)
        assertEquals(Issue(Severity.WARNING, "units_missing", "signal 0", "the units are not specified"), r.issues[0])
        assertEquals("warning", Severity.WARNING.text)
    }

    @Test
    fun checkFileLarge() {
        // a signal file of more than 2^31 - 1 bytes: its size is simulated
        val d = DataDir("checkbig")
        try {
            val w = Wfdb()
            w.writeRecord("big", IntArray(100) { it }, 1, 100.0, gains = doubleArrayOf(100.0), adcres = intArrayOf(16), units = listOf("mV"), names = listOf("ECG"), dir = d.dir)
            assertEquals(listOf("no problems found"), w.checkRecord("big", inputDir = d.dir).lines())
            checkSimulatedFileSize = 1L shl 31
            val r = try {
                w.checkRecord("big", inputDir = d.dir)
            } finally {
                checkSimulatedFileSize = null
            }
            assertEquals(listOf("warning: the signal file \"big.dat\" has more than 2147483647 bytes, which 32-bit applications cannot handle"), r.lines())
            assertTrue(r.ok)
        } finally {
            d.remove()
        }
    }

    @Test
    fun checkFormatting() {
        assertEquals("\"a\\x09b\\x7f\\xe9\"c\"", checkQuote("a\tb\u007fé\"c".toByteArray(Charsets.ISO_8859_1)))
        assertEquals("\"\"", checkQuote(null))
        assertTrue(listOf("12", "-1.5", "+.5").all { checkIsNumber(it.toByteArray()) })
        assertTrue(listOf("1.2.3", "V5", "-", "", ".").none { checkIsNumber(it.toByteArray()) })
        assertEquals(listOf("200.5", "1e+06", "360"), listOf(checkG(200.5), checkG(1e6), checkG(360.0)))
        assertEquals(listOf(-1L, -32768L, 5L), listOf(checkInt16(65535), checkInt16(32768), checkInt16(5)))
        val issues = ArrayList<Issue>()
        checkText(HeaderText("/a/2 1 360\n".toByteArray(), "/a".toByteArray(), ByteArray(0)), "", issues)
        assertTrue(issues.isEmpty())
        checkText(HeaderText("# c\nb/2 1 360\n".toByteArray(), "/a".toByteArray(), ByteArray(0)), "", issues)
        assertEquals("the header names the record \"b\", but its file name is \"/a\"", issues[0].message)
    }
}
