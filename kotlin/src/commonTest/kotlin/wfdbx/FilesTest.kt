// WFDB-x: files named in headers (normal mode: in the header's directory,
// and their containment), multi-segment records, legacy mode unchanged
// (the signal parts of rust/tests/files.rs, written with the C-style
// functions; the other parts are in WfdbioTest.kt).
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
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FilesTest {
    private fun quiet(dir: String): Wfdb {
        val w = Wfdb()
        w.wfdbquiet()
        w.wfdbx_set_input_dir(dir)
        w.wfdbx_set_output_dir(dir)
        return w
    }

    /** All the samples of a record (null if its signals cannot be read). */
    private fun samples(w: Wfdb, rec: String): List<Int>? {
        val n = w.isigopen(rec, null, 0)
        if (n <= 0) return null
        if (w.isigopen(rec, Array(n) { Siginfo() }, n) != n) {
            w.wfdbquit()
            return null
        }
        val buf = IntArray(n * 100000)
        val r = ArrayList<Int>()
        while (true) {
            val res = w.getvecs_status(buf, 100000)
            for (i in 0 until maxOf(res.count, 0L).toInt() * n) r.add(buf[i])
            if (res.count < 100000) {
                w.wfdbquit()
                return if (res.status < -1) null else r
            }
        }
    }

    /** A header naming its signal file [fname], and a 4-sample signal file db/data/a.dat. */
    private fun header(dir: String, rec: String, fname: String) {
        writeFile("$dir/db/$rec.hea", "$rec 1 100 4\n$fname 16 200/mV 16 0 1 10 0 x\n")
        writeFile("$dir/db/data/a.dat", byteArrayOf(1, 0, 2, 0, 3, 0, 4, 0))
    }

    @Test
    fun filesNamedInHeaders() {
        val dir = makeTempDir("hdr")
        header(dir, "rec", "data/a.dat")
        writeFile("$dir/data/a.dat", byteArrayOf(1, 0, 3, 0, 2, 0, 4, 0)) // (legacy mode only)
        val w = quiet(dir)
        assertEquals(listOf(1, 2, 3, 4), samples(w, "db/rec"))
        val w2 = quiet("$dir/db")
        assertEquals(listOf(1, 2, 3, 4), samples(w2, "rec"))
        for (name in listOf("../a.dat", "data/../data/a.dat", "$dir/db/data/a.dat", "~/a.dat", "http://127.0.0.1:9/a.dat")) {
            header(dir, "bad", name)
            // the header can be read; its signal file is refused
            assertEquals(1, w.isigopen("db/bad", null, 0), name)
            assertEquals(0, w.isigopen("db/bad", null, 1), name)
            assertEquals("isigopen: none of the signals for record db/bad is readable\n", w.wfdberror().latin1())
            w.wfdbquit()
            assertNull(w.wfdbx_open_in("$dir/db/".latin1(), null, name.latin1(), "db/bad".latin1()))
            assertEquals(
                "init: file $name named in the header of record db/bad is not in the header's directory\n",
                w.wfdberror().latin1(),
            )
        }
        // names that stay inside are fine
        for (name in listOf("./data/a.dat", "data//a.dat")) {
            header(dir, "ok", name)
            assertEquals(listOf(1, 2, 3, 4), samples(w, "db/ok"), name)
        }
        // legacy mode: the WFDB path is searched (the directory of the
        // header first, as C adds it to the front of the path, then the
        // others: here the signal file is found in the path's directory,
        // since there is none next to the header)
        w.wfdbx_set_legacy(1)
        w.setwfdb(dir)
        header(dir, "rec", "data/a.dat")
        assertEquals(listOf(1, 2, 3, 4), samples(w, "db/rec"))
        w.wfdbquit()
        w.setwfdb(dir)
        removeTree("$dir/db/data")
        assertEquals(listOf(1, 3, 2, 4), samples(w, "db/rec"))
        w.wfdbx_set_legacy(0)
        removeTree(dir)
    }

    @Test
    fun multiSegmentRecords() {
        val dir = makeTempDir("multi")
        val data = testDataDir()
        for (f in listOf("multi.hea", "100s.hea", "100s.dat", "null.hea")) writeFile("$dir/db/$f", readFile("$data/$f")!!)
        writeFile("$dir/db/gap.hea", "gap/2 2 360 23400\n100s 21600\n~ 1800\n")
        writeFile("$dir/db/out.hea", "out/2 2 360 23400\n100s 21600\n../100s 1800\n")
        writeFile("$dir/100s.hea", readFile("$data/100s.hea")!!)
        writeFile("$dir/100s.dat", readFile("$data/100s.dat")!!)
        val w = quiet(dir)
        val local = samples(w, "100s")!!
        val n = local.size
        val r = samples(w, "db/multi")!!
        assertEquals(2 * 45000, r.size)
        assertEquals(local, r.subList(0, n))
        assertEquals(local, r.subList(r.size - n, r.size))
        // a "~" segment is a gap
        val g = samples(w, "db/gap")!!
        assertEquals(2 * 23400, g.size)
        assertEquals(WFDB_INVALID_SAMPLE, g[n])
        // a segment outside the header's directory is refused
        val si = Array(2) { Siginfo() }
        assertEquals(2, w.isigopen("db/out", si, 2))
        val x = IntArray(2)
        assertEquals(-1, w.isigsettime(21600))
        assertTrue(w.getvec(x) < 0)
        w.wfdbquit()
        // ... and reading through to it ends with an error
        assertNull(samples(w, "db/out"))
        removeTree(dir)
    }
}
