// Tests of checkRecord against the check_record corpus (ports of
// rust/tests/check.rs and python/tests/test_check.py). The corpus (one
// broken record for each issue code, a clean record, records of
// tests/data, annotation files) is made by python/tests/check_corpus.py in
// a temporary directory; the report of each case must be the lines of its
// expected.txt (Python's reports). The tests are skipped, with a message,
// when python3 (with NumPy) is not available.
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

import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CheckCorpusTest {
    private val repo: File = File(testDataDir()).parentFile.parentFile
    private val made = ArrayList<String>()

    @AfterTest
    fun cleanup() {
        for (d in made) removeTree(d)
    }

    /** A corpus made by check_corpus.py in a new temporary directory, or null (with a message) without python3. */
    private fun corpus(name: String): String? {
        val dir = makeTempDir("check-$name")
        made.add(dir)
        val python = System.getenv("PYTHON") ?: "python3"
        val pb = ProcessBuilder(
            python, File(repo, "python/tests/check_corpus.py").path, dir, File(repo, "tests/data").path,
        )
        pb.environment()["PYTHONPATH"] = File(repo, "python/src").path
        pb.redirectOutput(ProcessBuilder.Redirect.DISCARD)
        pb.redirectErrorStream(false)
        val status = try {
            pb.start().waitFor()
        } catch (e: java.io.IOException) {
            println("CheckCorpusTest: skipped: $python cannot be run (${e.message})")
            return null
        }
        if (status != 0) {
            println("CheckCorpusTest: skipped: $python check_corpus.py failed (status $status; NumPy is needed)")
            return null
        }
        return dir
    }

    @Test
    fun corpus() {
        val dir = corpus("corpus") ?: return
        val cases = File(dir, "cases.txt").readText(Charsets.ISO_8859_1)
        val expected = File(dir, "expected.txt").readText(Charsets.ISO_8859_1)
        val w = Wfdb()
        val out = StringBuilder()
        val seen = sortedSetOf<String>()
        for (line in cases.lines()) {
            if (line.isEmpty()) continue
            val words = line.split(' ').filter { it.isNotEmpty() }
            val r = w.checkRecord(words[0], words.drop(1), inputDir = dir)
            assertEquals(words[0], r.record)
            assertEquals(r.issues.none { it.severity == Severity.ERROR }, r.ok)
            assertEquals(r.lines().joinToString("\n"), r.toString())
            r.issues.mapTo(seen) { it.code }
            out.append("== $line\n")
            for (l in r.lines()) out.append(l).append('\n')
        }
        // an empty diff: the same lines as Python's reports
        assertEquals(expected, out.toString())
        // every issue code is produced (file_large: see fileLarge)
        assertEquals(44, seen.size)
        assertFalse("file_large" in seen)
    }

    @Test
    fun issueFields() {
        val dir = corpus("fields") ?: return
        val w = Wfdb()
        var r = w.checkRecord("d_cksum", inputDir = dir)
        assertTrue(!r.ok && r.issues.size == 1)
        val i = r.issues[0]
        assertEquals(Triple(Severity.ERROR, "checksum", "signal 1"), Triple(i.severity, i.code, i.where))
        assertEquals("the checksum does not match: the header gives 1, the samples sum to 0", i.message)
        assertEquals("error: signal 1: ${i.message}", i.toString())
        r = w.checkRecord("clean", listOf("atr"), inputDir = dir)
        assertTrue(r.ok && r.issues.isEmpty())
        assertEquals("no problems found", r.toString())
        // warnings and infos only: ok
        r = w.checkRecord("nolen", inputDir = dir)
        assertTrue(r.ok)
        assertEquals(listOf(Severity.WARNING, Severity.INFO), r.issues.map { it.severity })
        assertEquals("warning: the record length is not specified", r.issues[0].toString())
    }

    @Test
    fun settingsRestored() {
        // legacy mode off during the call and restored; the library prints
        // nothing (its print setting is restored); the input directory is
        // restored
        val dir = corpus("settings") ?: return
        val w = Wfdb()
        val prevDir = w.wfdbxGetInputDir()
        w.wfdbxSetLegacy(true)
        val r = w.checkRecord("nofs", listOf("nofile"), inputDir = dir)
        assertTrue(w.wfdbxGetLegacy())
        w.wfdbxSetLegacy(false)
        // (legacy mode would assume 250 Hz: the frequency is reported missing)
        assertEquals("fs_missing", r.issues[0].code)
        assertEquals(prevDir, w.wfdbxGetInputDir())
        // quiet before: quiet after (the library's messages are recorded)
        w.wfdbquiet()
        w.checkRecord("nofs", listOf("nofile"), inputDir = dir)
        w.isigopen("no_such_record", null, 0)
        assertTrue("no_such_record" in String(w.wfdberror(), Charsets.ISO_8859_1))
        w.wfdbquit()
    }

    @Test
    fun modificationLabels() {
        // codes 42 and 43 defined by the file's modification labels have a
        // mnemonic (no warning); the definitions do not outlive the check
        val dir = corpus("labels") ?: return
        val w = Wfdb()
        w.wfdbquiet()
        w.setannstr(42, "QQ")
        w.setanndesc(42, "my beat")
        w.writeAnnotations("clean", "lab", longArrayOf(10, 20, 30), codes = intArrayOf(42, 1, 43), dir = dir)
        w.setannstr(-42, "[42]")
        w.setanndesc(-42, null as ByteArray?)
        val r = w.checkRecord("clean", listOf("lab"), inputDir = dir)
        assertEquals(
            listOf("warning: annotator lab: 1 annotation uses a code without a mnemonic: at sample 30 (code 43)"),
            r.lines(),
        )
        assertContentEquals("[42]".toByteArray(), w.annstr(42))
    }
}
