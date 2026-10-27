// The platform layer on Kotlin/Native (Linux and iOS; see Platform.kt):
// POSIX file descriptors and environment. The parts whose types differ
// between Linux and Darwin (struct stat), network access and processes are
// in linuxMain and iosMain.
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

@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package wfdbx.cstd

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.toKString
import kotlinx.cinterop.usePinned
import platform.posix.EINTR
import platform.posix.EPIPE
import platform.posix.O_APPEND
import platform.posix.O_CREAT
import platform.posix.O_RDONLY
import platform.posix.O_RDWR
import platform.posix.O_TRUNC
import platform.posix.O_WRONLY
import platform.posix.SEEK_CUR as P_SEEK_CUR
import platform.posix.close
import platform.posix.dup
import platform.posix.errno
import platform.posix.isatty
import platform.posix.lseek
import platform.posix.open
import platform.posix.read
import platform.posix.setenv as psetenv
import platform.posix.unsetenv as punsetenv
import platform.posix.write

/** struct stat-based helpers (linuxMain, iosMain). */
internal expect fun nativeFileId(fd: Int): FileId?
internal expect fun nativeBlksize(fd: Int): Int
internal expect fun nativePathId(path: String): FileId?
internal expect fun nativeIsDirectory(path: String): Boolean
internal expect fun nativeFetchUrl(url: String): FetchResult
internal expect fun nativeRunSortann(record: String, annotator: String, dir: String?): Int
internal expect fun nativeMkdir(path: String): Boolean
internal expect fun nativeUid(): Long

/** A C string (the bytes are passed as they are; Kotlin strings are converted to UTF-8 by cinterop, so bytes are decoded as UTF-8 here). */
internal fun cname(b: ByteArray): String = b.decodeToString()

internal actual class RawFile internal constructor(private val fd: Int, private val ownsFd: Boolean) {
    actual fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        while (true) {
            val n = b.usePinned { p -> read(fd, p.addressOf(off), len.convert()) }
            if (n < 0 && errno == EINTR) continue
            return if (n < 0) -1 else n.toInt()
        }
    }

    actual fun write(b: ByteArray, off: Int, len: Int): Boolean {
        var done = 0
        while (done < len) {
            val n = b.usePinned { p -> write(fd, p.addressOf(off + done), (len - done).convert()) }
            if (n < 0) {
                if (errno == EINTR) continue
                return false
            }
            done += n.toInt()
        }
        return true
    }

    actual fun seek(offset: Long, whence: Int): Long = lseek(fd, offset.convert(), whence).toLong()

    actual fun position(): Long = lseek(fd, 0.convert(), P_SEEK_CUR).toLong()

    actual fun size(): Long {
        val cur = position()
        if (cur < 0) return -1
        val end = seek(0, SEEK_END)
        seek(cur, SEEK_SET)
        return end
    }

    actual fun blksize(): Int = nativeBlksize(fd)

    actual fun fileId(): FileId? = nativeFileId(fd)

    actual fun close(): Boolean = if (ownsFd) close(fd) == 0 else true
}

