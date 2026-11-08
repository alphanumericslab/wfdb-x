// Tests of the files that the tools read and create themselves: under the
// input and output directories (port of test_tool_files of
// python/tests/test_files.py; see the toolfiles-* cases of the conformance
// suite). Each tool runs in a fresh JVM (java -cp <class path>
// wfdbx.cli.MainKt TOOL ...), in a scratch directory.
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

import java.io.File
import java.nio.file.Paths
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ToolFilesJvmTest {
    /** Runs a tool in a fresh process in [dir], with the environment variables [env]; returns its exit status. */
    private fun tool(dir: String, name: String, vararg args: String, env: Map<String, String> = emptyMap()): Int {
        val java = Paths.get(System.getProperty("java.home"), "bin", "java").toString()
        val pb = ProcessBuilder(listOf(java, "-cp", System.getProperty("java.class.path"), "wfdbx.cli.MainKt", name) + args)
        pb.directory(File(dir))
        val e = pb.environment()
        for (k in listOf("WFDB", "WFDBX_INPUT_DIR", "WFDBX_OUTPUT_DIR", "WFDBX_NETWORK", "JAVA_TOOL_OPTIONS")) e.remove(k)
        e.putAll(env)
        pb.redirectOutput(ProcessBuilder.Redirect.DISCARD)
        pb.redirectError(ProcessBuilder.Redirect.DISCARD)
        return pb.start().waitFor()
    }

    @Test
    fun toolFiles() {
        val d = DataDir("toolfiles")
        try {
            writeFile(d.path("sub/in.txt"), (0 until 50).joinToString("") { "$it ${-it}\n" })
            val wr = tool(
                d.dir, "wrsamp", "-i", "in.txt", "-o", "w1", "-F", "250", "-G", "200", "-R", "16", "-U", "mV",
                env = mapOf("WFDBX_INPUT_DIR" to "sub", "WFDBX_OUTPUT_DIR" to "out"),
            )
            assertEquals(0, wr)
            assertTrue(fileExists(d.path("out/w1.hea")) && fileExists(d.path("out/w1.dat")))
            val before = File(d.dir).list()!!.toSet()
            assertEquals(0, tool(d.dir, "mit2wav", "-r", "100s", "-o", "x.wav", env = mapOf("WFDBX_OUTPUT_DIR" to "out")))
            assertEquals(0, tool(d.dir, "mit2edf", "-r", "fmt16", "-o", "x.edf", env = mapOf("WFDBX_OUTPUT_DIR" to "out")))
            assertEquals(before, File(d.dir).list()!!.toSet()) // nothing in the current directory
            val wav = d.read("out/x.wav")!!
            assertEquals("RIFF", String(wav, 0, 4, Charsets.ISO_8859_1))
            assertEquals(44 + 2 * 2 * 21600, wav.size)
            assertTrue(d.read("out/x.edf")!!.isNotEmpty())
        } finally {
            d.remove()
        }
    }
}
