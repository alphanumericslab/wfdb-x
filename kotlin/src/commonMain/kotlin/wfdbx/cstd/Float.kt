// Exact binary-to-decimal conversion of doubles, as used by glibc's printf
// for %e, %f and %g (port of rust/src/cstd/float.rs).
//
// glibc formats a double from its exact binary value, rounding to the
// requested number of digits with round-half-even on the exact value. This
// file does the same: the exact decimal expansion of the value is computed
// (with Long arithmetic when it fits, otherwise with a small big-integer
// type) and rounded. [fixedFast] is an exact fast path for "%W.Pf" with
// P <= 9, used by the tools that print many samples.
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

/** Digits `k` (ASCII) with value `0.k * 10^point` (fixed) or `k[0].k[1..] * 10^point` (exponential). */
internal class Digits(val k: ByteArray, val point: Int, val carried: Boolean = false)

private const val FRAC_BITS = 52
private const val EXP_OFFSET = 1023 + FRAC_BITS

/** `|x| == m * 2^e` exactly, with `m < 2^53` (finite x). */
private fun rawM(x: Double): Long {
    val bits = x.toRawBits()
    val bexp = ((bits ushr FRAC_BITS) and 0x7ff).toInt()
    val frac = bits and ((1L shl FRAC_BITS) - 1)
    return if (bexp == 0) frac else frac or (1L shl FRAC_BITS)
}

private fun rawE(x: Double): Int {
    val bexp = ((x.toRawBits() ushr FRAC_BITS) and 0x7ff).toInt()
    return if (bexp == 0) 1 - EXP_OFFSET else bexp - EXP_OFFSET
}

private val POW5_LONG: LongArray = LongArray(28).also {
    it[0] = 1
    for (i in 1 until it.size) it[i] = it[i - 1] * 5
}

private val POW10_LONG: LongArray = LongArray(19).also {
    it[0] = 1
    for (i in 1 until it.size) it[i] = it[i - 1] * 10
}

/** Decimal digits (ASCII) of a positive Long. */
private fun longDigits(v: Long): ByteArray {
    if (v == 0L) return ByteArray(0)
    return v.toString().latin1()
}

/** A minimal unsigned big integer: little-endian 32-bit limbs held in a LongArray. */
private class Big(m: Long) {
    var limbs = LongArray(8)
    var n = 0

    init {
        var v = m
        while (v != 0L) {
            push(v and 0xffffffffL)
            v = v ushr 32
        }
    }

    fun push(v: Long) {
        if (n == limbs.size) limbs = limbs.copyOf(n * 2)
        limbs[n++] = v
    }

    fun mulSmall(f: Long) {
        var carry = 0L
        for (i in 0 until n) {
            val v = limbs[i] * f + carry // limbs < 2^32, f < 2^31: no overflow
            limbs[i] = v and 0xffffffffL
            carry = v ushr 32
        }
        if (carry != 0L) push(carry)
    }

    fun shl(bits: Int) {
        val words = bits / 32
        val b = bits % 32
        if (b != 0) {
            var carry = 0L
            for (i in 0 until n) {
                val v = limbs[i]
                limbs[i] = ((v shl b) and 0xffffffffL) or carry
                carry = v ushr (32 - b)
            }
            if (carry != 0L) push(carry)
        }
        if (words > 0) {
            val r = LongArray(n + words + 1)
            limbs.copyInto(r, words, 0, n)
            limbs = r
            n += words
        }
    }

    /** Decimal digits, without leading zeros (empty for 0). */
    fun toDecimal(): ByteArray {
        val chunk = 1_000_000_000L
        val l = limbs.copyOf(n)
        var len = n
        val chunks = ArrayList<Long>()
        while (len > 0) {
            var rem = 0L
            for (i in len - 1 downTo 0) {
                val v = (rem shl 32) or l[i]
                l[i] = v / chunk
                rem = v % chunk
            }
            chunks.add(rem)
            while (len > 0 && l[len - 1] == 0L) len--
        }
        val out = ByteVec(chunks.size * 9)
        for (i in chunks.indices.reversed()) {
            val s = chunks[i].toString()
            if (i != chunks.size - 1) out.fill('0'.code, 9 - s.length)
            out.addString(s)
        }
        val r = out.toByteArray()
        return if (r.size == 1 && r[0] == '0'.code.toByte()) ByteArray(0) else r
    }
}

