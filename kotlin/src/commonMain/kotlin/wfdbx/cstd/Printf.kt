// glibc-exact printf formatting (port of rust/src/cstd/printf.rs).
//
// [sprintf] formats a C format string with arguments, producing exactly the
// bytes glibc's printf produces on x86-64 Linux. Supported: the conversions
// d i u x X o c s e E f F g G %, the flags - + space # 0, field width and
// precision (also given as *), and the length modifiers hh h l ll L q j z t
// (integer arguments are converted to the C type the conversion reads: int
// without a modifier, short/char with h/hh, 64 bits with l, ll, j, z, t).
//
// Arguments are Kotlin values: Int, Long, Short, Byte (signed integers),
// UInt, ULong, UShort, UByte (unsigned), Double, Float, Char (its code),
// Boolean (0 or 1), ByteArray, ByteVec or String (for %s; String characters
// are ISO-8859-1 bytes), and null (C's NULL: "(null)" for %s, 0 otherwise).
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
 * C conversion of a double to a 32-bit int on x86 (cvttsd2si): truncation
 * toward zero; NaN and out-of-range values give Int.MIN_VALUE.
 */
fun d2i(x: Double): Int =
    if (x > -2147483649.0 && x < 2147483648.0) x.toInt() else Int.MIN_VALUE

/**
 * C conversion of a double to a 64-bit long on x86: truncation toward zero;
 * NaN and out-of-range values give Long.MIN_VALUE.
 */
fun d2l(x: Double): Long =
    if (x >= -9223372036854775808.0 && x < 9223372036854775808.0) x.toLong() else Long.MIN_VALUE

private const val LEN_NONE = 0
private const val LEN_H = 1
private const val LEN_HH = 2
private const val LEN_L = 3

private class Spec {
    var left = false
    var plus = false
    var space = false
    var alt = false
    var zero = false
    var width = 0
    var prec = -1 // -1: none
}

/** The signed 64-bit value of an integer argument (before narrowing). */
private fun rawSigned(a: Any?, len: Int): Long = when (a) {
    null -> 0L
    is Int -> a.toLong()
    is Long -> a
    is Short -> a.toLong()
    is Byte -> a.toLong()
    is UInt -> a.toLong()
    is ULong -> a.toLong()
    is UShort -> a.toLong()
    is UByte -> a.toLong()
    is Char -> a.code.toLong()
    is Boolean -> if (a) 1L else 0L
    is Double -> if (len == LEN_L) d2l(a) else d2i(a).toLong()
    is Float -> if (len == LEN_L) d2l(a.toDouble()) else d2i(a.toDouble()).toLong()
    is ByteArray -> if (a.isEmpty()) 0L else a[0].toLong() and 0xff
    is String -> if (a.isEmpty()) 0L else (a[0].code and 0xff).toLong()
    else -> 0L
}

private fun argSigned(a: Any?, len: Int): Long {
    val raw = rawSigned(a, len)
    return when (len) {
        LEN_NONE -> raw.toInt().toLong()
        LEN_H -> raw.toShort().toLong()
        LEN_HH -> raw.toByte().toLong()
        else -> raw
    }
}

/** The unsigned value (as the bits of a Long) of an integer argument. */
private fun argUnsigned(a: Any?, len: Int): Long {
    val raw = rawSigned(a, len)
    return when (len) {
        LEN_NONE -> raw and 0xffffffffL
        LEN_H -> raw and 0xffffL
        LEN_HH -> raw and 0xffL
        else -> raw
    }
}

private fun argInt(a: Any?): Int = when (a) {
    is Double -> d2i(a)
    is Float -> d2i(a.toDouble())
    else -> rawSigned(a, LEN_L).toInt()
}

private fun argDouble(a: Any?): Double = when (a) {
    is Double -> a
    is Float -> a.toDouble()
    is Int -> a.toDouble()
    is Long -> a.toDouble()
    is Short -> a.toDouble()
    is Byte -> a.toDouble()
    is UInt -> a.toDouble()
    is ULong -> a.toDouble()
    is UShort -> a.toDouble()
    is UByte -> a.toDouble()
    else -> 0.0
}

