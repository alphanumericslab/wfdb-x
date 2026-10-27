// C string parsing functions: strtol, strtoul, strtod, atoi, atol, atof,
// sscanf, strtok, and fgets-style line splitting, with the exact semantics
// of glibc in the C locale (port of rust/src/cstd/parse.rs).
//
// Positions are indices into a ByteArray. A function that returns a value
// and an end position (C's endptr) takes the start position `pos` and
// returns `end == pos` when no conversion was performed. A C string ends at
// the end of the array or at its first NUL byte.
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

/** C `isspace` in the C locale (space, \t, \n, \v, \f, \r). */
fun isspace(c: Int): Boolean = c == ' '.code || (c >= 9 && c <= 13)

/** C `isdigit`. */
fun isdigit(c: Int): Boolean = c >= '0'.code && c <= '9'.code

/** C `isxdigit`. */
fun isxdigit(c: Int): Boolean = isdigit(c) || (c >= 'a'.code && c <= 'f'.code) || (c >= 'A'.code && c <= 'F'.code)

/** C `isalnum` (C locale). */
fun isalnum(c: Int): Boolean = isdigit(c) || (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code)

/** C `isalpha` (C locale). */
fun isalpha(c: Int): Boolean = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code)

/** The end of the C string held in s from pos: the first NUL at or after pos, or s.size. */
private fun cend(s: ByteArray): Int {
    val z = s.indexOf(0.toByte())
    return if (z < 0) s.size else z
}

private fun u(s: ByteArray, i: Int): Int = s[i].toInt() and 0xff

private fun digitValue(c: Int): Int = when (c) {
    in '0'.code..'9'.code -> c - '0'.code
    in 'a'.code..'z'.code -> c - 'a'.code + 10
    in 'A'.code..'Z'.code -> c - 'A'.code + 10
    else -> Int.MAX_VALUE
}

private fun lower(c: Int): Int = c or 0x20

/** The result of [strtol] and [strtoul]: the value and C's endptr (`end == pos`: no conversion). */
class LongEnd(val value: Long, val end: Int) {
    /** The value. */
    operator fun component1(): Long = value

    /** The end position. */
    operator fun component2(): Int = end
}

/** The result of [strtod]: the value and C's endptr (`end == pos`: no conversion). */
class DoubleEnd(val value: Double, val end: Int) {
    /** The value. */
    operator fun component1(): Double = value

    /** The end position. */
    operator fun component2(): Int = end
}

private class IntParse(val neg: Boolean, val mag: Long, val ovf: Boolean, val end: Int)

/** Common part of strtol/strtoul (mag holds the unsigned 64-bit magnitude). end < 0: no conversion. */
private fun strtoInt(s: ByteArray, pos: Int, base0: Int): IntParse {
    val n = cend(s)
    var i = pos
    while (i < n && isspace(u(s, i))) i++
    var neg = false
    if (i < n && (u(s, i) == '+'.code || u(s, i) == '-'.code)) {
        neg = u(s, i) == '-'.code
        i++
    }
    var base = base0
    fun hexPrefix(i: Int) = i + 2 < n && u(s, i) == '0'.code && lower(u(s, i + 1)) == 'x'.code && isxdigit(u(s, i + 2))
    if (base == 0) {
        if (hexPrefix(i)) {
            base = 16
            i += 2
        } else if (i < n && u(s, i) == '0'.code) {
            base = 8
        } else {
            base = 10
        }
    } else if (base == 16 && hexPrefix(i)) {
        i += 2
    }
    if (base < 2 || base > 36) return IntParse(false, 0, false, -1)
    val start = i
    var v = 0UL
    var ovf = false
    val b = base.toULong()
    val limit = ULong.MAX_VALUE / b
    while (i < n) {
        val d = digitValue(u(s, i))
        if (d >= base) break
        if (!ovf) {
            if (v > limit) {
                ovf = true
            } else {
                val m = v * b
                val r = m + d.toULong()
                if (r < m) ovf = true else v = r
            }
        }
        i++
    }
    if (i == start) return IntParse(false, 0, false, -1)
    return IntParse(neg, v.toLong(), ovf, i)
}