/** The exact decimal expansion of `m * 2^e` (m > 0): digits and point, value `0.d * 10^point`. */
private fun exactDigits(m0: Long, e0: Int): Digits {
    // Remove trailing zero bits (m odd), so that the Long fast paths apply more often.
    val tz = m0.countTrailingZeroBits()
    val m = m0 ushr tz
    val e = e0 + tz
    if (e >= 0) {
        if (e <= 62 - (64 - m.countLeadingZeroBits())) {
            val d = longDigits(m shl e)
            return Digits(d, d.size)
        }
        val b = Big(m)
        b.shl(e)
        val d = b.toDecimal()
        return Digits(d, d.size)
    }
    val k = -e
    // m * 5^k / 10^k
    if (k < POW5_LONG.size && m <= Long.MAX_VALUE / POW5_LONG[k]) {
        val d = longDigits(m * POW5_LONG[k])
        return Digits(d, d.size - k)
    }
    val b = Big(m)
    var i = k
    while (i >= 13) {
        b.mulSmall(1_220_703_125L) // 5^13
        i -= 13
    }
    if (i > 0) b.mulSmall(POW5_LONG[i])
    val d = b.toDecimal()
    return Digits(d, d.size - k)
}

/**
 * Round the digits [d] (value `0.d * 10^point`) to [n] digits, ties to even.
 * Returns the kept digits and the new point.
 */
private fun roundDigits(d: ByteArray, point: Int, n: Long): Digits {
    val len = d.size.toLong()
    if (n >= len) {
        val k = d.copyOf((n).toInt())
        for (i in d.size until k.size) k[i] = '0'.code.toByte()
        return Digits(k, point)
    }
    if (n < 0) return Digits(ByteArray(0), point)
    val ni = n.toInt()
    val kept = d.copyOf(ni)
    val first = d[ni].toInt()
    var restNonzero = false
    for (i in ni + 1 until d.size) if (d[i] != '0'.code.toByte()) {
        restNonzero = true
        break
    }
    val lastOdd = ni > 0 && ((kept[ni - 1] - '0'.code.toByte()) and 1) == 1
    val up = first > '5'.code || (first == '5'.code && (restNonzero || lastOdd))
    if (!up) return Digits(kept, point)
    var i = ni
    while (i > 0) {
        i--
        if (kept[i] == '9'.code.toByte()) {
            kept[i] = '0'.code.toByte()
        } else {
            kept[i] = (kept[i] + 1).toByte()
            return Digits(kept, point)
        }
    }
    // All nines (or n == 0): the result is 10^point.
    val r = ByteArray(if (ni > 0) ni else 1)
    r[0] = '1'.code.toByte()
    for (j in 1 until r.size) r[j] = '0'.code.toByte()
    return Digits(r, point + 1)
}

/**
 * Digits of |x| rounded to [prec] digits after the point (%f): value
 * `0.k * 10^point`, where k holds all the digits down to the 10^-prec
 * position (k is empty if the rounded value is zero). x must be finite.
 */
internal fun digitsFixed(x: Double, prec: Int): Digits {
    if (x == 0.0) return Digits(ByteArray(0), 0)
    val ex = exactDigits(rawM(x), rawE(x))
    val n = ex.point.toLong() + prec
    val r = roundDigits(ex.k, ex.point, n)
    var allZero = true
    for (c in r.k) if (c != '0'.code.toByte()) {
        allZero = false
        break
    }
    if (allZero) return Digits(ByteArray(0), 0)
    val want = r.point.toLong() + prec
    if (r.k.size < want) {
        val k = r.k.copyOf(want.toInt())
        for (i in r.k.size until k.size) k[i] = '0'.code.toByte()
        return Digits(k, r.point)
    }
    return r
}

