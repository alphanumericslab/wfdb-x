// Helpers of the unit tests: scratch directories and copies of tests/data.
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

import wfdbx.cstd.Platform
import wfdbx.cstd.latin1

/** The absolute path of the repository's tests/data directory. */
expect fun testDataDir(): String

/** A new, empty directory (absolute path, without a final "/"). */
expect fun makeTempDir(name: String): String

/** Removes a directory tree. */
expect fun removeTree(path: String)

/** The names of the regular files in a directory. */
expect fun listFiles(dir: String): List<String>

/** Writes a file (creating missing directories). */
fun writeFile(path: String, data: ByteArray) {
    val f = localFopen(path.latin1(), "wb", false) ?: error("cannot create $path")
    f.write(data)
    check(f.close() == 0)
}

/** Writes a file (a string, one byte per character). */
fun writeFile(path: String, text: String) = writeFile(path, text.latin1())

/** The contents of a file, or null. */
fun readFile(path: String): ByteArray? = Platform.readFile(path.latin1())

/** Whether a file exists. */
fun fileExists(path: String): Boolean = Platform.readFile(path.latin1()) != null

/** A fresh copy of tests/data (its files) in a scratch directory. */
class DataDir(name: String) {
    /** The directory (absolute path, without a final "/"). */
    val dir: String = makeTempDir(name)

    init {
        val data = testDataDir()
        for (f in listFiles(data)) writeFile("$dir/$f", readFile("$data/$f")!!)
    }

    /** The path of [name] in the directory. */
    fun path(name: String) = "$dir/$name"

    /** The contents of [name]. */
    fun read(name: String): ByteArray? = readFile(path(name))

    /** A new library state reading from and writing to the directory. */
    fun wfdb(): Wfdb {
        val w = Wfdb()
        w.wfdbx_set_input_dir(dir)
        w.wfdbx_set_output_dir(dir)
        return w
    }

    /** Removes the directory. */
    fun remove() = removeTree(dir)
}

/** Hexadecimal digits (with optional spaces) to bytes. */
fun unhex(h: String): ByteArray {
    val d = h.filter { it != ' ' }
    return ByteArray(d.length / 2) { d.substring(2 * it, 2 * it + 2).toInt(16).toByte() }
}

/** Bytes to hexadecimal digits. */
fun hex(b: ByteArray): String = b.joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }

/** An aux field (length byte first). */
fun aux(s: String): ByteArray = byteArrayOf(s.length.toByte()) + s.latin1()
