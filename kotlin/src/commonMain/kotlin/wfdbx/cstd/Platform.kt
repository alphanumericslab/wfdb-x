// The platform layer: the few operating-system services that common code
// cannot provide (files, the standard streams, the environment, processes,
// network access). Each platform (jvmMain, nativeMain) implements these
// declarations; everything else is common code.
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

/** How [Platform.open] opens a file (C fopen modes, without "b"). */
enum class OpenMode(val read: Boolean, val write: Boolean) {
    /** "r" */
    READ(true, false),

    /** "r+" */
    READ_WRITE(true, true),

    /** "w": created or truncated. */
    WRITE(false, true),

    /** "w+" */
    WRITE_READ(true, true),

    /** "a": created; every write goes to the end. */
    APPEND(false, true),

    /** "a+" */
    APPEND_READ(true, true),
}

/**
 * The identity of a file: device and inode numbers where the platform has
 * them; otherwise ([dev] and [ino] -1) the canonical path in [path].
 */
data class FileId(val dev: Long, val ino: Long, val path: String? = null)

/** An open file descriptor (or the platform's equivalent), unbuffered. */
internal expect class RawFile {
    /** Reads up to [len] bytes: the number read, 0 at end of file, -1 on error. */
    fun read(b: ByteArray, off: Int, len: Int): Int

    /** Writes all [len] bytes; false on error. */
    fun write(b: ByteArray, off: Int, len: Int): Boolean

    /** C lseek: the new position, or -1 (e.g. on a pipe). */
    fun seek(offset: Long, whence: Int): Long

    /** The current position, or -1 if unknown (a pipe). */
    fun position(): Long

    /** The size of the file, or -1 if unknown. */
    fun size(): Long

    /** The preferred I/O block size (st_blksize; 4096 if unknown). */
    fun blksize(): Int

    /** The identity of the file, or null. */
    fun fileId(): FileId?

    /** Closes it (the standard input is never closed); false on error. */
    fun close(): Boolean
}

/** Result of [Platform.fetchUrl]: the data, or null with [toolMissing] if the download program could not be run. */
internal class FetchResult(val data: ByteArray?, val toolMissing: Boolean)

/** Operating-system services (one implementation per platform). */
internal expect object Platform {
    /** Opens a file (no directory creation); null on failure. */
    fun open(path: ByteArray, mode: OpenMode): RawFile?

    /** A duplicate of the standard input (or of the file attached by [freopenStdin]). */
    fun stdin(): RawFile?

    /** C `freopen(name, "rb", stdin)`; false if the file cannot be opened. */
    fun freopenStdin(path: ByteArray): Boolean

    /**
     * Writes to the standard output: 0, or -1 on error. If the reader of a
     * pipe has gone away, the process exits with status 141 (as a C program
     * killed by SIGPIPE appears to the shell).
     */
    fun writeStdout(b: ByteArray, off: Int, len: Int): Int

    /** Writes to the standard error (errors ignored). */
    fun writeStderr(b: ByteArray, off: Int, len: Int)

    /** Whether the standard output is a terminal. */
    fun stdoutIsTty(): Boolean

    /** `ftell(stdout)` after its buffer was written out, or -1 if not seekable. */
    fun stdoutTell(): Long

    /** C `getenv` (the value as bytes), including the values set by [setenv]. */
    fun getenv(name: String): ByteArray?

    /** C `setenv` (value null: `unsetenv`); seen by [getenv] and by child processes. */
    fun setenv(name: String, value: ByteArray?)

    /** Whether [path] names a directory. */
    fun isDirectory(path: ByteArray): Boolean

    /** C `mkdir(path, 0755)`; false on failure. */
    fun mkdir(path: ByteArray): Boolean

    /** The identity of the existing file [path] (following links), or null. */
    fun pathId(path: ByteArray): FileId?

    /** The whole contents of a local file, or null. */
    fun readFile(path: ByteArray): ByteArray?

    /** The user ID of the process, or -1 if unknown. */
    fun currentUid(): Long

    /** C `time(NULL)`: the current time, in seconds since 1970-01-01 00:00:00 UTC. */
    fun timeNow(): Long

    /**
     * Downloads a URL in full (redirects followed, an HTTP status of 400 or
     * more is a failure; gives up if connecting takes 30 s or no data
     * arrive for 30 s, with no limit on the total time).
     */
    fun fetchUrl(url: ByteArray): FetchResult

    /**
     * Runs `sortann --legacy -r. RECORD -a ANNOTATOR` (without a shell, in
     * the directory [dir] if not null) and returns its exit status (-1 if it
     * could not be run). The standard output and error are flushed first.
     */
    fun runSortann(record: ByteArray, annotator: ByteArray, dir: ByteArray?): Int

    /** Ends the process (without flushing anything). */
    fun exit(status: Int): Nothing

    /** The current directory (absolute), or null if unknown (wfdb-x: for checkRecord). */
    fun currentDir(): ByteArray?

    /** A file name given as a string, as bytes in the encoding of file names (for the high-level API). */
    fun nameBytes(s: String): ByteArray

    /** A file name (bytes in the encoding of file names) as a string. */
    fun nameString(b: ByteArray): String
}

/**
 * Runs [block] holding the process-wide lock that protects the few
 * process-wide structures (the list of open output streams, the cache of
 * fetched URLs), so that separate Wfdb instances may be used by different
 * threads.
 */
internal expect fun <T> withGlobalLock(block: () -> T): T