/**
 * Digits of |x| rounded to [nsig] >= 1 significant digits (%e): `k.size ==
 * nsig`, value `k[0].k[1..] * 10^point`; `carried` tells whether rounding
 * carried into a new decimal exponent. For zero, k is all zeros and the
 * exponent 0. x must be finite.
 */
internal fun digitsExp(x: Double, nsig: Int): Digits {
    if (x == 0.0) {
        val k = ByteArray(nsig) { '0'.code.toByte() }
        return Digits(k, 0, false)
    }
    val ex = exactDigits(rawM(x), rawE(x))
    val r = roundDigits(ex.k, ex.point, nsig.toLong())
    return Digits(r.k, r.point - 1, r.point != ex.point)
}

/**
 * Appends `printf("%<width>.<prec>f", x)` to [buf] if x is in the range of
 * this fast path (finite, prec <= 9, and |x| * 10^prec below 2^63): the
 * result is glibc's (the exact binary value correctly rounded, halfway
 * cases to even). Returns false, appending nothing, otherwise (use
 * [sprintf] then).
 */
fun fixedFast(buf: ByteVec, x: Double, width: Int, prec: Int): Boolean {
    if (x.isNaN() || x.isInfinite() || prec < 0 || prec > 9) return false
    val neg = (x.toRawBits() ushr 63) != 0L
    val m = rawM(x)
    val e = rawE(x)
    val p10 = POW10_LONG[prec]
    var q: Long
    if (e >= 0) {
        if (e > 40) return false
        val bitsM = 64 - m.countLeadingZeroBits()
        if (bitsM + e > 62) return false
        val v = m shl e
        if (v > Long.MAX_VALUE / p10) return false
        q = v * p10
    } else {
        val k = -e
        // n = m * p10 (< 2^83) as a 128-bit value hi:lo (unsigned)
        val mh = m ushr 32
        val ml = m and 0xffffffffL
        val a = mh * p10 // < 2^51
        val b = ml * p10 // < 2^62
        var lo = (a shl 32) + b
        val carry = if (ulongLess(lo, b)) 1L else 0L
        val hi = (a ushr 32) + carry
        if (k >= 120) {
            q = 0
        } else {
            // q = n >> k; rem = n & (2^k - 1); half = 2^(k - 1)
            val qhi: Long
            val qlo: Long
            if (k >= 64) {
                qhi = 0
                qlo = hi ushr (k - 64)
            } else {
                qhi = hi ushr k
                qlo = (lo ushr k) or (if (k == 0) 0 else hi shl (64 - k))
            }
            if (qhi != 0L || qlo < 0) return false
            q = qlo
            // Compare the remainder with half.
            val cmp: Int // <0 below, 0 half, >0 above
            if (k > 64) {
                val rh = hi and ((1L shl (k - 64)) - 1)
                val halfH = 1L shl (k - 65)
                cmp = if (rh != halfH) (if (ulongLess(rh, halfH)) -1 else 1)
                else (if (lo == 0L) 0 else 1)
            } else if (k == 64) {
                cmp = ulongCompare(lo, Long.MIN_VALUE)
            } else {
                val rl = lo and ((1L shl k) - 1)
                val half = 1L shl (k - 1)
                cmp = ulongCompare(rl, half)
            }
            lo = 0
            if (cmp > 0 || (cmp == 0 && (q and 1L) == 1L)) q += 1
        }
    }
    // Digits, least significant first.
    val tmp = ByteArray(20 + 2 + 9)
    var n = 0
    val p = prec
    while (true) {
        tmp[n++] = ('0'.code + (q % 10).toInt()).toByte()
        q /= 10
        if (n == p) tmp[n++] = '.'.code.toByte()
        if (q == 0L && n > p + (if (p > 0) 1 else 0)) break
    }
    if (neg) tmp[n++] = '-'.code.toByte()
    if (width > n) buf.fill(' '.code, width - n)
    for (i in n - 1 downTo 0) buf.add(tmp[i])
    return true
}

private fun ulongLess(a: Long, b: Long): Boolean = (a xor Long.MIN_VALUE) < (b xor Long.MIN_VALUE)

private fun ulongCompare(a: Long, b: Long): Int = (a xor Long.MIN_VALUE).compareTo(b xor Long.MIN_VALUE)