/**
 * C `strtol(s + pos, &end, base)` (64-bit long): out-of-range values are
 * clamped to Long.MIN_VALUE / Long.MAX_VALUE.
 */
fun strtol(s: ByteArray, base: Int = 10, pos: Int = 0): LongEnd {
    val p = strtoInt(s, pos, base)
    if (p.end < 0) return LongEnd(0, pos)
    val v = p.mag.toULong()
    val value = if (p.neg) {
        if (p.ovf || v > (1UL shl 63)) Long.MIN_VALUE else -(v.toLong())
    } else if (p.ovf || v > Long.MAX_VALUE.toULong()) {
        Long.MAX_VALUE
    } else {
        v.toLong()
    }
    return LongEnd(value, p.end)
}

/** C `strtol` on a string (one byte per character). */
fun strtol(s: String, base: Int = 10): LongEnd = strtol(s.latin1(), base, 0)

/** C `strtoll` (same as [strtol] on the reference platform). */
fun strtoll(s: ByteArray, base: Int = 10, pos: Int = 0): LongEnd = strtol(s, base, pos)

/**
 * C `strtoul(s + pos, &end, base)` (64-bit unsigned long, returned as the
 * bits of a Long): negative values wrap, out-of-range values give all ones.
 */
fun strtoul(s: ByteArray, base: Int = 10, pos: Int = 0): LongEnd {
    val p = strtoInt(s, pos, base)
    if (p.end < 0) return LongEnd(0, pos)
    if (p.ovf) return LongEnd(-1L, p.end)
    return LongEnd(if (p.neg) -p.mag else p.mag, p.end)
}

/** C `atoi`: `(int) strtol(s, NULL, 10)` (the long result truncated to 32 bits, as glibc does). */
fun atoi(s: ByteArray, pos: Int = 0): Int = strtol(s, 10, pos).value.toInt()

/** C `atoi` on a string. */
fun atoi(s: String): Int = atoi(s.latin1())

/** C `atol`: `strtol(s, NULL, 10)`. */
fun atol(s: ByteArray, pos: Int = 0): Long = strtol(s, 10, pos).value

/** C `atol` on a string. */
fun atol(s: String): Long = atol(s.latin1())

/** C `atof`: `strtod(s, NULL)`. */
fun atof(s: ByteArray, pos: Int = 0): Double = strtod(s, pos).value

/** C `atof` on a string. */
fun atof(s: String): Double = atof(s.latin1())

private const val EMIN = -1022
private const val EMAX = 1023
private const val ETINY = -1074
private const val PRECISION = 53L

private fun matchCi(s: ByteArray, n: Int, i: Int, word: String): Boolean {
    if (n < i + word.length) return false
    for (k in word.indices) if (lower(u(s, i + k)) != word[k].code) return false
    return true
}

/** 2^n for ETINY <= n <= EMAX. */
private fun pow2(n: Int): Double =
    if (n >= EMIN) Double.fromBits((n + EMAX).toLong() shl 52) else Double.fromBits(1L shl (n - ETINY))

/** x * 2^n, exact when the result is representable. */
private fun ldexp(x: Double, n: Int): Double = when {
    n < EMIN -> x * pow2(EMIN) * pow2(n - EMIN)
    n > EMAX -> x * pow2(EMAX) * pow2(n - EMAX)
    else -> x * pow2(n)
}

/** Correctly rounded value of a hexadecimal significand times 2^exp2 (sticky: nonzero digits were dropped). */
private fun hexValue(mant: Long, sticky: Boolean, exp2: Long): Double {
    if (mant == 0L) return 0.0
    val lz = mant.countLeadingZeroBits()
    val m = mant shl lz // bit 63 set
    val e = exp2 - lz + 63 // value = 1.xxx * 2^e
    if (e > EMAX) return Double.POSITIVE_INFINITY
    val keep: Long = if (e >= EMIN) PRECISION else PRECISION - (EMIN - e)
    if (keep <= 0) {
        if (keep == 0L) {
            val half = m == Long.MIN_VALUE && !sticky
            return if (half) 0.0 else pow2(ETINY)
        }
        return 0.0
    }
    val shift = (64 - keep).toInt()
    var kept = m ushr shift
    val dropped = m and ((1L shl shift) - 1)
    val half = 1L shl (shift - 1)
    if (dropped > half || (dropped == half && (sticky || (kept and 1L) == 1L))) kept += 1
    return ldexp(kept.toDouble(), (e - keep + 1).toInt())
}

