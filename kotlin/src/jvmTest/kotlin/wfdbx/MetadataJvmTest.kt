// JVM tests of the header metadata functions: the permissions of a changed
// header, and a header read from a URL, served by a local HTTP server
// (127.0.0.1) (the parts of python/tests/test_metadata.py that need them;
// the rest is in commonTest/MetadataTest.kt).
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
import java.io.File
import java.net.InetSocketAddress
import java.nio.file.Files
import java.nio.file.Paths
import java.nio.file.attribute.PosixFilePermissions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

class MetadataJvmTest {
    private fun posix(): Boolean = "posix" in java.nio.file.FileSystems.getDefault().supportedFileAttributeViews()

    @Test
    fun permissionsKept() {
        if (!posix()) return
        val d = makeTempDir("metaperm")
        try {
            val rec = copyMetaHeader("basic", d)
            val p = Paths.get("$rec.hea")
            Files.setPosixFilePermissions(p, PosixFilePermissions.fromString("rw-r-----"))
            Wfdb().setMetadata(rec, "Age", "64")
            assertEquals("rw-r-----", PosixFilePermissions.toString(Files.getPosixFilePermissions(p)))
            assertEquals("64", Wfdb().getMetadata(rec, "Age"))
            // a header written to dir with no header of that name there: the
            // permissions of a new file (the umask applies)
            val out = "$d/out"
            File(out).mkdir()
            writeFile("$d/probe", "")
            Wfdb().setMetadata(rec, "Age", "65", dir = out)
            assertEquals(
                Files.getPosixFilePermissions(Paths.get("$d/probe")),
                Files.getPosixFilePermissions(Paths.get("$out/basic.hea")),
            )
            assertEquals(listOf("basic.hea"), listFiles(out))
        } finally {
            removeTree(d)
        }
    }

    @Test
    fun url() {
        val d = makeTempDir("metaurl")
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { ex ->
            val f = File(d + ex.requestURI.path)
            if (f.isFile) {
                val body = f.readBytes()
                ex.sendResponseHeaders(200, body.size.toLong())
                ex.responseBody.use { it.write(body) }
            } else {
                ex.sendResponseHeaders(404, -1)
                ex.close()
            }
        }
        server.start()
        try {
            copyMetaHeader("basic", d)
            val url = "http://127.0.0.1:${server.address.port}/basic"
            val w = Wfdb()
            w.wfdbxSetNetwork(false)
            w.wfdbquiet()
            val e = assertFailsWith<WfdbException> { w.readMetadata(url) } // network off
            assertFalse(e is WfdbArgumentException)
            assertEquals("63", w.getMetadata(url, "Age", network = true))
            assertFalse(w.wfdbxGetNetwork()) // (for that call only)
            assertEquals(
                "header of record $url was read from a URL, and cannot be changed (give dir to write the changed header to a local directory)",
                assertFailsWith<WfdbArgumentException> { w.setMetadata(url, "Age", "1", network = true) }.message,
            )
            File("$d/copy").mkdir()
            w.setMetadata(url, "Age", "1", network = true, dir = "$d/copy")
            assertEquals("1", w.getMetadata("$d/copy/basic", "Age"))
            assertEquals("63", w.getMetadata("$d/basic", "Age"))
            // readHeader gives the metadata of a header read from a URL too
            assertEquals("63", w.readHeader(url, network = true).metadata.first { it.first == "Age" }.second)
        } finally {
            server.stop(0)
            removeTree(d)
        }
    }
}
