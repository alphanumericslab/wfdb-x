// Native (POSIX) parts of the test helpers.
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

@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package wfdbx

import kotlinx.cinterop.pointed
import kotlinx.cinterop.toKString
import platform.posix.closedir
import platform.posix.getenv
import platform.posix.mkdtemp
import platform.posix.opendir
import platform.posix.readdir
import platform.posix.system

actual fun testDataDir(): String = getenv("WFDBX_TESTDATA")?.toKString() ?: "../tests/data"

actual fun makeTempDir(name: String): String {
    val t = "/tmp/wfdbx-kt-$name-XXXXXX".encodeToByteArray() + byteArrayOf(0)
    val p = kotlinx.cinterop.memScoped {
        val buf = kotlinx.cinterop.allocArrayOf(t)
        mkdtemp(buf)?.toKString()
    }
    return p ?: error("mkdtemp failed")
}

actual fun removeTree(path: String) {
    system("rm -rf '$path'")
}

actual fun listFiles(dir: String): List<String> {
    val d = opendir(dir) ?: return emptyList()
    val r = ArrayList<String>()
    while (true) {
        val e = readdir(d) ?: break
        val n = e.pointed.d_name.toKString()
        if (n != "." && n != ".." && e.pointed.d_type.toInt() == 8) r.add(n)
    }
    closedir(d)
    return r.sorted()
}
