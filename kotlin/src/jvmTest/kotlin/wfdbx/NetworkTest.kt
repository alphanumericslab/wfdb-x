// Tests of network access on the JVM (HttpURLConnection) against a local
// HTTP server (a port of rust/tests/network.rs, with the C-style
// functions in place of the high-level API).
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
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NetworkTest {
    @Test
    fun urls() {
        val requests = AtomicInteger()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { ex ->
            requests.incrementAndGet()
            val path = ex.requestURI.path
            when {
                path == "/db/rec.hea" -> {
                    val body = "rec 0\n".latin1()
                    ex.sendResponseHeaders(200, body.size.toLong())
                    ex.responseBody.use { it.write(body) }
                }
                path == "/moved/rec.hea" -> {
                    ex.responseHeaders.add("Location", "/db/rec.hea")
                    ex.sendResponseHeaders(302, -1)
                    ex.close()
                }
                else -> {
                    ex.sendResponseHeaders(404, -1)
                    ex.close()
                }
            }
        }
        server.start()
        try {
            val base = "http://127.0.0.1:${server.address.port}"
            val w = Wfdb()
            w.wfdbquiet()
            w.wfdbx_set_network(1)
            w.wfdbx_set_input_dir("$base/db/")
            val f = w.wfdb_open("hea", "rec", WFDB_READ)
            assertNotNull(f)
            assertEquals(WFDB_NET, f.fileType())
            assertEquals("rec 0\n", f.readToEnd().latin1())
            f.close()
            assertEquals("$base/db/rec.hea", w.wfdb_filename().latin1())
            // fetched once per process
            val n = requests.get()
            w.wfdb_open("hea", "rec", WFDB_READ)!!.close()
            assertEquals(n, requests.get())
            // redirects are followed; a status of 400 or more is a failure
            assertEquals("rec 0\n", w.wfdb_open("hea", "$base/moved/rec", WFDB_READ)!!.readToEnd().latin1())
            assertNull(w.wfdb_open("hea", "nosuch", WFDB_READ))
            // remote files are read-only; legacy mode reads no URLs
            assertNull(w.wfdb_fopen("$base/db/x".latin1(), "wb"))
            w.wfdbx_set_legacy(1)
            assertNull(w.wfdb_fopen("$base/db/rec.hea".latin1(), "rb"))
            w.wfdbx_set_legacy(0)
            // network access off
            w.wfdbx_set_network(0)
            assertNull(w.wfdb_open("hea", "$base/db/rec", WFDB_READ))
        } finally {
            server.stop(0)
        }
    }

    /** All the samples of a record (null if its signals cannot be read to the end). */
    private fun samples(w: Wfdb, rec: String): List<Int>? {
        val n = w.isigopen(rec, null, 0)
        if (n <= 0 || w.isigopen(rec, Array(n) { Siginfo() }, n) != n) {
            w.wfdbquit()
            return null
        }
        val buf = IntArray(n * 50000)
        val r = ArrayList<Int>()
        while (true) {
            val res = w.getvecs_status(buf, 50000)
            for (i in 0 until maxOf(res.count, 0L).toInt() * n) r.add(buf[i])
            if (res.count < 50000) {
                w.wfdbquit()
                return if (res.status < -1) null else r
            }
        }
    }

    @Test
    fun remoteRecords() {
        val log = Collections.synchronizedList(ArrayList<String>())
        val data = File(testDataDir())
        val extra = mapOf(
            "/db/sub.hea" to "sub 1 100 4\ndata/a.dat 16 200/mV 16 0 1 10 0 x\n",
            "/db/esc.hea" to "esc 1 100 4\n../a.dat 16 200/mV 16 0 1 10 0 x\n",
        )
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { ex ->
            val path = ex.requestURI.path
            log.add(path)
            val body: ByteArray? = when {
                extra.containsKey(path) -> extra[path]!!.latin1()
                path == "/db/data/a.dat" || path == "/a.dat" -> byteArrayOf(1, 0, 2, 0, 3, 0, 4, 0)
                path.startsWith("/db/") && File(data, path.substring(4)).isFile -> File(data, path.substring(4)).readBytes()
                else -> null
            }
            if (body == null) {
                ex.sendResponseHeaders(404, -1)
                ex.close()
            } else {
                ex.sendResponseHeaders(200, body.size.toLong())
                ex.responseBody.use { it.write(body) }
            }
        }
        server.start()
        try {
            val db = "http://127.0.0.1:${server.address.port}/db/"
            fun count(p: String) = synchronized(log) { log.count { it == p } }
            val local = Wfdb()
            local.wfdbquiet()
            local.wfdbx_set_input_dir(testDataDir())
            val ref = samples(local, "100s")!!
            val w = Wfdb()
            w.wfdbquiet()
            w.wfdbx_set_network(1)
            // a URL as the record name: the signal file next to it
            assertEquals(ref, samples(w, "${db}100s"))
            // the input directory as a URL
            w.wfdbx_set_input_dir(db)
            assertEquals(ref, samples(w, "100s"))
            assertEquals(1, count("/db/100s.hea"))
            assertEquals(1, count("/db/100s.dat"))
            assertEquals(360.0, w.sampfreq("100s"))
            assertEquals(" 69 M 1085 1629 x1", w.getinfo("100s")?.latin1())
            // files named in a remote header: in its directory (at its URL)
            assertEquals(listOf(1, 2, 3, 4), samples(w, "sub"))
            assertEquals(1, count("/db/data/a.dat"))
            assertNull(samples(w, "esc"))
            assertEquals(0, count("/a.dat"))
            // a remote multi-segment record (its segments at the same URL)
            assertEquals(2 * 45000, samples(w, "multi")!!.size)
            // a missing header (the failure is kept: fetched once)
            assertTrue(w.isigopen("nosuch", null, 0) < 0)
            assertTrue(w.isigopen("nosuch", null, 0) < 0)
            assertEquals(1, count("/db/nosuch.hea"))
            // no network access: nothing is fetched
            val n = log.size
            val w2 = Wfdb()
            w2.wfdbquiet()
            w2.wfdbx_set_network(0)
            w2.wfdbx_set_input_dir(db)
            assertTrue(w2.isigopen("fresh", null, 0) < 0)
            assertEquals(n, log.size)
            // an output signal file cannot be a URL
            assertEquals(-3, w.osigfopen(arrayOf(Siginfo(fname = "${db}o.dat".latin1(), desc = "x".latin1(), fmt = 16, gain = 1.0)), 1))
        } finally {
            server.stop(0)
        }
    }
}
