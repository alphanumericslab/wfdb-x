// Linux parts of the native platform layer: struct stat, the curl program
// for network access (run without a shell, as the C++ and Rust ports do),
// and the sortann program for legacy mode (posix_spawnp).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package wfdbx.cstd

import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.CPointer
import kotlinx.cinterop.IntVar
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.convert
import kotlinx.cinterop.cstr
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.set
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import platform.posix.S_IFDIR
import platform.posix.S_IFMT
import platform.posix.close
import platform.posix.fstat
import platform.posix.getuid
import platform.posix.mkdir
import platform.posix.pipe
import platform.posix.posix_spawn_file_actions_addclose
import platform.posix.posix_spawn_file_actions_adddup2
import platform.posix.posix_spawn_file_actions_addopen
import platform.posix.posix_spawn_file_actions_destroy
import platform.posix.posix_spawn_file_actions_init
import platform.posix.posix_spawn_file_actions_t
import platform.posix.posix_spawnp
import platform.posix.read
import platform.posix.stat
import platform.posix.waitpid
import platform.posix.O_RDONLY
import platform.posix.O_WRONLY
import platform.posix.EINTR
import platform.posix.errno

internal actual fun nativeFileId(fd: Int): FileId? = memScoped {
    val st = alloc<stat>()
    if (fstat(fd, st.ptr) != 0) null else FileId(st.st_dev.toLong(), st.st_ino.toLong())
}

internal actual fun nativeBlksize(fd: Int): Int = memScoped {
    val st = alloc<stat>()
    if (fstat(fd, st.ptr) != 0 || st.st_blksize <= 0) 4096 else st.st_blksize.toInt()
}

internal actual fun nativePathId(path: String): FileId? = memScoped {
    val st = alloc<stat>()
    if (stat(path, st.ptr) != 0) null else FileId(st.st_dev.toLong(), st.st_ino.toLong())
}

internal actual fun nativeIsDirectory(path: String): Boolean = memScoped {
    val st = alloc<stat>()
    stat(path, st.ptr) == 0 && (st.st_mode.toInt() and S_IFMT) == S_IFDIR
}

internal actual fun nativeMkdir(path: String): Boolean = mkdir(path, 493.convert()) == 0 // 0755

internal actual fun nativeUid(): Long = getuid().toLong()

/** Runs argv[0] (found in the PATH) without a shell; returns (exit status, standard output) (status -1 if it could not be run). */
private fun spawn(argv: List<String>, dir: String?, captureStdout: Boolean, quiet: Boolean): Pair<Int, ByteArray> = memScoped {
    val fa = alloc<posix_spawn_file_actions_t>()
    posix_spawn_file_actions_init(fa.ptr)
    val fds = allocArray<IntVar>(2)
    if (captureStdout) {
        if (pipe(fds) != 0) return@memScoped Pair(-1, ByteArray(0))
        posix_spawn_file_actions_adddup2(fa.ptr, fds[1], 1)
        posix_spawn_file_actions_addclose(fa.ptr, fds[0])
        posix_spawn_file_actions_addclose(fa.ptr, fds[1])
        posix_spawn_file_actions_addopen(fa.ptr, 0, "/dev/null", O_RDONLY, 0.convert())
    }
    if (quiet) posix_spawn_file_actions_addopen(fa.ptr, 2, "/dev/null", O_WRONLY, 0.convert())
    val args = allocArray<CPointer<ByteVar>?>(argv.size + 2)
    var k = 0
    if (dir != null) {
        // (posix_spawn has no working directory: use env -C DIR)
        args[k++] = "env".cstr.ptr
        args[k++] = "-C".cstr.ptr
        args[k++] = dir.cstr.ptr
    }
    val all = allocArray<CPointer<ByteVar>?>(argv.size + 4)
    for (i in 0 until k) all[i] = args[i]
    for (a in argv) all[k++] = a.cstr.ptr
    all[k] = null
    val pid = alloc<IntVar>()
    val rc = posix_spawnp(pid.ptr, if (dir != null) "env" else argv[0], fa.ptr, null, all, platform.posix.environ)
    posix_spawn_file_actions_destroy(fa.ptr)
    if (rc != 0) {
        if (captureStdout) {
            close(fds[0])
            close(fds[1])
        }
        return@memScoped Pair(-1, ByteArray(0))
    }
    val out = ByteVec(65536)
    if (captureStdout) {
        close(fds[1])
        val buf = ByteArray(65536)
        while (true) {
            val n = buf.usePinned { p -> read(fds[0], p.addressOf(0), buf.size.convert()) }
            if (n < 0 && errno == EINTR) continue
            if (n <= 0) break
            out.addAll(buf, 0, n.toInt())
        }
        close(fds[0])
    }
    val status = alloc<IntVar>()
    while (waitpid(pid.value, status.ptr, 0) < 0 && errno == EINTR) {}
    val s = status.value
    val code = if ((s and 0x7f) == 0) (s shr 8) and 0xff else -1
    Pair(code, out.toByteArray())
}

internal actual fun nativeFetchUrl(url: String): FetchResult {
    val (code, data) = spawn(
        listOf("curl", "--silent", "--fail", "--location", "--connect-timeout", "30", "--speed-limit", "1", "--speed-time", "30", url),
        null, captureStdout = true, quiet = true,
    )
    return when (code) {
        0 -> FetchResult(data, false)
        -1, 127 -> FetchResult(null, true)
        else -> FetchResult(null, false)
    }
}

internal actual fun nativeRunSortann(record: String, annotator: String, dir: String?): Int =
    spawn(listOf("sortann", "--legacy", "-r.", record, "-a", annotator), dir, captureStdout = false, quiet = false).first