/**
 * C `strtod(s + pos, &end)` as glibc implements it (correctly rounded
 * decimal and hexadecimal input, inf, infinity, nan, nan(...)).
 */
fun strtod(s: ByteArray, pos: Int = 0): DoubleEnd {
    val n = cend(s)
    var i = pos
    while (i < n && isspace(u(s, i))) i++
    var neg = false
    if (i < n && (u(s, i) == '+'.code || u(s, i) == '-'.code)) {
        neg = u(s, i) == '-'.code
        i++
    }
    fun sign(v: Double) = if (neg) -v else v
    // Hexadecimal
    if (i + 1 < n && u(s, i) == '0'.code && lower(u(s, i + 1)) == 'x'.code) {
        val j = i + 2
        val hasDigits = (j < n && isxdigit(u(s, j))) || (j + 1 < n && u(s, j) == '.'.code && isxdigit(u(s, j + 1)))
        if (hasDigits) {
            val r = parseHex(s, n, j)
            return DoubleEnd(sign(r.value), r.end)
        }
        return DoubleEnd(sign(0.0), i + 1) // "0x" alone: the "0" is the number
    }
    // Decimal
    val start = i
    var j = i
    var ndig = 0
    while (j < n && isdigit(u(s, j))) {
        j++
        ndig++
    }
    if (j < n && u(s, j) == '.'.code) {
        j++
        while (j < n && isdigit(u(s, j))) {
            j++
            ndig++
        }
    }
    if (ndig > 0) {
        val mantEnd = j
        if (j < n && lower(u(s, j)) == 'e'.code) {
            var k = j + 1
            if (k < n && (u(s, k) == '+'.code || u(s, k) == '-'.code)) k++
            if (k < n && isdigit(u(s, k))) {
                while (k < n && isdigit(u(s, k))) k++
                j = k
            }
        }
        val v = parseDecimal(s, start, mantEnd, j)
        return DoubleEnd(sign(v), j)
    }
    if (matchCi(s, n, i, "inf")) {
        val end = if (matchCi(s, n, i, "infinity")) i + 8 else i + 3
        return DoubleEnd(sign(Double.POSITIVE_INFINITY), end)
    }
    if (matchCi(s, n, i, "nan")) {
        var end = i + 3
        if (end < n && u(s, end) == '('.code) {
            var k = end + 1
            while (k < n && (isalnum(u(s, k)) || u(s, k) == '_'.code)) k++
            if (k < n && u(s, k) == ')'.code) end = k + 1
        }
        return DoubleEnd(sign(Double.NaN), end)
    }
    return DoubleEnd(0.0, pos)
}

/** C `strtod` on a string. */
fun strtod(s: String): DoubleEnd = strtod(s.latin1(), 0)

/**
 * Correctly rounded value of a decimal mantissa s[start until mantEnd]
 * (digits and an optional point) and exponent part s[mantEnd until end]
 * (`e[+-]digits`, or empty).
 */
private fun parseDecimal(s: ByteArray, start: Int, mantEnd: Int, end: Int): Double {
    // Kotlin's String.toDouble is correctly rounded (as glibc's strtod).
    // Very long exponents are clamped first (the result is then 0 or
    // infinity, or determined by the clamped exponent).
    val sb = StringBuilder(mantEnd - start + 24)
    for (k in start until mantEnd) sb.append(u(s, k).toChar())
    if (sb[0] == '.') sb.insert(0, '0')
    if (sb[sb.length - 1] == '.') sb.append('0')
    if (end > mantEnd) {
        var k = mantEnd + 1
        var eneg = false
        if (u(s, k) == '-'.code) {
            eneg = true
            k++
        } else if (u(s, k) == '+'.code) {
            k++
        }
        var e = 0L
        while (k < end) {
            e = minOf(e * 10 + (u(s, k) - '0'.code), 1_000_000_000_000L)
            k++
        }
        val bound = 100_000L + (mantEnd - start)
        if (e > bound) e = bound
        sb.append('e')
        if (eneg) sb.append('-')
        sb.append(e)
    }
    return sb.toString().toDoubleOrNull() ?: 0.0
}