/** Writes prefix + body padded to the field width; zeroOk: zero padding allowed (after the prefix). */
private fun pad(out: ByteVec, sp: Spec, prefix: String, body: ByteVec, zeroOk: Boolean) {
    val len = prefix.length + body.size
    if (sp.width <= len) {
        out.addString(prefix)
        out.addAll(body.bytes, 0, body.size)
        return
    }
    val fill = sp.width - len
    if (sp.left) {
        out.addString(prefix)
        out.addAll(body.bytes, 0, body.size)
        out.fill(' '.code, fill)
    } else if (sp.zero && zeroOk) {
        out.addString(prefix)
        out.fill('0'.code, fill)
        out.addAll(body.bytes, 0, body.size)
    } else {
        out.fill(' '.code, fill)
        out.addString(prefix)
        out.addAll(body.bytes, 0, body.size)
    }
}

private const val DIGITS_LOWER = "0123456789abcdef"
private const val DIGITS_UPPER = "0123456789ABCDEF"

private fun fmtInt(out: ByteVec, sp: Spec, conv: Char, arg: Any?, len: Int) {
    val buf = ByteArray(24)
    var i = buf.size
    val neg: Boolean
    var mag: Long // unsigned bits
    if (conv == 'd' || conv == 'i') {
        val v = argSigned(arg, len)
        neg = v < 0
        mag = if (neg) -v else v // Long.MIN_VALUE stays: its unsigned magnitude is 2^63
    } else {
        neg = false
        mag = argUnsigned(arg, len)
    }
    val base = when (conv) {
        'x', 'X' -> 16
        'o' -> 8
        else -> 10
    }
    val digits = if (conv == 'X') DIGITS_UPPER else DIGITS_LOWER
    val isZero = mag == 0L
    var v = mag
    while (v != 0L) {
        val d = v.toULong() % base.toULong()
        i--
        buf[i] = digits[d.toInt()].code.toByte()
        v = (v.toULong() / base.toULong()).toLong()
    }
    if (isZero && sp.prec != 0) {
        i--
        buf[i] = '0'.code.toByte()
    }
    val ndig = buf.size - i
    val body = ByteVec(32)
    if (sp.prec > ndig) body.fill('0'.code, sp.prec - ndig)
    body.addAll(buf, i, ndig)
    var prefix = ""
    when (conv) {
        'd', 'i' -> prefix = if (neg) "-" else if (sp.plus) "+" else if (sp.space) " " else ""
        'o' -> if (sp.alt && (body.size == 0 || body[0] != '0'.code)) {
            val b2 = ByteVec(body.size + 1)
            b2.add('0'.code)
            b2.addAll(body.bytes, 0, body.size)
            pad(out, sp, "", b2, sp.prec < 0)
            return
        }
        'x' -> if (sp.alt && !isZero) prefix = "0x"
        'X' -> if (sp.alt && !isZero) prefix = "0X"
    }
    pad(out, sp, prefix, body, sp.prec < 0)
}

/** Fixed-notation digits: k holds digits with value `0.k * 10^point`; prec digits after the point. */
private fun fixedBody(body: ByteVec, k: ByteArray, point: Int, prec: Int, alt: Boolean) {
    if (point > 0) {
        if (k.size >= point) {
            body.addAll(k, 0, point)
        } else {
            body.addAll(k)
            body.fill('0'.code, point - k.size)
        }
    } else {
        body.add('0'.code)
    }
    if (prec > 0 || alt) body.add('.'.code)
    for (i in 0 until prec) {
        val idx = point.toLong() + i
        val c = if (idx < 0 || idx >= k.size) '0'.code.toByte() else k[idx.toInt()]
        body.add(c)
    }
}

private fun expBody(body: ByteVec, k: ByteArray, klen: Int, exp: Int, alt: Boolean, strip: Boolean, upper: Boolean) {
    body.add(k[0])
    var end = klen
    if (strip) while (end > 1 && k[end - 1] == '0'.code.toByte()) end--
    if (end > 1 || alt) {
        body.add('.'.code)
        body.addAll(k, 1, end - 1)
    }
    body.add(if (upper) 'E'.code else 'e'.code)
    body.add(if (exp < 0) '-'.code else '+'.code)
    val a = if (exp < 0) -exp else exp
    if (a < 10) body.add('0'.code)
    body.addString(a.toString())
}

