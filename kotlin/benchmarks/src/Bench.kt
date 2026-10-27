// The benchmark program of the Kotlin implementation (run by
// benchmarks/run.sh, which runs the same operations with C++, Rust and
// Python and compares the outputs).
//
//   java -jar build/libs/wfdbx-bench.jar read   DIR REC REPS
//   java -jar build/libs/wfdbx-bench.jar write  DIR REC OUTDIR REPS
//   java -jar build/libs/wfdbx-bench.jar ann    OUTDIR REPS
//   java -jar build/libs/wfdbx-bench.jar getvec DIR REC REPS
//
// Each prints the best time of REPS runs (after one untimed warm-up run, so
// that the JIT compiler has compiled the code) and a digest of the data
// (FNV-1a of the samples) for the comparison with the other languages.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.bench

import wfdbx.Siginfo
import wfdbx.Wfdb
import wfdbx.getvec
import wfdbx.isigopen
import wfdbx.readRecord
import wfdbx.wfdbquit
import wfdbx.wfdbx_set_input_dir
import wfdbx.writeAnnotations
import wfdbx.writeRecord

private fun fnv(h0: Long, v: Int): Long = (h0 xor (v.toLong() and 0xffffffffL)) * 1099511628211L

private const val FNV0 = -3750763034362895579L // 14695981039346656037

private fun time(reps: Int, f: () -> Unit): Double {
    f() // (warm-up)
    var best = Double.MAX_VALUE
    repeat(reps) {
        val t = System.nanoTime()
        f()
        best = minOf(best, (System.nanoTime() - t) / 1e6)
    }
    return best
}

/** The 200000 annotations of the benchmark (the same in every language). */
private class Anns(n: Int) {
    val samples = LongArray(n) { 10L * it + (7L * it) % 9 }
    val codes = IntArray(n) { intArrayOf(1, 1, 1, 5, 8, 1, 12, 1)[it % 8] }
    val subtypes = IntArray(n) { if (it % 50 == 0) 1 else 0 }
    val aux = List(n) { if (it % 1000 == 0) "(N" else null }
}

fun main(args: Array<String>) {
    val w = Wfdb()
    when (args[0]) {
        "read" -> {
            val (dir, rec) = args[1] to args[2]
            var last: wfdbx.Record? = null
            val ms = time(args[3].toInt()) { last = w.readRecord(rec, inputDir = dir) }
            val r = last!!
            var h = FNV0
            for (v in r.samples) h = fnv(h, v)
            println("read_record ${"%.1f".format(ms)} ms frames=${r.nsamples} nsig=${r.nsig} digest=${java.lang.Long.toUnsignedString(h, 16)}")
        }
        "write" -> {
            val (dir, rec, out) = Triple(args[1], args[2], args[3])
            val r = w.readRecord(rec, inputDir = dir)
            val ms = time(args[4].toInt()) {
                w.writeRecord(
                    rec, r.samples, r.nsig, r.fs, fmt = 16, gains = r.gains.toDoubleArray(),
                    baselines = r.baselines.toIntArray(), adcres = intArrayOf(16), units = listOf("mV"),
                    names = r.names, dir = out,
                )
            }
            println("write_record ${"%.1f".format(ms)} ms")
        }
        "ann" -> {
            val out = args[1]
            val a = Anns(200000)
            val ms = time(args[2].toInt()) {
                w.writeAnnotations("big", "bench", a.samples, codes = a.codes, subtypes = a.subtypes, aux = a.aux, dir = out)
            }
            println("write_annotations ${"%.1f".format(ms)} ms")
        }
        "getvec" -> {
            val (dir, rec) = args[1] to args[2]
            w.wfdbx_set_input_dir(dir)
            var h = FNV0
            var frames = 0L
            val ms = time(args[3].toInt()) {
                w.wfdbquit()
                val n = w.isigopen(rec, null, 0)
                val si = Array(n) { Siginfo() }
                w.isigopen(rec, si, n)
                val v = IntArray(n)
                h = FNV0
                frames = 0
                while (w.getvec(v) >= 0) {
                    for (x in v) h = fnv(h, x)
                    frames++
                }
                w.wfdbquit()
            }
            println("getvec ${"%.1f".format(ms)} ms frames=$frames digest=${java.lang.Long.toUnsignedString(h, 16)}")
        }
        else -> error("unknown command ${args[0]}")
    }
}
