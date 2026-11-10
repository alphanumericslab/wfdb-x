// Tests of the header metadata functions (readMetadata, getMetadata,
// setMetadata, removeMetadata, updateMetadata) and of the metadata of
// readHeader and writeRecord (port of python/tests/test_metadata.py; the
// permissions and a URL are tested in jvmTest/MetadataJvmTest.kt).
//
// The shared cases (tests/metadata/cases.tsv, with the expected headers in
// tests/metadata/expected/) are run by every implementation of WFDB-x, which
// must give the same results and write byte-identical headers.
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

import wfdbx.cstd.latin1
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The directory tests/metadata of the repository. */
internal fun metadataDir(): String = testDataDir().removeSuffix("/").removeSuffix("data") + "metadata"

/** Copies tests/metadata/headers/NAME.hea into [dir]; returns the record name (a full path). */
internal fun copyMetaHeader(name: String, dir: String): String {
    writeFile("$dir/$name.hea", readFile("${metadataDir()}/headers/$name.hea")!!)
    return "$dir/$name"
}

class MetadataTest {
    /** A string of cases.tsv: "x" + hexadecimal bytes, or "-" (null). */
    private fun str(f: String): String? = if (f == "-") null else unhex(f.substring(1)).latin1()

    /** A list of KEY:VALUE pairs of cases.tsv. */
    private fun pairs(f: String): List<Pair<String, String?>> =
        if (f.isEmpty()) emptyList() else f.split(',').map { val (k, v) = it.split(':'); Pair(str(k)!!, str(v)) }

    @Test
    fun sharedCases() {
        val lines = readFile("${metadataDir()}/cases.tsv")!!.latin1().split('\n').filter { it.isNotEmpty() && !it.startsWith("#") }
        assertEquals(56, lines.size)
        for (line in lines) {
            val c = line.split('\t')
            assertEquals(10, c.size, line)
            val (name, header, op) = c
            val d = makeTempDir("meta")
            try {
                val rec = copyMetaHeader(header, d)
                val before = readFile("$rec.hea")!!
                val w = Wfdb()
                var warnings = 0
                val warn: (String) -> Unit = { warnings++ }
                var error = "-"
                var result = "-"
                try {
                    when (op) {
                        "read" -> result = w.readMetadata(rec, onWarning = warn)
                            .joinToString(",") { "x" + hex(it.first.latin1()) + ":x" + hex(it.second.latin1()) }
                        "get" -> result = w.getMetadata(rec, str(c[3])!!, onWarning = warn)?.let { "x" + hex(it.latin1()) } ?: "-"
                        "set" -> w.setMetadata(rec, str(c[3])!!, str(c[4])!!)
                        "remove" -> result = w.removeMetadata(rec, str(c[3])!!).toString()
                        "update" -> w.updateMetadata(rec, pairs(c[5]))
                        else -> error("unknown operation $op")
                    }
                } catch (e: WfdbArgumentException) {
                    error = "argument"
                } catch (e: WfdbException) {
                    error = "file"
                }
                assertEquals(c[6], error, name)
                assertEquals(c[7].toInt(), warnings, "$name: warnings")
                if (error == "-") assertEquals(c[8], result, name)
                val after = readFile("$rec.hea")!!
                if (c[9] != "-") {
                    assertContentEquals(readFile("${metadataDir()}/${c[9]}")!!, after, name)
                } else {
                    assertContentEquals(before, after, "$name: the header changed")
                }
                // no temporary file is left behind
                assertEquals(listOf("$header.hea"), listFiles(d), name)
            } finally {
                removeTree(d)
            }
        }
    }

