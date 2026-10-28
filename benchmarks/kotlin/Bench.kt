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
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import kotlin.system.exitProcess
import wfdbx.Annotations
import wfdbx.Record
import wfdbx.WfdbException
import wfdbx.readAnnotations
import wfdbx.readRecord
import wfdbx.wfdbxSetInputDir
import wfdbx.writeAnnotations
import wfdbx.writeRecord

private val OPS = listOf("read_long", "read_long_phys", "read_mimic", "read_wide", "write_long", "read_ann", "write_ann")

/** The 64-bit sum of the samples of [rec]. */
private fun digitalSum(rec: Record): String {
    var sum = 0L
    for (v in rec.samples) sum += v
    return sum.toString()
}

/**
 * Save [kept], the result of the first call of [op], as dump/op.* (see
 * benchmarks/python/bench.py), little-endian. Record.samples and
 * Record.physical are already frame by frame.
 */
private fun save(op: String, kept: Any?, out: File, dump: File) {
    val p = { ext: String -> File(dump, "$op.$ext") }
    when (op) {
        "read_long", "read_mimic", "read_wide" -> {
            val x = (kept as Record).samples
            val b = ByteBuffer.allocate(4 * x.size).order(ByteOrder.LITTLE_ENDIAN)
            b.asIntBuffer().put(x)
            p("bin").writeBytes(b.array())
        }
        "read_long_phys" -> {
            val x = (kept as Record).physical!!
            val b = ByteBuffer.allocate(8 * x.size).order(ByteOrder.LITTLE_ENDIAN)
            b.asDoubleBuffer().put(x)
            p("bin").writeBytes(b.array())
        }
        "read_ann" -> {
            val a = kept as Annotations
            val aux = a.aux.map { it?.toByteArray(Charsets.ISO_8859_1) }
            val b = ByteBuffer.allocate(28 * a.size + aux.sumOf { it?.size ?: 0 })
                .order(ByteOrder.LITTLE_ENDIAN)
            for (k in 0 until a.size) {
                b.putLong(a.samples[k]).putInt(a.codes[k]).putInt(a.subtypes[k])
                    .putInt(a.chans[k]).putInt(a.nums[k])
                val x = aux[k]
                if (x == null) b.putInt(-1) else b.putInt(x.size).put(x)
            }
            p("ann").writeBytes(b.array())
        }
        "write_long" -> {
            File(out, "out.hea").copyTo(p("hea"), overwrite = true)
            File(out, "out.dat").copyTo(p("dat"), overwrite = true)
        }
        "write_ann" -> File(out, "out.atr").copyTo(p("atr"), overwrite = true)
    }
}

private fun run(op: String, out: File, reps: Int): String {
    // Untimed preparation.
    val src = if (op == "write_long") readRecord("long") else null
    val ann = if (op == "write_ann") readAnnotations("long", "atr") else null

    // call() is the timed call: the operation alone, returning what it
    // read. check() is computed from the first call's result, outside the
    // timed calls.
    val call: () -> Any? = when (op) {
        "read_long" -> { -> readRecord("long") }
        "read_long_phys" -> { -> readRecord("long", physical = true) }
        "read_mimic" -> { -> readRecord("mimic") }
        "read_wide" -> { -> readRecord("wide") }
        "write_long" -> { ->
            val r = src!!
            writeRecord(
                "out", r.samples, r.nsig, r.fs, fmt = 16, gains = r.gains.toDoubleArray(),
                adcres = intArrayOf(16), units = r.units, dir = out.path,
            )
            null
        }
        "read_ann" -> { -> readAnnotations("long", "atr") }
        "write_ann" -> { ->
            val a = ann!!
            writeAnnotations("out", "atr", a.samples, codes = a.codes, aux = a.aux, dir = out.path)
            null
        }
        else -> error("unknown operation $op")
    }
    val check: (Any?) -> String = { res ->
        when (op) {
            "read_long_phys" -> {
                var sum = 0.0
                for (v in (res as Record).physical!!) if (!v.isNaN()) sum += v
                (Math.round(sum * 1000.0) / 1000.0).toString()
            }
            "write_long" -> File(out, "out.dat").length().toString()
            "read_ann" -> (res as Annotations).size.toString()
            "write_ann" -> File(out, "out.atr").length().toString()
            else -> digitalSum(res as Record)
        }
    }

    val dump = System.getenv("WFDBX_BENCH_DUMP")?.takeIf { it.isNotEmpty() }
    var t = System.nanoTime()
    var res = call()
    val first = (System.nanoTime() - t) / 1e9
    val value = check(res)
    if (dump != null) save(op, res, out, File(dump))
    res = null
    val times = DoubleArray(reps)
    for (i in 0 until reps) {
        t = System.nanoTime()
        res = call()
        times[i] = (System.nanoTime() - t) / 1e9
        res = null
    }
    return "{\"op\": \"$op\", \"first\": $first, \"best\": ${times.min()}, " +
        "\"times\": [${times.joinToString(", ")}], \"check\": $value}"
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
    // (in $TMPDIR if set, as the other drivers)
    val tmp = System.getenv("TMPDIR")?.takeIf { it.isNotEmpty() }
    val out = (if (tmp != null) Files.createTempDirectory(File(tmp).toPath(), "wfdbx-bench-")
               else Files.createTempDirectory("wfdbx-bench-")).toFile()
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