private fun parseHex(s: ByteArray, n: Int, j0: Int): DoubleEnd {
    var j = j0
    var mant = 0L
    var sticky = false
    var exp2 = 0L
    var seenPoint = false
    while (true) {
        if (j < n && isxdigit(u(s, j))) {
            val d = digitValue(u(s, j)).toLong()
            if ((mant ushr 60) == 0L) {
                mant = (mant shl 4) or d
                if (seenPoint) exp2 -= 4
            } else {
                if (d != 0L) sticky = true
                if (!seenPoint) exp2 += 4
            }
            j++
        } else if (j < n && u(s, j) == '.'.code && !seenPoint) {
            seenPoint = true
            j++
        } else {
            break
        }
    }
    if (j < n && lower(u(s, j)) == 'p'.code) {
        var k = j + 1
        var eneg = false
        if (k < n && (u(s, k) == '+'.code || u(s, k) == '-'.code)) {
            eneg = u(s, k) == '-'.code
            k++
        }
        if (k < n && isdigit(u(s, k))) {
            var e = 0L
            while (k < n && isdigit(u(s, k))) {
                e = minOf(e * 10 + (u(s, k) - '0'.code), 1_000_000_000L)
                k++
            }
            exp2 += if (eneg) -e else e
            j = k
        }
    }
    return DoubleEnd(hexValue(mant, sticky, exp2), j)
}

/** The result of [strtof]. */
class FloatEnd(val value: Float, val end: Int)

/** C `strtof`: like [strtod], correctly rounded to Float (decimal input is rounded once, directly to Float, as glibc does). */
fun strtof(s: ByteArray, pos: Int = 0): FloatEnd {
    val r = strtod(s, pos)
    val d = r.value
    if (r.end == pos || d.isNaN() || d.isInfinite() || d == 0.0) return FloatEnd(d.toFloat(), r.end)
    var i = pos
    while (i < r.end && isspace(u(s, i))) i++
    var neg = false
    if (u(s, i) == '-'.code || u(s, i) == '+'.code) {
        neg = u(s, i) == '-'.code
        i++
    }
    if (i + 1 < r.end && lower(u(s, i + 1)) == 'x'.code) return FloatEnd(d.toFloat(), r.end) // hexadecimal: through Double
    val t = StringBuilder()
    for (k in i until r.end) t.append(u(s, k).toChar())
    if (t.isNotEmpty() && t[0] == '.') t.insert(0, '0')
    // (an exponent that toFloat cannot parse falls back to the double)
    val v = try {
        t.toString().toFloat()
    } catch (e: NumberFormatException) {
        return FloatEnd(d.toFloat(), r.end)
    }
    return FloatEnd(if (neg) -v else v, r.end)
}

// ---------------------------------------------------------------------------
// sscanf

/** A destination of an [sscanf] conversion (the C pointer argument). */
sealed class ScanDest {
    internal open fun storeInt(v: Long) {}
    internal open fun storeFloat(text: ByteArray) {}
    internal open fun storeBytes(v: ByteArray) {}
}

/** `int *` (integer conversions store the value truncated to 32 bits; %c stores the byte value). */
class CInt(var v: Int = 0) : ScanDest() {
    override fun storeInt(v: Long) {
        this.v = v.toInt()
    }

    override fun storeBytes(v: ByteArray) {
        if (v.isNotEmpty()) this.v = (this.v and 0xff.inv()) or (v[0].toInt() and 0xff)
    }
}

/** `long *`. */
class CLong(var v: Long = 0) : ScanDest() {
    override fun storeInt(v: Long) {
        this.v = v
    }
}

