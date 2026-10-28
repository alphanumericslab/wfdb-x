// Benchmark driver for the Kotlin implementation of WFDB-x.
//
//   java -jar kotlin/build/libs/wfdbx-bench.jar OP DATADIR REPS
//
// Built by `./gradlew benchJar` in kotlin/. See benchmarks/README.md for the
// operations and the output (one JSON line on the standard output).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
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

import java.io.File
import java.nio.file.Files
import kotlin.system.exitProcess
import wfdbx.WfdbException
import wfdbx.readAnnotations
import wfdbx.readRecord
import wfdbx.wfdbxSetInputDir
import wfdbx.writeAnnotations
import wfdbx.writeRecord

private val OPS = listOf("read_long", "read_long_phys", "read_mimic", "read_wide", "write_long", "read_ann", "write_ann")

/** The 64-bit sum of the samples of a record read with default options. */
private fun digitalSum(record: String): String {
    var sum = 0L
    for (v in readRecord(record).samples) sum += v
    return sum.toString()
}

private fun run(op: String, out: File, reps: Int): String {
    // Untimed preparation.
    val src = if (op == "write_long") readRecord("long") else null
    val ann = if (op == "write_ann") readAnnotations("long", "atr") else null

    val call: () -> String = when (op) {
        "read_long" -> { -> digitalSum("long") }
        "read_long_phys" -> { ->
            var sum = 0.0
            for (v in readRecord("long", physical = true).physical!!) if (!v.isNaN()) sum += v
            (Math.round(sum * 1000.0) / 1000.0).toString()
        }
        "read_mimic" -> { -> digitalSum("mimic") }
        "read_wide" -> { -> digitalSum("wide") }
        "write_long" -> { ->
            val r = src!!
            writeRecord(
                "out", r.samples, r.nsig, r.fs, fmt = 16, gains = r.gains.toDoubleArray(),
                adcres = intArrayOf(16), units = r.units, dir = out.path,
            )
            File(out, "out.dat").length().toString()
        }
        "read_ann" -> { -> readAnnotations("long", "atr").size.toString() }
        "write_ann" -> { ->
            val a = ann!!
            writeAnnotations("out", "atr", a.samples, codes = a.codes, aux = a.aux, dir = out.path)
            File(out, "out.atr").length().toString()
        }
        else -> error("unknown operation $op")
    }

    var t = System.nanoTime()
    val check = call()
    val first = (System.nanoTime() - t) / 1e9
    val times = DoubleArray(reps)
    for (i in 0 until reps) {
        t = System.nanoTime()
        call()
        times[i] = (System.nanoTime() - t) / 1e9
    }
    return "{\"op\": \"$op\", \"first\": $first, \"best\": ${times.min()}, " +
        "\"times\": [${times.joinToString(", ")}], \"check\": $check}"
}

fun main(args: Array<String>) {
    if (args.size != 3) {
        System.err.println("usage: java -jar wfdbx-bench.jar OP DATADIR REPS")
        exitProcess(2)
    }
    val (op, dir) = args[0] to args[1]
    if (op !in OPS) {
        System.err.println("wfdbx-bench: unknown operation $op")
        exitProcess(2)
    }
    val reps = args[2].toIntOrNull()
    if (reps == null || reps < 1) {
        System.err.println("wfdbx-bench: REPS must be an integer >= 1")
        exitProcess(2)
    }
    wfdbxSetInputDir(dir)
    val out = Files.createTempDirectory("wfdbx-bench-").toFile()
    val line = try {
        run(op, out, reps)
    } catch (e: WfdbException) {
        System.err.println("wfdbx-bench: $op: ${e.message}")
        null
    } finally {
        out.deleteRecursively()
    }
    if (line == null) exitProcess(1)
    println(line)
}