private fun stripZeros(body: ByteVec) {
    var hasPoint = false
    for (i in 0 until body.size) if (body[i] == '.'.code) {
        hasPoint = true
        break
    }
    if (!hasPoint) return
    while (body.last() == '0'.code) body.pop()
    if (body.last() == '.'.code) body.pop()
}

private fun fmtFloat(out: ByteVec, sp: Spec, conv: Char, x: Double) {
    val upper = conv.isUpperCase()
    val negative = (x.toRawBits() ushr 63) != 0L
    val prefix = if (negative) "-" else if (sp.plus) "+" else if (sp.space) " " else ""
    val body = ByteVec(32)
    if (x.isNaN() || x.isInfinite()) {
        body.addString(
            if (x.isNaN()) (if (upper) "NAN" else "nan") else (if (upper) "INF" else "inf")
        )
        pad(out, sp, prefix, body, false)
        return
    }
    val prec = if (sp.prec < 0) 6 else sp.prec // the C default precision
    when (conv) {
        'f', 'F' -> {
            val d = digitsFixed(x, prec)
            fixedBody(body, d.k, d.point, prec, sp.alt)
        }
        'e', 'E' -> {
            val d = digitsExp(x, prec + 1)
            expBody(body, d.k, d.k.size, d.point, sp.alt, false, upper)
        }
        else -> {
            // %g, %G
            val p = if (prec == 0) 1 else prec
            val d = digitsExp(x, p)
            val xexp = d.point
            if (d.carried && xexp == p) {
                // glibc chose fixed notation from the unrounded exponent
                // (p - 1), with no fraction digits; when rounding carries
                // into exponent p it switches to exponential notation but
                // keeps zero fraction digits: "%#g" of 999999.5 is
                // "1.e+06", not "1.00000e+06".
                expBody(body, d.k, 1, xexp, sp.alt, true, upper)
            } else if (xexp < p && xexp >= -4) {
                // C: %g uses %e style if the exponent is < -4 or >= P
                fixedBody(body, d.k, xexp + 1, p - 1 - xexp, sp.alt)
                if (!sp.alt) stripZeros(body)
            } else {
                expBody(body, d.k, d.k.size, xexp, sp.alt, !sp.alt, upper)
            }
        }
    }
    pad(out, sp, prefix, body, true)
}

private val NULL_STR = "(null)".latin1()

/**
 * Formats [fmt] with [args] as glibc's sprintf does, appending the result
 * to [out]. Returns the number of bytes appended. The format ends at its
 * end or at a NUL byte. Missing arguments are taken as 0 (or NULL for
 * %s); unknown conversions are copied to the output unchanged.
 */
