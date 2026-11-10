// JVM tests of the temporary files of WFDB-x 1.2.2: the files that replace a
// header (the metadata functions) and the files of writeRecord and
// writeAnnotations are created readable and writable by their owner only,
// then given the permissions of the file they replace (or of a new file),
// and a symbolic link is kept, its target replaced.
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
import wfdbx.cstd.latin1
import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.attribute.PosixFilePermissions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TempFilesJvmTest {
    private fun posix(): Boolean = "posix" in java.nio.file.FileSystems.getDefault().supportedFileAttributeViews()

    private fun perms(p: Path): String = PosixFilePermissions.toString(Files.getPosixFilePermissions(p))

    private fun setPerms(p: Path, s: String) = Files.setPosixFilePermissions(p, PosixFilePermissions.fromString(s))

    /** The permissions of a new file in [dir] (0666 less the umask). */
    private fun newFilePerms(dir: String): String {
        val probe = Paths.get(dir, "probe.new")
        Files.deleteIfExists(probe)
        Files.createFile(probe)
        val s = perms(probe)
        Files.delete(probe)
        return s
    }

    @Test
    fun ownerOnlyAtCreation() {
        if (!posix()) return
        val d = makeTempDir("tmpmode")
        try {
            val tmp = Platform.createTempFile("$d/rec.hea".latin1())!!.latin1()
            val name = File(tmp).name
            assertTrue(name.startsWith(".rec.hea.") && name.endsWith(".tmp") && name.length == ".rec.hea.".length + 12, name)
            assertEquals(d, File(tmp).parent)
            assertEquals("rw-------", perms(Paths.get(tmp)))
            assertEquals(0L, File(tmp).length())
            Files.delete(Paths.get(tmp))
        } finally {
            removeTree(d)
        }
    }

    @Test
    fun headerModeKept() {
        if (!posix()) return
        val d = makeTempDir("tmphea")
        try {
            // a 0600 header stays 0600; a 0644 one stays 0644
            val rec = copyMetaHeader("basic", d)
            val p = Paths.get("$rec.hea")
            for (mode in listOf("rw-------", "rw-r--r--", "rw-rw----")) {
                setPerms(p, mode)
                Wfdb().setMetadata(rec, "Age", "6" + mode.length)
                assertEquals(mode, perms(p))
            }
            assertEquals(emptyList(), File(d).list()!!.filter { it.endsWith(".tmp") })
        } finally {
            removeTree(d)
        }
    }

    @Test
    fun writersTemporaryFiles() {
        if (!posix()) return
        val d = DataDir("tmpwrite")
        val w = d.wfdb()
        try {
            val x = IntArray(20) { it }
            fun write(rec: String) =
                w.writeRecord(rec, x, 2, 250.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("mV"))
            // while the files are written, the temporary files are owner-only
            val seen = ArrayList<String>()
            w.io.testNewheader = { rec ->
                val status = w.newheader(rec)
                for (f in File(d.dir).listFiles()!!) if (f.name.endsWith(".tmp")) seen.add(f.name + " " + perms(f.toPath()))
                status
            }
            try {
                write("r")
            } finally {
                w.io.testNewheader = null
            }
            assertEquals(2, seen.size, seen.toString()) // (the signal file and the header)
            for (s in seen) assertTrue(s.endsWith(" rw-------"), s)
            // the new files have the permissions of any new file
            val fresh = newFilePerms(d.dir)
            assertEquals(fresh, perms(Paths.get(d.path("r.dat"))))
            assertEquals(fresh, perms(Paths.get(d.path("r.hea"))))
            // the permissions of the files they replace are kept
            setPerms(Paths.get(d.path("r.dat")), "rw-r-----")
            setPerms(Paths.get(d.path("r.hea")), "rw-------")
            write("r")
            assertEquals("rw-r-----", perms(Paths.get(d.path("r.dat"))))
            assertEquals("rw-------", perms(Paths.get(d.path("r.hea"))))
            // a symbolic link: its target is replaced, the link is kept
            File(d.path("real")).mkdir()
            write("real/s")
            Files.createSymbolicLink(Paths.get(d.path("s.hea")), Paths.get("real/s.hea"))
            Files.createSymbolicLink(Paths.get(d.path("s.dat")), Paths.get(d.path("real/s.dat")))
            val y = IntArray(20) { 2 * it }
            w.writeRecord("s", y, 2, 250.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("mV"))
            assertTrue(Files.isSymbolicLink(Paths.get(d.path("s.hea"))))
            assertTrue(Files.isSymbolicLink(Paths.get(d.path("s.dat"))))
            assertEquals(y.toList(), w.readRecord("real/s").samples.toList())
            // annotations: owner-only while written, then the mode kept
            w.writeAnnotations("r", "qrs", longArrayOf(10, 20), symbols = listOf("N", "N"))
            setPerms(Paths.get(d.path("r.qrs")), "rw-------")
            w.writeAnnotations("r", "qrs", longArrayOf(30, 10, 20), symbols = listOf("N", "V", "N"))
            assertEquals("rw-------", perms(Paths.get(d.path("r.qrs"))))
            assertEquals(listOf(10L, 20L, 30L), w.readAnnotations("r", "qrs", fs = 250.0).samples.toList())
            assertEquals(emptyList(), File(d.dir).walk().filter { it.name.endsWith(".tmp") }.map { it.name }.toList())
        } finally {
            w.wfdbquit()
            d.remove()
        }
    }

    @Test
    fun specialFileWrittenDirectly() {
        // a destination that is not a regular file (here /dev/null) is
        // opened directly, as before (no temporary file in /dev)
        if (!File("/dev/null").exists() || !posix()) return
        val w = Wfdb()
        val d = makeTempDir("tmpdev")
        try {
            Files.createSymbolicLink(Paths.get("$d/n.qrs"), Paths.get("/dev/null"))
            w.writeAnnotations("$d/n", "qrs", longArrayOf(1, 2), symbols = listOf("N", "N"))
            assertTrue(Files.isSymbolicLink(Paths.get("$d/n.qrs")))
            assertEquals(listOf("n.qrs"), File(d).list()!!.toList())
        } finally {
            w.wfdbquit()
            removeTree(d)
        }
    }
}
