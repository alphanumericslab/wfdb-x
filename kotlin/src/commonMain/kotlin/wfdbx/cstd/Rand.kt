// Exact emulation of glibc's srand/rand (random, TYPE_3 additive feedback
// generator with 31 words of state), used for dithering by wrsamp -d and
// xform -d (port of rust/src/cstd/rand.rs).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.cstd

/** glibc's RAND_MAX. */
const val RAND_MAX: Int = Int.MAX_VALUE

private const val DEG_3 = 31
private const val SEP_3 = 3

/** The state of glibc's rand() generator; `GlibcRand()` is the generator at program start (srand(1)). */
class GlibcRand(seed: Int = 1) {
    private val state = IntArray(DEG_3)
    private var f = SEP_3
    private var r = 0

    init {
        srand(seed)
    }

    /** C `srand(seed)` (the seed is an unsigned int; 0 is the same as 1). */
    fun srand(seed0: Int) {
        val seed = if (seed0 == 0) 1 else seed0
        state[0] = seed
        var word = seed.toLong() // (int) seed
        // "Minimal standard" generator 16807 * word % 2147483647 (Schrage's
        // method), then 10 * DEG_3 values are discarded.
        for (i in 1 until DEG_3) {
            val hi = word / 127773
            val lo = word % 127773
            word = 16807 * lo - 2836 * hi
            if (word < 0) word += 2147483647
            state[i] = word.toInt()
        }
        f = SEP_3
        r = 0
        repeat(10 * DEG_3) { rand() }
    }

    /** C `rand()`: the next value, in 0..RAND_MAX. */
    fun rand(): Int {
        val v = state[f] + state[r]
        state[f] = v
        f = if (f == DEG_3 - 1) 0 else f + 1
        r = if (r == DEG_3 - 1) 0 else r + 1
        return v ushr 1
    }
}

/** The process generator (per thread, as the Rust port). */
internal expect fun processRand(): GlibcRand

/** C `srand(seed)` on the process generator. */
fun srand(seed: Int) = processRand().srand(seed)

/** C `rand()` on the process generator. */
fun rand(): Int = processRand().rand()