/** `short *` (`%hd`). */
class CShort(var v: Short = 0) : ScanDest() {
    override fun storeInt(v: Long) {
        this.v = v.toShort()
    }
}

/** `double *`. */
class CDouble(var v: Double = 0.0) : ScanDest() {
    override fun storeInt(v: Long) {
        this.v = v.toDouble()
    }

    override fun storeFloat(text: ByteArray) {
        this.v = strtod(text).value
    }
}

/** `float *`. */
class CFloat(var v: Float = 0f) : ScanDest() {
    override fun storeInt(v: Long) {
        this.v = v.toFloat()
    }

    override fun storeFloat(text: ByteArray) {
        this.v = strtof(text).value
    }
}

/** `char *` buffer (`%s`, `%[...]`, `%Nc`): its contents are replaced. */
class CBytes(var v: ByteArray = ByteArray(0)) : ScanDest() {
    override fun storeBytes(v: ByteArray) {
        this.v = v
    }
}

/** `char *` (a single `%c`), as an unsigned byte value 0..255. */
class CChar(var v: Int = 0) : ScanDest() {
    override fun storeInt(v: Long) {
        this.v = v.toInt() and 0xff
    }

    override fun storeBytes(v: ByteArray) {
        if (v.isNotEmpty()) this.v = v[0].toInt() and 0xff
    }
}

private class IntScan(val v: Long, val used: Int)

/** Scan an integer as glibc's scanf does (base 0 for %i); null on a matching failure. */
private fun scanInt(s: ByteArray, from: Int, lim: Int, base0: Int, unsigned: Boolean): IntScan? {
    var i = from
    val text = ByteVec(24)
    if (i < lim && (u(s, i) == '+'.code || u(s, i) == '-'.code)) {
        text.add(s[i])
        i++
    }
    var base = base0
    var gotDigit = false
    if ((base == 0 || base == 16) && i < lim && u(s, i) == '0'.code) {
        text.add('0'.code)
        i++
        gotDigit = true
        if (i < lim && lower(u(s, i)) == 'x'.code) {
            i++
            base = 16
        } else if (base == 0) {
            base = 8
        }
    }
    if (base == 0) base = 10
    while (i < lim && digitValue(u(s, i)) < base) {
        text.add(s[i])
        i++
        gotDigit = true
    }
    if (!gotDigit) return null
    val t = text.toByteArray()
    val v = if (unsigned) strtoul(t, base).value else strtol(t, base).value
    return IntScan(v, i - from)
}

/** Scan a floating-point number as glibc's scanf does; returns the length of its text, or -1. */
private fun scanFloat(s: ByteArray, from: Int, lim: Int, widthEnd: Boolean): Int {
    var i = from
    if (i < lim && (u(s, i) == '+'.code || u(s, i) == '-'.code)) i++
    if (matchCi(s, lim, i, "nan")) return i + 3 - from
    if (i < lim && lower(u(s, i)) == 'i'.code) {
        if (!matchCi(s, lim, i, "inf")) return -1
        // scanf commits to "infinity" once its fourth letter is read.
        i += 3
        if (i < lim && lower(u(s, i)) == 'i'.code) {
            if (!matchCi(s, lim, i, "inity")) return -1
            i += 5
        }
        return i - from
    }
    var hex = false
    var ndig = 0
    if (i + 1 < lim && u(s, i) == '0'.code && lower(u(s, i + 1)) == 'x'.code) {
        if (widthEnd && i + 2 == lim) return i + 1 - from // the width ends at the 'x': the number is "0"
        hex = true
        i += 2
    }
    fun isdig(c: Int) = if (hex) isxdigit(c) else isdigit(c)
    while (i < lim && isdig(u(s, i))) {
        i++
        ndig++
    }
    if (i < lim && u(s, i) == '.'.code) {
        i++
        if (hex) ndig++ // "0x." is accepted (as 0), "0x" alone is not
        while (i < lim && isdig(u(s, i))) {
            i++
            ndig++
        }
    }
    if (ndig == 0) return -1
    val expc = if (hex) 'p'.code else 'e'.code
    if (i < lim && lower(u(s, i)) == expc) {
        i++
        if (i < lim && (u(s, i) == '+'.code || u(s, i) == '-'.code)) i++
        while (i < lim && isdigit(u(s, i))) i++
    }
    return i - from
}