fun sprintfInto(out: ByteVec, fmt: ByteArray, args: Array<out Any?>): Int {
    val start = out.size
    var n = fmt.indexOf(0.toByte())
    if (n < 0) n = fmt.size
    var i = 0
    var ai = 0
    while (i < n) {
        val litStart = i
        while (i < n && fmt[i] != '%'.code.toByte()) i++
        if (i > litStart) out.addAll(fmt, litStart, i - litStart)
        if (i >= n) break
        val specStart = i
        i++
        val sp = Spec()
        // Flags
        flags@ while (i < n) {
            when (fmt[i].toInt().toChar()) {
                '-' -> sp.left = true
                '+' -> sp.plus = true
                ' ' -> sp.space = true
                '#' -> sp.alt = true
                '0' -> sp.zero = true
                '\'', 'I' -> {}
                else -> break@flags
            }
            i++
        }
        // Width
        if (i < n && fmt[i] == '*'.code.toByte()) {
            val w = argInt(args.getOrNull(ai))
            ai++
            if (w < 0) sp.left = true
            sp.width = if (w == Int.MIN_VALUE) Int.MAX_VALUE else if (w < 0) -w else w
            i++
        } else {
            while (i < n && fmt[i] >= '0'.code.toByte() && fmt[i] <= '9'.code.toByte()) {
                val d = fmt[i] - '0'.code.toByte()
                sp.width = if (sp.width > (Int.MAX_VALUE - d) / 10) Int.MAX_VALUE else sp.width * 10 + d
                i++
            }
        }
        // Precision
        if (i < n && fmt[i] == '.'.code.toByte()) {
            i++
            if (i < n && fmt[i] == '*'.code.toByte()) {
                val p = argInt(args.getOrNull(ai))
                ai++
                sp.prec = if (p < 0) -1 else p
                i++
            } else {
                var p = 0
                while (i < n && fmt[i] >= '0'.code.toByte() && fmt[i] <= '9'.code.toByte()) {
                    val d = fmt[i] - '0'.code.toByte()
                    p = if (p > (Int.MAX_VALUE - d) / 10) Int.MAX_VALUE else p * 10 + d
                    i++
                }
                sp.prec = p
            }
        }
        // Length modifier
        var len = LEN_NONE
        lens@ while (i < n) {
            when (fmt[i].toInt().toChar()) {
                'h' -> len = if (len == LEN_H) LEN_HH else LEN_H
                'l', 'L', 'q', 'j', 'z', 't' -> len = LEN_L
                else -> break@lens
            }
            i++
        }
        if (i >= n) {
            out.addAll(fmt, specStart, n - specStart)
            break
        }
        val conv = fmt[i].toInt().toChar()
        i++
        when (conv) {
            'd', 'i', 'u', 'x', 'X', 'o' -> {
                val a = args.getOrNull(ai)
                ai++
                fmtInt(out, sp, conv, a, len)
            }
            'e', 'E', 'f', 'F', 'g', 'G' -> {
                val x = argDouble(args.getOrNull(ai))
                ai++
                fmtFloat(out, sp, conv, x)
            }
            'c' -> {
                val a = args.getOrNull(ai)
                ai++
                val c = when (a) {
                    is ByteArray -> if (a.isEmpty()) 0 else a[0].toInt()
                    is String -> if (a.isEmpty()) 0 else a[0].code
                    else -> argSigned(a, LEN_L).toInt()
                }
                val body = ByteVec(1)
                body.add(c)
                pad(out, sp, "", body, false)
            }
            's' -> {
                val a = args.getOrNull(ai)
                ai++
                val s: ByteArray
                var slen: Int
                when (a) {
                    is ByteArray -> {
                        s = a
                        slen = cstrlen(a)
                    }
                    is ByteVec -> {
                        s = a.bytes
                        slen = 0
                        while (slen < a.size && s[slen] != 0.toByte()) slen++
                    }
                    is String -> {
                        s = a.latin1()
                        slen = cstrlen(s)
                    }
                    else -> {
                        // glibc prints "(null)", or nothing if the precision
                        // would truncate it.
                        s = NULL_STR
                        slen = if (sp.prec in 0 until NULL_STR.size) 0 else NULL_STR.size
                    }
                }
                if (sp.prec in 0 until slen) slen = sp.prec
                val body = ByteVec(slen)
                body.addAll(s, 0, slen)
                pad(out, sp, "", body, false)
            }
            '%' -> out.add('%'.code)
            else -> out.addAll(fmt, specStart, i - specStart)
        }
    }
    return out.size - start
}

/** [sprintfInto] with a format given as a string (one byte per character). */
fun sprintfInto(out: ByteVec, fmt: String, args: Array<out Any?>): Int = sprintfInto(out, fmt.latin1(), args)

/** Formats [fmt] with [args] as glibc's sprintf does. */
fun sprintf(fmt: ByteArray, vararg args: Any?): ByteArray {
    val out = ByteVec(fmt.size + 16)
    sprintfInto(out, fmt, args)
    return out.toByteArray()
}

/** Formats [fmt] (one byte per character) with [args] as glibc's sprintf does. */
fun sprintf(fmt: String, vararg args: Any?): ByteArray {
    val out = ByteVec(fmt.length + 16)
    sprintfInto(out, fmt.latin1(), args)
    return out.toByteArray()
}

/** Same as [sprintf] (the name of the Rust macro). */
fun cformat(fmt: String, vararg args: Any?): ByteArray {
    val out = ByteVec(fmt.length + 16)
    sprintfInto(out, fmt.latin1(), args)
    return out.toByteArray()
}

/** Same as [sprintf] with a byte format. */
fun cformat(fmt: ByteArray, vararg args: Any?): ByteArray {
    val out = ByteVec(fmt.size + 16)
    sprintfInto(out, fmt, args)
    return out.toByteArray()
}