    @Test
    fun readHeaderAndWriteRecord() {
        val d = makeTempDir("metawr")
        try {
            val w = Wfdb()
            val x = IntArray(10)
            w.writeRecord(
                "w", x, 1, 100.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("mV"),
                comments = listOf("a comment", "Site: B"), dir = d, metadata = listOf("Age" to " 63 ", "Notes" to ""),
            )
            val data = readFile("$d/w.hea")!!.latin1()
            assertTrue(data.endsWith("#a comment\r\n#Site: B\r\n# Age: 63\r\n# Notes:\r\n"), data)
            val h = w.readHeader("w", inputDir = d)
            assertEquals(listOf("Site" to "B", "Age" to "63", "Notes" to ""), h.metadata)
            assertEquals(listOf("a comment", "Site: B", " Age: 63", " Notes:"), h.comments)
            w.writeRecord(
                "v", x, 1, 100.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("mV"),
                dir = d, metadata = mapOf("Dx" to "426783006").toList(),
            )
            assertEquals(listOf("Dx" to "426783006"), w.readMetadata("$d/v"))
            // the physical-units writer takes metadata too
            w.writeRecord(
                "p", DoubleArray(10), 1, 100.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12),
                units = listOf("mV"), dir = d, metadata = listOf("Sex" to "F"),
            )
            assertEquals("F", w.getMetadata("$d/p", "sex"))
        } finally {
            removeTree(d)
        }
    }

    @Test
    fun readHeaderMetadata() {
        val d = makeTempDir("metarh")
        try {
            val w = Wfdb()
            // the sample record: its info string is an entry
            assertEquals(
                listOf("Produced by xform from record 100, beginning at 0" to "0"),
                w.readHeader("100s", inputDir = testDataDir()).metadata,
            )
            // an EDF file has no .hea file: no metadata (and no error)
            val edf = w.readHeader("fmt16.edf", inputDir = testDataDir())
            assertEquals(emptyList(), edf.metadata)
            // a key given twice: the first, and one warning
            copyMetaHeader("dups", d)
            val warnings = ArrayList<String>()
            val h = w.readHeader("$d/dups", onWarning = { warnings.add(it) })
            assertEquals(listOf("age" to "40", "Sex" to "M", "Height" to "180"), h.metadata)
            assertEquals(1, warnings.size)
            assertTrue(warnings[0].startsWith("header of record $d/dups has more than one entry for key age (lines "), warnings[0])
            assertTrue(warnings[0].endsWith("); the first is used"), warnings[0])
        } finally {
            removeTree(d)
        }
    }

    @Test
    fun writeRecordMetadataErrors() {
        val d = makeTempDir("metawe")
        try {
            val w = Wfdb()
            fun write(md: List<Pair<String, String?>>, comments: List<String>? = null) = w.writeRecord(
                "e", IntArray(10), 1, 100.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12),
                units = listOf("mV"), comments = comments, dir = d, metadata = md,
            )
            val bad = listOf(
                listOf("a:b" to "1"), listOf("Age" to "1\n2"), listOf("Age" to "1", "AGE" to "2"),
                listOf("Age" to null), listOf("" to "x"),
            )
            for (md in bad) assertFailsWith<WfdbArgumentException> { write(md) }
            val e = assertFailsWith<WfdbArgumentException> { write(listOf("Age" to "2"), listOf("age: 1")) }
            assertEquals("writeRecord: metadata key 'age' is also given in comments", e.message)
            assertEquals(
                "writeRecord: metadata key 'a:b' must not contain ':'",
                assertFailsWith<WfdbArgumentException> { write(listOf("a:b" to "1")) }.message,
            )
            assertEquals(
                "writeRecord: value of metadata key 'Age' must not be null",
                assertFailsWith<WfdbArgumentException> { write(listOf("Age" to null)) }.message,
            )
            assertEquals(emptyList(), listFiles(d)) // nothing was written
        } finally {
            removeTree(d)
        }
    }

    @Test
    fun infoFileIgnored() {
        val d = makeTempDir("metainfo")
        try {
            val rec = copyMetaHeader("lf", d)
            writeFile("$rec.info", "#Age: 1\n")
            assertEquals(emptyList(), Wfdb().readMetadata(rec))
        } finally {
            removeTree(d)
        }
    }

    @Test
    fun inputDirAndDir() {
        val d = makeTempDir("metadir")
        try {
            val inp = "$d/in"
            val out = "$d/out"
            copyMetaHeader("basic", inp)
            writeFile("$out/x", "") // (creates the directory)
            val original = readFile("$inp/basic.hea")!!
            val w = Wfdb()
            assertEquals("F", w.getMetadata("basic", "Sex", inputDir = inp))
            w.wfdbxSetInputDir(inp)
            assertEquals("F", w.getMetadata("basic.hea", "sex"))
            w.setMetadata("basic", "Age", "64", dir = out)
            assertContentEquals(original, readFile("$inp/basic.hea"))
            assertEquals("64", w.getMetadata("$out/basic", "Age"))
            // an unchanged header is still written to dir
            assertEquals(0, w.removeMetadata("basic", "Weight", dir = out))
            assertContentEquals(original, readFile("$out/basic.hea"))
            val e = assertFailsWith<WfdbException> { w.setMetadata("basic", "Age", "1", dir = "$d/none") }
            assertFalse(e is WfdbArgumentException)
            assertEquals("directory $d/none does not exist", e.message)
            w.wfdbxSetInputDir(null)
            // the header is changed where it was read, not in the output directory
            w.wfdbxSetOutputDir(out)
            w.setMetadata("$inp/basic", "Age", "65")
            assertEquals("65", w.getMetadata("$inp/basic", "Age"))
            assertContentEquals(original, readFile("$out/basic.hea"))
            assertEquals(listOf("basic.hea"), listFiles(inp))
            assertEquals(listOf("basic.hea", "x"), listFiles(out))
            // the map form of updateMetadata, in its order
            w.updateMetadata("$inp/basic", linkedMapOf("Weight" to "72", "Age" to null, "sex" to "M"))
            assertNull(w.getMetadata("$inp/basic", "AGE"))
            assertEquals("M", w.getMetadata("$inp/basic", "Sex"))
            assertEquals("72", w.readMetadata("$inp/basic").last().second)
            assertFailsWith<WfdbArgumentException> { w.updateMetadata("$inp/basic", mapOf("Age" to null, "age" to "66")) }
        } finally {
            removeTree(d)
        }
    }

    @Test
    fun missingAndInvalid() {
        val d = makeTempDir("metainv")
        try {
            val w = Wfdb()
            val e = assertFailsWith<WfdbException> { w.readMetadata("$d/none") }
            assertFalse(e is WfdbArgumentException)
            assertEquals("can't read header for record $d/none", e.message)
            assertFalse(assertFailsWith<WfdbException> { w.setMetadata("$d/none", "Age", "1") } is WfdbArgumentException)
            assertFailsWith<WfdbArgumentException> { w.readMetadata("") }
            assertFailsWith<WfdbArgumentException> { w.readMetadata("-") }
            val rec = copyMetaHeader("basic", d)
            val before = readFile("$rec.hea")!!
            assertEquals(
                "metadata value 'Ā' has a character that is not Latin-1 (one byte per character)",
                assertFailsWith<WfdbArgumentException> { w.setMetadata(rec, "Name", "Ā") }.message,
            )
            assertEquals(
                "metadata key 'a\\nb' must not contain a line break",
                assertFailsWith<WfdbArgumentException> { w.getMetadata(rec, "a\nb") }.message,
            )
            assertEquals("metadata key must not be empty", assertFailsWith<WfdbArgumentException> { w.removeMetadata(rec, " \t") }.message)
            assertEquals(
                "metadata key 'AGE' is given more than once (keys are compared without regard to letter case)",
                assertFailsWith<WfdbArgumentException> { w.updateMetadata(rec, listOf("Age" to "1", "AGE" to null)) }.message,
            )
            assertContentEquals(before, readFile("$rec.hea"))
            // bytes beyond ASCII, one character per byte
            w.setMetadata(rec, "Name", "ZÃ¼rich")
            assertEquals("ZÃ¼rich", w.getMetadata(rec, "Name"))
            assertTrue(readFile("$rec.hea")!!.latin1().contains("# Name: ZÃ¼rich\r\n"))
            writeFile("$d/norec.hea", "# only a comment\n")
            assertEquals(emptyList(), w.readMetadata("$d/norec"))
            assertEquals(
                "header of record $d/norec has no record line",
                assertFailsWith<WfdbArgumentException> { w.setMetadata("$d/norec", "Age", "1") }.message,
            )
            assertNull(w.getMetadata(rec, "Weight"))
            assertEquals(listOf("basic.hea", "norec.hea"), listFiles(d))
        } finally {
            removeTree(d)
        }
    }

    @Test
    fun duplicateMessages() {
        val d = makeTempDir("metadup")
        try {
            val w = Wfdb()
            val rec = copyMetaHeader("dups", d)
            val e = assertFailsWith<WfdbArgumentException> { w.setMetadata(rec, "AGE", "1") }
            assertTrue(e.message!!.startsWith("header of record $rec has more than one entry for key AGE (lines "), e.message)
            assertTrue(e.message!!.endsWith("); remove them first"), e.message)
        } finally {
            removeTree(d)
        }
    }
}
