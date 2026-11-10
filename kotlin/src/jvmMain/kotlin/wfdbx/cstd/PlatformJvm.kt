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
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation, either version 2.1 of the License, or (at
// your option) any later version. See LICENSE.

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
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption

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

/** The characters of the random part of a temporary file name. */
private const val TMP_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789_"

/** The permissions of a temporary file at its creation: rw------- (owner only). */
private val OWNER_ONLY = java.nio.file.attribute.PosixFilePermissions.asFileAttribute(
    java.nio.file.attribute.PosixFilePermissions.fromString("rw-------"),
)

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

    actual fun remove(path: ByteArray): Boolean = File(jnuString(path)).delete()

    actual fun replaceFile(dest: ByteArray, data: ByteArray): Boolean {
        val d = path(dest) ?: return false
        // (owner-only from its creation: the header may hold patient data)
        val t = createOwnerOnly(d) ?: return false
        try {
            FileChannel.open(t, StandardOpenOption.WRITE).use { ch ->
                val bb = ByteBuffer.wrap(data)
                while (bb.hasRemaining()) ch.write(bb)
                ch.force(true)
            }
            if (commit(t, d)) return true
        } catch (e: Exception) {
        }
        try {
            Files.deleteIfExists(t)
        } catch (e: Exception) {
        }
        return false
    }

    actual fun createTempFile(dest: ByteArray): ByteArray? {
        val d = path(dest) ?: return null
        return createOwnerOnly(d)?.let { jnuBytes(it.toString()) }
    }

    actual fun commitFile(tmp: ByteArray, dest: ByteArray): Boolean {
        val t = path(tmp) ?: return false
        val d = path(dest) ?: return false
        return try {
            commit(t, d)
        } catch (e: Exception) {
            false
        }
    }

    actual fun absolutePath(path: ByteArray): ByteArray? {
        val p = path(path) ?: return null
        return try {
            jnuBytes(p.toAbsolutePath().normalize().toString())
        } catch (e: Exception) {
            null
        }
    }

    actual fun realPath(path: ByteArray): ByteArray? {
        var p = path(path)?.let {
            try {
                it.toAbsolutePath().normalize()
            } catch (e: Exception) {
                null
            }
        } ?: return null
        try {
            if (Files.exists(p)) return jnuBytes(p.toRealPath().toString())
            // (a missing file, or a link to one: the links are followed as
            // far as they lead, as os.path.realpath does)
            var n = 0
            while (Files.isSymbolicLink(p) && n++ < 40) {
                val parent = p.parent ?: break
                p = parent.resolve(Files.readSymbolicLink(p)).normalize()
            }
            val parent = p.parent
            val name = p.fileName
            if (parent != null && name != null && Files.isDirectory(parent)) {
                p = parent.toRealPath().resolve(name)
            }
        } catch (e: Exception) {
        }
        return jnuBytes(p.toString())
    }

    actual fun isSpecialFile(path: ByteArray): Boolean {
        val p = path(path) ?: return false
        return try {
            Files.exists(p) && !Files.isRegularFile(p) && !Files.isDirectory(p)
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Creates a new, empty file `.NAME.XXXXXXXX.tmp` in the directory of
     * [dest], readable and writable by its owner only from its creation
     * (POSIX permissions rw-------, where the file system has them;
     * otherwise as any new file); null if it cannot be created.
     */
    private fun createOwnerOnly(dest: Path): Path? {
        val base = dest.fileName?.toString() ?: return null
        val dir = dest.parent ?: Paths.get("")
        val rnd = java.util.concurrent.ThreadLocalRandom.current()
        val posix = try {
            (dest.parent ?: dest.toAbsolutePath().parent ?: dest).fileSystem.supportedFileAttributeViews().contains("posix")
        } catch (e: Exception) {
            false
        }
        for (attempt in 0 until 100) {
            val suffix = String(CharArray(8) { TMP_CHARS[rnd.nextInt(TMP_CHARS.length)] })
            val cand = dir.resolve(".$base.$suffix.tmp")
            try {
                return if (posix) Files.createFile(cand, OWNER_ONLY) else Files.createFile(cand)
            } catch (e: FileAlreadyExistsException) {
            } catch (e: Exception) {
                return null
            }
        }
        return null
    }

    /**
     * Gives [tmp] the permission bits that writing [dest] in place would
     * give (those of dest if it exists, else those of a new file in its
     * directory: 0666 less the umask), then renames it over dest.
     */
    private fun commit(tmp: Path, dest: Path): Boolean {
        if (Files.exists(dest)) copyMode(dest, tmp) else newFileMode(dest)?.let { setMode(tmp, it) }
        try {
            Files.move(tmp, dest, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (e: AtomicMoveNotSupportedException) {
            Files.move(tmp, dest, StandardCopyOption.REPLACE_EXISTING)
        }
        return true
    }

    /**
     * The permission bits of a new file in the directory of [dest] (0666
     * less the umask, which the JVM cannot read): those of an empty file
     * created there, and removed at once; null where there are none.
     */
    private fun newFileMode(dest: Path): Int? {
        val base = dest.fileName?.toString() ?: return null
        val dir = dest.parent ?: Paths.get("")
        val rnd = java.util.concurrent.ThreadLocalRandom.current()
        for (attempt in 0 until 100) {
            val suffix = String(CharArray(8) { TMP_CHARS[rnd.nextInt(TMP_CHARS.length)] })
            val probe = dir.resolve(".$base.$suffix.tmp")
            try {
                Files.createFile(probe)
            } catch (e: FileAlreadyExistsException) {
                continue
            } catch (e: Exception) {
                return null
            }
            try {
                return modeOf(probe)
            } finally {
                try {
                    Files.deleteIfExists(probe)
                } catch (e: Exception) {
                }
            }
        }
        return null
    }

    /** The permission bits of [p] (12 where the "unix" view exists, else the 9 POSIX ones), or null. */
    internal fun modeOf(p: Path): Int? {
        try {
            return (Files.getAttribute(p, "unix:mode") as Number).toInt() and 0xfff
        } catch (e: Exception) {
        }
        return try {
            var m = 0
            for (perm in Files.getPosixFilePermissions(p)) m = m or (1 shl (8 - perm.ordinal))
            m
        } catch (e: Exception) {
            null
        }
    }

    /** Gives [p] the permission bits [mode] (see [modeOf]); nothing where there are none. */
    private fun setMode(p: Path, mode: Int) {
        try {
            Files.setAttribute(p, "unix:mode", mode)
            return
        } catch (e: Exception) {
        }
        try {
            val set = java.util.EnumSet.noneOf(java.nio.file.attribute.PosixFilePermission::class.java)
            for (perm in java.nio.file.attribute.PosixFilePermission.values()) {
                if (mode and (1 shl (8 - perm.ordinal)) != 0) set.add(perm)
            }
            Files.setPosixFilePermissions(p, set)
        } catch (e: Exception) {
        }
    }

    /** Gives [to] the permission bits of [from]. */
    private fun copyMode(from: Path, to: Path) {
        modeOf(from)?.let { setMode(to, it) }
    }

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
