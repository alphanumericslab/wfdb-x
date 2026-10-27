// The platform layer on the JVM (see Platform.kt): files through
// java.nio FileChannels, the standard streams through the process's file
// descriptors, the environment through System.getenv plus the values set by
// setenv (the JVM cannot change its own environment; they are passed to
// child processes), network access through HttpURLConnection, and the
// sortann tool run as a new JVM with the same class path.
//
// File names, environment values and arguments are converted between bytes
// and Java strings with the platform's file name encoding
// (sun.jnu.encoding), so that names round-trip as the JVM sees them.
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

import java.io.File
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URI
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.charset.Charset
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

/** The charset of file names, arguments and environment values. */
internal val jnuCharset: Charset = try {
    Charset.forName(System.getProperty("sun.jnu.encoding") ?: "UTF-8")
} catch (e: Exception) {
    Charsets.UTF_8
}

/** Bytes to a Java string (file name encoding). */
fun jnuString(b: ByteArray): String = String(b, jnuCharset)

/** A Java string to bytes (file name encoding). */
fun jnuBytes(s: String): ByteArray = s.toByteArray(jnuCharset)

private fun path(b: ByteArray): Path? = try {
    Paths.get(jnuString(b))
} catch (e: Exception) {
    null
}

internal actual class RawFile internal constructor(
    private val ch: FileChannel,
    private val closeable: AutoCloseable?,
    private val id: FileId?,
    private val appendMode: Boolean,
) {
    actual fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        return try {
            val n = ch.read(ByteBuffer.wrap(b, off, len))
            if (n < 0) 0 else n
        } catch (e: IOException) {
            -1
        }
    }

    actual fun write(b: ByteArray, off: Int, len: Int): Boolean = try {
        val bb = ByteBuffer.wrap(b, off, len)
        while (bb.hasRemaining()) ch.write(bb)
        true
    } catch (e: IOException) {
        false
    }

    actual fun seek(offset: Long, whence: Int): Long = try {
        val target = when (whence) {
            SEEK_SET -> offset
            SEEK_CUR -> ch.position() + offset
            SEEK_END -> ch.size() + offset
            else -> -1
        }
        if (target < 0) -1 else {
            ch.position(target)
            target
        }
    } catch (e: Exception) {
        -1
    }

    actual fun position(): Long = try {
        if (appendMode) ch.size() else ch.position()
    } catch (e: Exception) {
        -1
    }

    actual fun size(): Long = try {
        ch.size()
    } catch (e: Exception) {
        -1
    }

    actual fun blksize(): Int = 4096

    actual fun fileId(): FileId? = id

    actual fun close(): Boolean {
        if (closeable == null) return true
        return try {
            closeable.close()
            true
        } catch (e: Exception) {
            false
        }
    }
}

private fun idOf(p: Path?): FileId? {
    if (p == null) return null
    return try {
        val a = Files.readAttributes(p, "unix:dev,ino")
        FileId((a["dev"] as Number).toLong(), (a["ino"] as Number).toLong())
    } catch (e: Exception) {
        try {
            val r = p.toRealPath()
            FileId(-1, -1, r.toString())
        } catch (e2: Exception) {
            null
        }
    }
}

private fun stdinChannel(): FileChannel = FileInputStream(FileDescriptor.`in`).channel

