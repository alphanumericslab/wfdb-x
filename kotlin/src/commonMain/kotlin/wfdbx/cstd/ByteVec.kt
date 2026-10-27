// A growable byte array (Rust's Vec<u8>, C's char buffers), and conversions
// between Kotlin strings and C byte strings.
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

/**
 * A growable array of bytes, used to build C strings and file contents.
 *
 * [bytes] may be longer than [size]; only the first [size] bytes are valid.
 */
class ByteVec(capacity: Int = 16) {
    /** The storage (valid up to [size]). */
    var bytes: ByteArray = ByteArray(if (capacity < 1) 1 else capacity)
        private set

    /** The number of bytes held. */
    var size: Int = 0
        private set

    private fun grow(need: Int) {
        if (need <= bytes.size) return
        var n = bytes.size * 2
        if (n < need) n = need
        bytes = bytes.copyOf(n)
    }

    /** Appends one byte (the low 8 bits of [b]). */
    fun add(b: Int) {
        if (size == bytes.size) grow(size + 1)
        bytes[size++] = b.toByte()
    }

    /** Appends one byte. */
    fun add(b: Byte) {
        if (size == bytes.size) grow(size + 1)
        bytes[size++] = b
    }

    /** Appends `len` bytes of [a] from [off]. */
    fun addAll(a: ByteArray, off: Int = 0, len: Int = a.size - off) {
        if (len <= 0) return
        grow(size + len)
        a.copyInto(bytes, size, off, off + len)
        size += len
    }

    /** Appends the bytes (ISO-8859-1) of [s]. */
    fun addString(s: String) {
        grow(size + s.length)
        for (c in s) bytes[size++] = c.code.toByte()
    }

    /** Appends [n] copies of [b]. */
    fun fill(b: Int, n: Int) {
        if (n <= 0) return
        grow(size + n)
        bytes.fill(b.toByte(), size, size + n)
        size += n
    }

    /** The byte at [i] (0..255). */
    operator fun get(i: Int): Int = bytes[i].toInt() and 0xff

    /** Sets the byte at [i]. */
    operator fun set(i: Int, b: Int) {
        bytes[i] = b.toByte()
    }

    /** The last byte (0..255), or -1 if empty. */
    fun last(): Int = if (size == 0) -1 else bytes[size - 1].toInt() and 0xff

    /** Removes the last byte. */
    fun pop() {
        if (size > 0) size--
    }

    /** Sets the size to [n] (which must not exceed the current size). */
    fun truncate(n: Int) {
        if (n < size) size = if (n < 0) 0 else n
    }

    /** Empties the vector. */
    fun clear() {
        size = 0
    }

    /** Whether it is empty. */
    fun isEmpty(): Boolean = size == 0

    /** A copy of the bytes held. */
    fun toByteArray(): ByteArray = bytes.copyOf(size)

    /** A copy of the bytes from [from] to [to]. */
    fun slice(from: Int, to: Int = size): ByteArray = bytes.copyOfRange(from, to)

    /** The bytes as an ISO-8859-1 string. */
    override fun toString(): String = latin1String(bytes, 0, size)
}

/** The bytes of a string, one byte per character (ISO-8859-1; characters above 255 are truncated). */
fun String.latin1(): ByteArray {
    val r = ByteArray(length)
    for (i in indices) r[i] = this[i].code.toByte()
    return r
}

/** A string with one character per byte (ISO-8859-1). */
fun ByteArray.latin1(): String = latin1String(this, 0, size)

/** A string with one character per byte of `a[off until off + len]`. */
fun latin1String(a: ByteArray, off: Int, len: Int): String {
    val c = CharArray(len)
    for (i in 0 until len) c[i] = (a[off + i].toInt() and 0xff).toChar()
    return c.concatToString()
}

/** The C string held in [s]: the bytes before the first NUL (all of [s] if there is none). */
fun cstr(s: ByteArray): ByteArray {
    val z = s.indexOf(0.toByte())
    return if (z < 0) s else s.copyOf(z)
}

/** The length of the C string held in [s] (C `strlen`). */
fun cstrlen(s: ByteArray): Int {
    val z = s.indexOf(0.toByte())
    return if (z < 0) s.size else z
}

/** Whether two byte strings are equal (C `strcmp(a, b) == 0` on C strings without NULs). */
fun beq(a: ByteArray?, b: ByteArray?): Boolean =
    if (a == null || b == null) a === b else a.contentEquals(b)

/** Whether [a] equals the ISO-8859-1 bytes of [s]. */
fun beq(a: ByteArray?, s: String): Boolean {
    if (a == null || a.size != s.length) return false
    for (i in a.indices) if ((a[i].toInt() and 0xff) != s[i].code) return false
    return true
}

/** Whether [a] begins with [p]. */
fun ByteArray.startsWith(p: ByteArray): Boolean {
    if (p.size > size) return false
    for (i in p.indices) if (this[i] != p[i]) return false
    return true
}

/** Whether [a] begins with the ISO-8859-1 bytes of [p]. */
fun ByteArray.startsWith(p: String): Boolean {
    if (p.length > size) return false
    for (i in p.indices) if ((this[i].toInt() and 0xff) != p[i].code) return false
    return true
}

/** Whether [a] ends with the ISO-8859-1 bytes of [p]. */
fun ByteArray.endsWith(p: String): Boolean {
    if (p.length > size) return false
    val o = size - p.length
    for (i in p.indices) if ((this[o + i].toInt() and 0xff) != p[i].code) return false
    return true
}

/** The position of the first occurrence of [needle] in this array at or after [from], or -1. */
fun ByteArray.indexOf(needle: ByteArray, from: Int = 0): Int {
    if (needle.isEmpty()) return from
    var i = from
    while (i + needle.size <= size) {
        var k = 0
        while (k < needle.size && this[i + k] == needle[k]) k++
        if (k == needle.size) return i
        i++
    }
    return -1
}

/** The concatenation of byte strings. */
fun bcat(vararg parts: ByteArray): ByteArray {
    var n = 0
    for (p in parts) n += p.size
    val r = ByteArray(n)
    var o = 0
    for (p in parts) {
        p.copyInto(r, o)
        o += p.size
    }
    return r
}

/** The byte at [i] of this array as an unsigned value (0..255), or 0 past the end (C's terminating NUL). */
fun ByteArray.at(i: Int): Int = if (i in indices) this[i].toInt() and 0xff else 0