/**
 * Parse the scan set of a %[ conversion whose body starts at fmt[f0] (just
 * after the '['), as glibc's vfscanf does. Returns the membership table
 * and sets next[0] to the format position after the closing ']', or
 * returns null if the set has no closing ']'.
 */
private fun parseScanset(fmt: ByteArray, f0: Int, next: IntArray): BooleanArray? {
    fun at(k: Int) = fmt.at(k)
    var f = f0
    val set = BooleanArray(256)
    val negate = at(f) == '^'.code
    if (negate) f++
    if (at(f) == ']'.code || at(f) == '-'.code) {
        set[at(f)] = true
        f++
    }
    while (true) {
        val c = at(f)
        f++
        if (c == 0) return null
        if (c == ']'.code) break
        if (c == '-'.code && at(f) != 0 && at(f) != ']'.code && at(f - 2) <= at(f)) {
            // A range lo-hi (lo was already added; hi is added by the next iteration).
            for (m in at(f - 2) until at(f)) set[m] = true
        } else {
            set[c] = true
        }
    }
    if (negate) for (m in set.indices) set[m] = !set[m]
    next[0] = f
    return set
}

/**
 * C `sscanf(input, fmt, ...)` with glibc's semantics.
 *
 * Returns the number of assigned conversions, or -1 (EOF) if the input
 * ended before the first assignment. Destinations of conversions that were
 * not reached are left unchanged (C programs rely on such stale values).
 * Supports %d %i %u %x %X %o %e %f %g %E %G %a %s %c %[...] %n %%,
 * assignment suppression (*), field widths, and the length modifiers (which
 * are ignored: the [ScanDest] class gives the destination type).
 */
fun sscanf(input: ByteArray, fmt: ByteArray, vararg args: ScanDest): Int {
    val n = cend(input)
    var i = 0
    var f = 0
    var ai = 0
    var done = 0
    val fl = cend(fmt)
    while (f < fl) {
        val c = u(fmt, f)
        if (isspace(c)) {
            while (f < fl && isspace(u(fmt, f))) f++
            while (i < n && isspace(u(input, i))) i++
            continue
        }
        if (c != '%'.code) {
            if (i >= n) return if (done == 0) -1 else done
            if (u(input, i) != c) return done
            i++
            f++
            continue
        }
        f++
        var suppress = false
        if (f < fl && u(fmt, f) == '*'.code) {
            suppress = true
            f++
        }
        var width = 0
        while (f < fl && isdigit(u(fmt, f))) {
            width = width * 10 + (u(fmt, f) - '0'.code)
            f++
        }
        while (f < fl && u(fmt, f).toChar() in "hlLqjzt") f++
        if (f >= fl) return done
        val conv = u(fmt, f).toChar()
        f++
        if (conv == '%') {
            while (i < n && isspace(u(input, i))) i++
            if (i >= n) return if (done == 0) -1 else done
            if (u(input, i) != '%'.code) return done
            i++
            continue
        }
        if (conv == 'n') {
            if (!suppress) {
                args.getOrNull(ai)?.storeInt(i.toLong())
                ai++
            }
            continue
        }
        if (conv != 'c' && conv != '[') while (i < n && isspace(u(input, i))) i++
        // glibc parses a scan set before reading the input.
        var scanset: BooleanArray? = null
        if (conv == '[') {
            val next = IntArray(1)
            scanset = parseScanset(fmt, f, next) ?: return done
            f = next[0]
        }
        if (i >= n) return if (done == 0) -1 else done
        val lim = if (width > 0) minOf(i + width, n) else n
        when (conv) {
            'd', 'i', 'u', 'x', 'X', 'o' -> {
                val base = when (conv) {
                    'd', 'u' -> 10
                    'i' -> 0
                    'o' -> 8
                    else -> 16
                }
                val r = scanInt(input, i, lim, base, !(conv == 'd' || conv == 'i')) ?: return done
                i += r.used
                if (!suppress) {
                    args.getOrNull(ai)?.storeInt(r.v)
                    ai++
                    done++
                }
            }
            'e', 'E', 'f', 'F', 'g', 'G', 'a', 'A' -> {
                val used = scanFloat(input, i, lim, width > 0 && i + width <= n)
                if (used < 0) return done
                if (!suppress) {
                    args.getOrNull(ai)?.storeFloat(input.copyOfRange(i, i + used))
                    ai++
                    done++
                }
                i += used
            }
            's' -> {
                var j = i
                while (j < lim && !isspace(u(input, j))) j++
                if (!suppress) {
                    args.getOrNull(ai)?.storeBytes(input.copyOfRange(i, j))
                    ai++
                    done++
                }
                i = j
            }
            'c' -> {
                val w = if (width > 0) width else 1
                val take = minOf(w, n - i)
                if (!suppress) {
                    args.getOrNull(ai)?.storeBytes(input.copyOfRange(i, i + take))
                    ai++
                    done++
                }
                i += take
            }
            '[' -> {
                val set = scanset!!
                var j = i
                while (j < lim && set[u(input, j)]) j++
                if (j == i) return done
                if (!suppress) {
                    args.getOrNull(ai)?.storeBytes(input.copyOfRange(i, j))
                    ai++
                    done++
                }
                i = j
            }
            else -> return done
        }
    }
    return done
}