internal actual object Platform {
    private var stdinReplacement = -1

    actual fun open(path: ByteArray, mode: OpenMode): RawFile? {
        if (path.isEmpty() || path.contains(0)) return null
        val flags = when (mode) {
            OpenMode.READ -> O_RDONLY
            OpenMode.READ_WRITE -> O_RDWR
            OpenMode.WRITE -> O_WRONLY or O_CREAT or O_TRUNC
            OpenMode.WRITE_READ -> O_RDWR or O_CREAT or O_TRUNC
            OpenMode.APPEND -> O_WRONLY or O_CREAT or O_APPEND
            OpenMode.APPEND_READ -> O_RDWR or O_CREAT or O_APPEND
        }
        val fd = open(cname(path), flags, 438) // 0666 (and the umask), as fopen
        return if (fd < 0) null else RawFile(fd, true)
    }

    actual fun stdin(): RawFile? {
        val fd = dup(if (stdinReplacement >= 0) stdinReplacement else 0)
        return if (fd < 0) null else RawFile(fd, true)
    }

    actual fun freopenStdin(path: ByteArray): Boolean {
        val fd = open(cname(path), O_RDONLY)
        if (fd < 0) return false
        if (stdinReplacement >= 0) close(stdinReplacement)
        stdinReplacement = fd
        return true
    }

    private fun writeFd(fd: Int, b: ByteArray, off: Int, len: Int): Int {
        var done = 0
        while (done < len) {
            val n = b.usePinned { p -> write(fd, p.addressOf(off + done), (len - done).convert()) }
            if (n < 0) {
                if (errno == EINTR) continue
                return -errno
            }
            done += n.toInt()
        }
        return 0
    }

    actual fun writeStdout(b: ByteArray, off: Int, len: Int): Int {
        val r = writeFd(1, b, off, len)
        if (r == -EPIPE) platform.posix.exit(128 + 13)
        return if (r == 0) 0 else -1
    }

    actual fun writeStderr(b: ByteArray, off: Int, len: Int) {
        writeFd(2, b, off, len)
    }

    actual fun stdoutIsTty(): Boolean = isatty(1) != 0

    actual fun stdoutTell(): Long = lseek(1, 0.convert(), P_SEEK_CUR).toLong()

    actual fun getenv(name: String): ByteArray? = platform.posix.getenv(name)?.toKString()?.encodeToByteArray()

    actual fun setenv(name: String, value: ByteArray?) {
        if (value == null) punsetenv(name) else psetenv(name, cname(value), 1)
    }

    actual fun isDirectory(path: ByteArray): Boolean = nativeIsDirectory(cname(path))

    actual fun mkdir(path: ByteArray): Boolean = nativeMkdir(cname(path))

    actual fun pathId(path: ByteArray): FileId? = nativePathId(cname(path))

    actual fun readFile(path: ByteArray): ByteArray? {
        val f = open(path, OpenMode.READ) ?: return null
        val out = ByteVec(4096)
        val buf = ByteArray(65536)
        while (true) {
            val n = f.read(buf, 0, buf.size)
            if (n < 0) {
                f.close()
                return null
            }
            if (n == 0) break
            out.addAll(buf, 0, n)
        }
        f.close()
        return out.toByteArray()
    }

    actual fun currentUid(): Long = nativeUid()

    actual fun timeNow(): Long = platform.posix.time(null).toLong()

    actual fun currentDir(): ByteArray? {
        val buf = ByteArray(4096)
        val r = buf.usePinned { platform.posix.getcwd(it.addressOf(0), buf.size.convert()) }
        if (r == null) return null
        val n = buf.indexOf(0.toByte())
        return buf.copyOf(if (n < 0) buf.size else n)
    }

    actual fun nameBytes(s: String): ByteArray = s.encodeToByteArray()

    actual fun nameString(b: ByteArray): String = b.decodeToString()

    actual fun fetchUrl(url: ByteArray): FetchResult = nativeFetchUrl(cname(url))

    actual fun runSortann(record: ByteArray, annotator: ByteArray, dir: ByteArray?): Int {
        Stdout.flush()
        return nativeRunSortann(cname(record), cname(annotator), dir?.let { cname(it) })
    }

    actual fun exit(status: Int): Nothing {
        platform.posix.exit(status)
        throw IllegalStateException() // not reached
    }
}

@kotlin.native.concurrent.ThreadLocal
private object RandHolder {
    val r = GlibcRand()
}

internal actual fun processRand(): GlibcRand = RandHolder.r

// (Kotlin/Native: one lock-free path; the structures it protects are used by
// one thread at a time in the tools. A mutex could be added with
// platform.posix.pthread_mutex_t if needed.)
internal actual fun <T> withGlobalLock(block: () -> T): T = block()
