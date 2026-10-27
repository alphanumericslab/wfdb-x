// JVM parts of the test helpers.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It tests WFDB-x; it has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

import java.io.File
import java.nio.file.Files

actual fun testDataDir(): String =
    System.getProperty("wfdbx.testdata") ?: File("../tests/data").absolutePath

actual fun makeTempDir(name: String): String =
    Files.createTempDirectory("wfdbx-kt-$name-").toFile().canonicalPath

actual fun removeTree(path: String) {
    File(path).deleteRecursively()
}

actual fun listFiles(dir: String): List<String> =
    File(dir).listFiles()?.filter { it.isFile }?.map { it.name }?.sorted() ?: emptyList()
