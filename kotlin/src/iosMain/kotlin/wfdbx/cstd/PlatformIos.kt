// iOS parts of the native platform layer: struct stat, and network access
// through NSURLSession (written, but not built or tested on Linux). iOS
// cannot run programs, so legacy mode cannot run sortann (the file is then
// left to be rearranged, as when sortann is not found).
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

@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package wfdbx.cstd

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.usePinned
import platform.Foundation.NSData
import platform.Foundation.NSHTTPURLResponse
import platform.Foundation.NSMutableURLRequest
import platform.Foundation.NSURL
import platform.Foundation.NSURLSession
import platform.Foundation.NSURLSessionConfiguration
import platform.Foundation.dataTaskWithRequest
import platform.darwin.DISPATCH_TIME_FOREVER
import platform.darwin.dispatch_semaphore_create
import platform.darwin.dispatch_semaphore_signal
import platform.darwin.dispatch_semaphore_wait
import platform.posix.S_IFDIR
import platform.posix.S_IFMT
import platform.posix.fstat
import platform.posix.getuid
import platform.posix.memcpy
import platform.posix.mkdir
import platform.posix.stat

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
    stat(path, st.ptr) == 0 && (st.st_mode.toInt() and S_IFMT.toInt()) == S_IFDIR.toInt()
}

internal actual fun nativeMkdir(path: String): Boolean = mkdir(path, 493.convert()) == 0 // 0755

internal actual fun nativeUid(): Long = getuid().toLong()

internal actual fun nativeFetchUrl(url: String): FetchResult {
    val u = NSURL.URLWithString(url) ?: return FetchResult(null, false)
    val config = NSURLSessionConfiguration.ephemeralSessionConfiguration
    config.timeoutIntervalForRequest = 30.0 // no data for 30 s: give up (no total limit)
    val session = NSURLSession.sessionWithConfiguration(config)
    val request = NSMutableURLRequest.requestWithURL(u)
    val sem = dispatch_semaphore_create(0)
    var result: ByteArray? = null
    val task = session.dataTaskWithRequest(request) { data: NSData?, response, error ->
        val status = (response as? NSHTTPURLResponse)?.statusCode ?: 0
        if (error == null && data != null && status < 400) {
            val n = data.length.toInt()
            val b = ByteArray(n)
            if (n > 0) b.usePinned { p -> memcpy(p.addressOf(0), data.bytes, data.length) }
            result = b
        }
        dispatch_semaphore_signal(sem)
    }
    task.resume()
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER)
    session.finishTasksAndInvalidate()
    return FetchResult(result, false)
}

internal actual fun nativeRunSortann(record: String, annotator: String, dir: String?): Int = -1
