// JVM-only tests of the signal functions: an output signal file that is a
// hard link to an input file (the file identity check of osigfopen).
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

import wfdbx.cstd.latin1
import java.nio.file.Files
import java.nio.file.Paths
import kotlin.test.Test
import kotlin.test.assertEquals

class SignalJvmTest {
    @Test
    fun hardLinkIsInputFile() {
        val d = DataDir("hardlink")
        val w = d.wfdb()
        w.wfdbquiet()
        Files.createLink(Paths.get(d.path("ahard16.dat")), Paths.get(d.path("fmt16.dat")))
        val si = Array(3) { Siginfo() }
        assertEquals(3, w.isigopen("fmt16", si, 3))
        val spec = arrayOf(Siginfo(fname = "ahard16.dat".latin1(), desc = "x".latin1(), fmt = 16, gain = 200.0, adcres = 16))
        assertEquals(-3, w.osigfopen(spec, 1))
        assertEquals("osigfopen: output file ahard16.dat is also an input file\n", w.wfdberror().latin1())
        val v = IntArray(3)
        assertEquals(3, w.getvec(v)) // the input is intact
        assertEquals(9000, d.read("fmt16.dat")!!.size)
        w.wfdbquit()
        d.remove()
    }
}