/** [sscanf] with a format given as a string. */
fun sscanf(input: ByteArray, fmt: String, vararg args: ScanDest): Int = sscanf(input, fmt.latin1(), *args)

/** [sscanf] with input and format given as strings. */
fun sscanf(input: String, fmt: String, vararg args: ScanDest): Int = sscanf(input.latin1(), fmt.latin1(), *args)

// ---------------------------------------------------------------------------
// strtok

/**
 * The C `strtok` function over one string.
 *
 * `Strtok(s)` followed by `next(delims)` corresponds to `strtok(s,
 * delims)`; each further `next(delims)` corresponds to `strtok(NULL,
 * delims)`. Tokens are returned as copies (C writes a NUL over the
 * delimiter that ends each token; callers that depend on that modification
 * must reproduce it themselves). [start] and [end] give the location of the
 * last token returned.
 */
class Strtok(s: ByteArray) {
    private val s: ByteArray = s
    private val n: Int = cend(s)
    private var pos: Int = 0 // -1: exhausted

    /** Start of the last token returned (in the string). */
    var start: Int = -1
        private set

    /** End (exclusive) of the last token returned. */
    var end: Int = -1
        private set

    /** The next token, or null (C's NULL). */
    fun next(delims: ByteArray): ByteArray? {
        if (pos < 0) return null
        var i = pos
        while (i < n && delims.contains(s[i])) i++
        if (i >= n) {
            pos = -1
            return null
        }
        var j = i
        while (j < n && !delims.contains(s[j])) j++
        pos = if (j < n) j + 1 else -1
        start = i
        end = j
        return s.copyOfRange(i, j)
    }

    /** The next token, delimiters given as a string. */
    fun next(delims: String): ByteArray? = next(delims.latin1())

    /** The position where the next call will start, or -1 if the string is exhausted. */
    fun position(): Int = pos

    /** The rest of the string from the current position (empty if exhausted). */
    fun rest(): ByteArray = if (pos in 0..n) s.copyOfRange(pos, n) else ByteArray(0)
}

// ---------------------------------------------------------------------------
// fgets

/**
 * Splits [data] into the successive results of `fgets(buf, size, fp)`:
 * pieces of at most `size - 1` bytes, each ending with a newline unless the
 * line was longer or the input ended.
 */
fun fgetsLines(data: ByteArray, size: Int): List<ByteArray> {
    val lim = maxOf(size - 1, 1)
    val r = ArrayList<ByteArray>()
    var i = 0
    val n = data.size
    while (i < n) {
        val end = minOf(i + lim, n)
        var j = end
        for (k in i until end) if (data[k] == '\n'.code.toByte()) {
            j = k + 1
            break
        }
        r.add(data.copyOfRange(i, j))
        i = j
    }
    return r
}