internal actual object Platform {
    private val envOverrides = HashMap<String, ByteArray?>()
    private var stdinReplacement: FileInputStream? = null
    private val stdoutStream = FileOutputStream(FileDescriptor.out)
    private val stderrStream = FileOutputStream(FileDescriptor.err)

    actual fun open(path: ByteArray, mode: OpenMode): RawFile? {
        val name = jnuString(path)
        if (name.isEmpty() || name.indexOf('\u0000') >= 0) return null
        return try {
            when (mode) {
                OpenMode.READ -> {
                    val s = FileInputStream(name)
                    RawFile(s.channel, s, idOf(path(path)), false)
                }
                OpenMode.WRITE -> {
                    val s = FileOutputStream(name, false)
                    RawFile(s.channel, s, idOf(path(path)), false)
                }
                OpenMode.APPEND -> {
                    val s = FileOutputStream(name, true)
                    RawFile(s.channel, s, idOf(path(path)), true)
                }
                OpenMode.READ_WRITE, OpenMode.WRITE_READ, OpenMode.APPEND_READ -> {
                    if (mode == OpenMode.READ_WRITE && !File(name).exists()) return null
                    val f = RandomAccessFile(name, "rw")
                    if (mode == OpenMode.WRITE_READ) f.setLength(0)
                    RawFile(f.channel, f, idOf(path(path)), mode == OpenMode.APPEND_READ)
                }
            }
        } catch (e: Exception) {
            null
        }
    }

    actual fun stdin(): RawFile? {
        val r = stdinReplacement
        return if (r != null) RawFile(r.channel, null, null, false) else RawFile(stdinChannel(), null, null, false)
    }

    actual fun freopenStdin(path: ByteArray): Boolean = try {
        stdinReplacement = FileInputStream(jnuString(path))
        true
    } catch (e: Exception) {
        false
    }

    actual fun writeStdout(b: ByteArray, off: Int, len: Int): Int = try {
        stdoutStream.write(b, off, len)
        0
    } catch (e: IOException) {
        if ((e.message ?: "").contains("Broken pipe")) {
            // As a C program killed by SIGPIPE (13) would be seen by the shell.
            Runtime.getRuntime().halt(128 + 13)
        }
        -1
    }

    actual fun writeStderr(b: ByteArray, off: Int, len: Int) {
        try {
            stderrStream.write(b, off, len)
        } catch (e: IOException) {
        }
    }

    actual fun stdoutIsTty(): Boolean {
        val c = System.console() ?: return false
        return try {
            val m = c.javaClass.getMethod("isTerminal")
            m.invoke(c) as Boolean
        } catch (e: Exception) {
            true
        }
    }

    actual fun stdoutTell(): Long = try {
        stdoutStream.channel.position()
    } catch (e: Exception) {
        -1
    }

    actual fun getenv(name: String): ByteArray? {
        if (envOverrides.containsKey(name)) return envOverrides[name]
        return System.getenv(name)?.let { jnuBytes(it) }
    }

    actual fun setenv(name: String, value: ByteArray?) {
        envOverrides[name] = value
    }

    /** Applies the values set by setenv to the environment of a child process. */
    internal fun applyEnv(env: MutableMap<String, String>) {
        for ((k, v) in envOverrides) if (v == null) env.remove(k) else env[k] = jnuString(v)
    }

    actual fun isDirectory(path: ByteArray): Boolean = File(jnuString(path)).isDirectory

    actual fun mkdir(path: ByteArray): Boolean = File(jnuString(path)).mkdir()

    actual fun pathId(path: ByteArray): FileId? {
        val p = path(path) ?: return null
        if (!Files.exists(p)) return null
        return idOf(p)
    }

    actual fun readFile(path: ByteArray): ByteArray? = try {
        Files.readAllBytes(Paths.get(jnuString(path)))
    } catch (e: Exception) {
        null
    }

    actual fun currentUid(): Long = try {
        (Files.getAttribute(Paths.get("/proc/self"), "unix:uid") as Number).toLong()
    } catch (e: Exception) {
        -1
    }

    actual fun timeNow(): Long = Math.floorDiv(System.currentTimeMillis(), 1000L)

    actual fun currentDir(): ByteArray? = System.getProperty("user.dir")?.let { jnuBytes(File(it).absolutePath) }

    actual fun nameBytes(s: String): ByteArray = jnuBytes(s)

    actual fun nameString(b: ByteArray): String = jnuString(b)

    actual fun fetchUrl(url: ByteArray): FetchResult {
        var u = String(url, Charsets.ISO_8859_1)
        try {
            for (hop in 0 until 20) {
                val c = URI(u).toURL().openConnection() as HttpURLConnection
                c.connectTimeout = 30_000 // connecting may take 30 s
                c.readTimeout = 30_000 // no data for 30 s: give up (no total limit)
                c.instanceFollowRedirects = false
                c.setRequestProperty("User-Agent", "wfdb-x")
                val code = c.responseCode
                if (code in 300..399) {
                    val loc = c.getHeaderField("Location") ?: return FetchResult(null, false)
                    u = URI(u).resolve(loc).toString()
                    c.disconnect()
                    continue
                }
                if (code >= 400) {
                    c.disconnect()
                    return FetchResult(null, false)
                }
                val data = c.inputStream.use { it.readBytes() }
                c.disconnect()
                return FetchResult(data, false)
            }
        } catch (e: Exception) {
        }
        return FetchResult(null, false)
    }

    actual fun runSortann(record: ByteArray, annotator: ByteArray, dir: ByteArray?): Int {
        Stdout.flush()
        return try {
            val java = Paths.get(System.getProperty("java.home"), "bin", "java").toString()
            val cp = System.getProperty("java.class.path")
            val pb = ProcessBuilder(
                java, "-cp", cp, "wfdbx.cli.MainKt", "sortann", "--legacy", "-r.",
                jnuString(record), "-a", jnuString(annotator),
            )
            if (dir != null) pb.directory(File(jnuString(dir)))
            applyEnv(pb.environment())
            pb.inheritIO()
            pb.start().waitFor()
        } catch (e: Exception) {
            -1
        }
    }

    actual fun exit(status: Int): Nothing {
        System.out.flush()
        Runtime.getRuntime().halt(status)
        throw IllegalStateException() // not reached
    }
}

private val processRandTl: ThreadLocal<GlibcRand> = ThreadLocal.withInitial { GlibcRand() }

internal actual fun processRand(): GlibcRand = processRandTl.get()

private val globalLock = Any()

internal actual fun <T> withGlobalLock(block: () -> T): T = synchronized(globalLock) { block() }
