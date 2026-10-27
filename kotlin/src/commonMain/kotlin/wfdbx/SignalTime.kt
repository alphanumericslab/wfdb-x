// Time, date and amplitude conversions of lib/signal.c (strtim, timstr,
// mstimstr, datstr, strdat, setbasetime, counter frequency and base count,
// adumuv, muvadu, aduphys, physadu), part of the port of signal.c (see
// Signal.kt; through rust/src/signal.rs).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of lib/signal.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency or gain: times
// that need a sampling frequency are not converted when none is specified (the
// original used 1 sample per second, or 250 Hz for a header without a
// frequency), and the amplitudes of uncalibrated signals are not converted
// (the original assumed 200 adu per physical unit); additions:
// wfdbx_time_needs_freq; legacy mode (wfdbx_set_legacy) restores the original
// behavior. Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md
// gives the reasons.
//
// Original C code: lib/signal.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by
//   Benjamin Moody, including FLAC support (2020).
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

import wfdbx.cstd.Platform
import wfdbx.cstd.Strtok
import wfdbx.cstd.cformat
import wfdbx.cstd.cstr
import wfdbx.cstd.d2i
import wfdbx.cstd.d2l
import wfdbx.cstd.getenv
import wfdbx.cstd.latin1
import wfdbx.cstd.strtod
import wfdbx.cstd.strtol

/** Lengths of C's static date_string and time_string buffers (without the terminating NUL), to which C truncates the strings it formats. */
private const val DATE_STRING_LEN = 36
private const val TIME_STRING_LEN = 61

private fun truncated(b: ByteArray, n: Int): ByteArray = if (b.size > n) b.copyOf(n) else b

// ---------------------------------------------------------------------------
// The local time

/**
 * The current local time as (year, month 1-12, day, hour, minute, second)
 * (C `localtime(time(NULL))`). The time zone is read from the TZif file
 * named by TZ (or /etc/localtime); UTC is used if there is none.
 */
internal fun localTimeNow(): LongArray {
    val now = Platform.timeNow()
    val secsPerDay = 24L * 3600
    val t = now + tzOffset(now)
    val days = FloorMath.floorDiv(t, secsPerDay)
    val secs = FloorMath.floorMod(t, secsPerDay)
    // Civil date from days since 1970-01-01 (H. Hinnant's algorithm).
    val z = days + 719468
    val era = FloorMath.floorDiv(z, 146097L)
    val doe = z - era * 146097
    val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    var y = yoe + era * 400
    val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    val mp = (5 * doy + 2) / 153
    val d = doy - (153 * mp + 2) / 5 + 1
    val m = if (mp < 10) mp + 3 else mp - 9
    if (m <= 2) y += 1
    return longArrayOf(y, m, d, secs / 3600, secs % 3600 / 60, secs % 60)
}

/** floorDiv and floorMod (common code). */
private object FloorMath {
    fun floorDiv(a: Long, b: Long): Long {
        val q = a / b
        return if ((a % b != 0L) && ((a xor b) < 0)) q - 1 else q
    }

    fun floorMod(a: Long, b: Long): Long = a - floorDiv(a, b) * b
}

/** The UTC offset (seconds) of the local time zone at time t, from a TZif file (0 if it cannot be determined). */
private fun tzOffset(t: Long): Long {
    val tz = getenv("TZ")
    val path: ByteArray = if (tz != null && tz.isNotEmpty()) {
        val z = if (tz[0] == ':'.code.toByte()) tz.copyOfRange(1, tz.size) else tz
        if (z.isNotEmpty() && z[0] == '/'.code.toByte()) z else "/usr/share/zoneinfo/".latin1() + z
    } else {
        "/etc/localtime".latin1()
    }
    val data = Platform.readFile(path) ?: return 0
    return tzifOffset(data, t) ?: 0
}

/** The UTC offset at time t given by the TZif data d (RFC 8536). */
private fun tzifOffset(d: ByteArray, t: Long): Long? {
    // The header: magic (4 bytes), version (1), unused (15), then six 32-bit
    // counts (isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt).
    val headerLen = 44
    val countsPos = 20
    // Record sizes: a local time type (32-bit UTC offset, isdst byte,
    // abbreviation index byte); a version 1 leap second record (two 32-bit
    // values); a transition (32-bit time and a type index byte).
    val ttinfoLen = 6
    val ttinfoIsdst = 4
    val leap1Len = 8
    val trans1Len = 5
    fun byte(p: Int): Int? = if (p >= 0 && p < d.size) d[p].toInt() and 0xff else null
    fun be32(p: Int): Long? {
        if (p < 0 || p + 4 > d.size) return null
        var v = 0
        for (i in 0 until 4) v = (v shl 8) or (d[p + i].toInt() and 0xff)
        return v.toLong()
    }
    fun be64(p: Int): Long? {
        if (p < 0 || p + 8 > d.size) return null
        var v = 0L
        for (i in 0 until 8) v = (v shl 8) or (d[p + i].toLong() and 0xff)
        return v
    }
    fun isMagic(p: Int) = p >= 0 && p + 4 <= d.size && d.copyOfRange(p, p + 4).contentEquals("TZif".latin1())
    fun counts(base: Int): IntArray? {
        val c = IntArray(6)
        for (k in 0 until 6) c[k] = (be32(base + countsPos + 4 * k) ?: return null).toInt()
        return c
    }
    if (!isMagic(0)) return null
    val version = byte(4) ?: return null
    var base = 0
    var c = counts(0) ?: return null
    var tsize = 4
    if (version >= '2'.code) {
        // Skip the version 1 data block; use the 64-bit block.
        base = headerLen + c[3] * trans1Len + c[4] * ttinfoLen + c[5] + c[2] * leap1Len + c[1] + c[0]
        if (!isMagic(base)) return null
        c = counts(base) ?: return null
        tsize = 8
    }
    val timecnt = c[3]
    val typecnt = c[4]
    val times = base + headerLen
    val idx = times + timecnt * tsize
    val types = idx + timecnt
    if (typecnt == 0) return null
    var ty = 0
    // The first non-DST type, as the default before the first transition.
    for (k in 0 until typecnt) {
        if ((byte(types + ttinfoLen * k + ttinfoIsdst) ?: return null) == 0) {
            ty = k
            break
        }
    }
    for (k in 0 until timecnt) {
        val tk = (if (tsize == 8) be64(times + k * tsize) else be32(times + k * tsize)) ?: return null
        if (tk <= t) ty = byte(idx + k) ?: return null else break
    }
    return be32(types + ttinfoLen * ty)
}

// ---------------------------------------------------------------------------
// Base time

/**
 * C `setbasetime(string)`: sets the base time and date of the record
 * ("hh:mm:ss dd/mm/yyyy", the date being optional; null or empty: the
 * current local time). Returns 0, or -1 if the string is incorrectly
 * formatted.
 *
 * Translation of the C function setbasetime() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.setbasetime(string: ByteArray?): Int {
    sig.pdays = -1
    val s = if (string == null) ByteArray(0) else cstr(string)
    if (s.isEmpty()) {
        val lt = localTimeNow()
        val ds = cformat("%02d/%02d/%d", lt[2].toInt(), lt[1].toInt(), lt[0].toInt())
        sig.bdate = strdat(ds)
        sig.dateString = ds
        val ts = cformat("%d:%d:%d", lt[3].toInt(), lt[4].toInt(), lt[5].toInt())
        sig.btime = fstrtim(ts, 1000.0)
        return 0
    }
    var k = 0
    while (k < s.size && s[k] == ' '.code.toByte()) k++
    val str = s.copyOfRange(k, s.size)
    val p = str.indexOf(' '.code.toByte())
    val tpart = if (p >= 0) str.copyOf(p) else str
    sig.btime = fstrtim(tpart, 1000.0)
    sig.bdate = if (p >= 0) strdat(str.copyOfRange(p + 1, str.size)) else 0
    if (sig.btime == 0L && sig.bdate == 0L && !(str.isNotEmpty() && str[0] == '['.code.toByte())) {
        wfdb_error(cformat("setbasetime: incorrect time format, '%s'\n", str))
        return -1
    }
    return 0
}

/** [setbasetime] with a string. */
fun Wfdb.setbasetime(string: String): Int = setbasetime(string.latin1())

// ---------------------------------------------------------------------------
// Time strings

/** Convert a sample number to a string, using the given sampling frequency (ftimstr). */
internal fun Wfdb.ftimstr(t: Long, f: Double): ByteArray {
    val ts = fmstimstr(t, f)
    val p = Strtok(ts).next(".") ?: return ByteArray(0)
    if (t <= 0 && (sig.btime != 0L || sig.bdate != 0L)) {
        // time of day
        return p + sig.dateString + byteArrayOf(']'.code.toByte())
    }
    return p
}

/** Convert a sample number to a string with milliseconds, using the given sampling frequency (fmstimstr). */
internal fun Wfdb.fmstimstr(t0: Long, f: Double): ByteArray {
    var t = t0
    val btime = sig.btime
    val bdate = sig.bdate
    if (t > 0 || (btime == 0L && bdate == 0L)) {
        // time interval
        if (t < 0) t = -t
        // Convert from sample intervals to seconds.
        var s = d2l(t / f)
        var msec = d2i((t - s * f) * 1000.0 / f + 0.5)
        if (msec == 1000) {
            msec = 0
            s++
        }
        t = s
        val seconds = (t % 60).toInt()
        t /= 60
        val minutes = (t % 60).toInt()
        val hours = (t / 60).toInt()
        return if (hours > 0) {
            cformat("%2d:%02d:%02d.%03d", hours, minutes, seconds, msec)
        } else {
            cformat("   %2d:%02d.%03d", minutes, seconds, msec)
        }
    }
    // time of day
    // Convert to milliseconds since midnight.
    val tms = btime - (t * 1000.0 / f)
    // Convert to seconds.
    var s = d2l(tms / 1000.0)
    var msec = d2i((tms - s * 1000.0) + 0.5)
    if (msec == 1000) {
        msec = 0
        s++
    }
    t = s
    val seconds = (t % 60).toInt()
    t /= 60
    val minutes = (t % 60).toInt()
    t /= 60
    val hours = (t % 24).toInt()
    val days = t / 24
    if (days != sig.pdays) {
        if (bdate > 0) {
            datstr(days + bdate)
        } else if (days == 0L) {
            sig.dateString = ByteArray(0)
        } else {
            sig.dateString = cformat(" %ld", days)
        }
        sig.pdays = days
    }
    return truncated(cformat("[%02d:%02d:%02d.%03d%s]", hours, minutes, seconds, msec, sig.dateString), TIME_STRING_LEN)
}

/** Convert a string to a sample number, using the given sampling frequency (fstrtim). */
private fun Wfdb.fstrtim(string0: ByteArray, f: Double): Long {
    var string = cstr(string0)
    var k = 0
    while (k < string.size) {
        val c = string[k].toInt()
        if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) k++ else break
    }
    if (k > 0) string = string.copyOfRange(k, string.size)
    val st = sig
    val c0 = if (string.isEmpty()) 0 else string[0].toInt() and 0xff
    when (c0) {
        'c'.code -> return if (st.cfreq > 0.0) {
            d2l((strtod(string, 1).value - st.bcount) * f / st.cfreq)
        } else {
            strtol(string, 10, 1).value
        }
        'e'.code -> {
            val n = if (st.inMsrec != 0) st.msnsamples else st.nsamples
            return n * (if ((st.gvmode and WFDB_HIGHRES) == WFDB_HIGHRES) st.spfmax.toLong() else 1L)
        }
        'f'.code -> return d2l(strtol(string, 10, 1).value * f / st.ffreq)
        'i'.code -> return d2l(
            st.istime * (if (st.ifreq > 0.0) st.ifreq / st.sfreq else 1.0) *
                (if ((st.gvmode and WFDB_HIGHRES) == WFDB_HIGHRES) st.ispfmax.toDouble() else 1.0),
        )
        'o'.code -> return st.ostime
        's'.code -> return strtol(string, 10, 1).value
        '['.code -> {
            // time of day, possibly with date or days since start
            val str = string.copyOfRange(1, string.size)
            val q = strchrAt(str, ']')
            if (q < 0) return 0 // '[...': malformed time string
            val p = strchrAt(str, ' ')
            val days: Long = if (p in 0..q) {
                val r = strchrAt(str, '/', p + 1)
                if (r in 0..q) {
                    // '[hh:mm:ss.sss dd/mm/yyyy]'
                    strdat(str.copyOfRange(p + 1, str.size)) - sig.bdate
                } else {
                    strtol(str, 10, p + 1).value // '[hh:mm:ss.sss d]'
                }
            } else {
                0 // '[hh:mm:ss.sss]': time since midnight only
            }
            var x = (fstrtim(str, 1000.0) - sig.btime).toDouble()
            if (days > 0) x += days * (24.0 * 60.0 * 60.0 * 1000.0)
            val t = d2l(x * f / 1000.0 + 0.5)
            return -t
        }
        else -> {
            val x = strtod(string, 0).value
            val p = strchrAt(string, ':')
            if (p < 0) return d2l(x * f + 0.5)
            val y = strtod(string, p + 1).value
            val p2 = strchrAt(string, ':', p + 1)
            if (p2 < 0) return d2l((60.0 * x + y) * f + 0.5)
            val z = strtod(string, p2 + 1).value
            return d2l((3600.0 * x + 60.0 * y + z) * f + 0.5)
        }
    }
}

/**
 * The frequency used by timstr, mstimstr and strtim, or 0 if none is
 * specified. wfdb-x: no default sampling frequency (C used 1 sample per
 * second, as legacy mode does).
 */
private fun Wfdb.tfreq(): Double = if (sig.ifreq > 0.0) sig.ifreq else if (sig.sfreq > 0.0) sig.sfreq else if (legacy) 1.0 else 0.0

/**
 * wfdb-x: the result of timstr and mstimstr (named func in the error
 * message) when no sampling frequency is specified: the time as a sample
 * number ("s" followed by |t|, a valid strtim argument).
 */
private fun Wfdb.nofreqTimstr(func: String, t: Long): ByteArray {
    wfdb_error(cformat("%s: sampling frequency is not specified\n", func))
    return cformat("s%lld", if (t < 0) -t else t)
}

/**
 * wfdb-x addition (C `wfdbx_time_needs_freq(string)`): whether [strtim]
 * needs a sampling frequency to convert [string]. Returns 0 if string
 * (after leading spaces, tabs, newlines and carriage returns) begins with
 * e, i, o or s, or with c while the counter frequency is not positive; 1
 * otherwise.
 *
 * Part of wfdb-x; not in the original WFDB package.
 */
fun Wfdb.wfdbx_time_needs_freq(string: ByteArray): Int {
    var first = 0
    for (b in string) {
        val c = b.toInt() and 0xff
        if (c != ' '.code && c != '\t'.code && c != '\n'.code && c != '\r'.code) {
            first = c
            break
        }
    }
    return when (first) {
        'e'.code, 'i'.code, 'o'.code, 's'.code -> 0
        'c'.code -> if (sig.cfreq > 0.0) 1 else 0
        else -> 1
    }
}

/** [wfdbx_time_needs_freq] with a string. */
fun Wfdb.wfdbx_time_needs_freq(string: String): Int = wfdbx_time_needs_freq(string.latin1())

/**
 * C `timstr(t)`: a time string ("hh:mm:ss", or "[hh:mm:ss dd/mm/yyyy]" for
 * a time of day: t <= 0 when the base time is defined).
 *
 * wfdb-x: if no sampling frequency is specified, reports an error and
 * returns the time as a sample number ("s" followed by |t|).
 *
 * Translation of the C function timstr() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: if the sampling frequency is not
 * specified, it reports an error and returns the time as a sample number (the
 * original assumed 1 sample per second); see docs/DIVERGENCES.md.
 */
fun Wfdb.timstr(t: Long): ByteArray {
    val f = tfreq()
    if (f <= 0.0) return nofreqTimstr("timstr", t)
    return ftimstr(t, f)
}

/**
 * C `mstimstr(t)`: as timstr, with milliseconds.
 *
 * wfdb-x: if no sampling frequency is specified, reports an error and
 * returns the time as a sample number ("s" followed by |t|).
 *
 * Translation of the C function mstimstr() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: if the sampling frequency is not
 * specified, it reports an error and returns the time as a sample number (the
 * original assumed 1 sample per second); see docs/DIVERGENCES.md.
 */
fun Wfdb.mstimstr(t: Long): ByteArray {
    val f = tfreq()
    if (f <= 0.0) return nofreqTimstr("mstimstr", t)
    return fmstimstr(t, f)
}

/**
 * C `getcfreq()`: the counter frequency.
 *
 * Translation of the C function getcfreq() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.getcfreq(): Double = if (sig.cfreq > 0.0) sig.cfreq else sig.ffreq

/**
 * C `setcfreq(freq)`: sets the counter frequency.
 *
 * Translation of the C function setcfreq() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.setcfreq(freq: Double) {
    sig.cfreq = freq
}

/**
 * C `getbasecount()`: the base counter value.
 *
 * Translation of the C function getbasecount() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.getbasecount(): Double = sig.bcount

/**
 * C `setbasecount(count)`: sets the base counter value.
 *
 * Translation of the C function setbasecount() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.setbasecount(counter: Double) {
    sig.bcount = counter
}

/**
 * C `strtim(string)`: converts a time string to a sample number.
 *
 * The string may be an elapsed time ("1:02:03.5", "10" seconds), a sample
 * number ("s1000"), a time of day ("[12:00:00]", with an optional date),
 * "e" (the end of the record), "i" (the current position of the input
 * signals), or "o" (that of the output signals).
 *
 * Returns the number of samples (> 0) for an elapsed time; the negated
 * elapsed time from the start of the record for a time of day; 0 for the
 * base time, or for an incorrectly formatted string.
 *
 * wfdb-x: if no sampling frequency is specified and the string needs one
 * (see [wfdbx_time_needs_freq]), reports an error and returns 0.
 *
 * Translation of the C function strtim() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: if the string needs a sampling frequency
 * and none is specified, it reports an error and returns 0 (the original
 * assumed 1 sample per second); see docs/DIVERGENCES.md.
 */
fun Wfdb.strtim(string: ByteArray): Long {
    var f = tfreq()
    if (f <= 0.0) {
        // wfdb-x: no default sampling frequency (C used 1 sample per second)
        if (wfdbx_time_needs_freq(string) != 0) {
            wfdb_error("strtim: sampling frequency is not specified\n")
            return 0
        }
        f = 1.0 // not used
    }
    return fstrtim(string, f)
}

/** [strtim] with a string. */
fun Wfdb.strtim(string: String): Long = strtim(string.latin1())

/**
 * C `datstr(date)`: a Julian date as " dd/mm/yyyy" (with a leading space).
 *
 * Translation of the C function datstr() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.datstr(date: Long): ByteArray {
    val ymd = julianToYmd(date)
    val ds = truncated(cformat(" %02d/%02d/%d", ymd[2], ymd[1], ymd[0]), DATE_STRING_LEN)
    sig.dateString = ds
    sig.pdays = -1
    return ds.copyOf()
}

/**
 * C `strdat(string)`: the Julian date of a "dd/mm/yyyy" date (0 if it is
 * invalid).
 *
 * Translation of the C function strdat() (lib/signal.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.strdat(string0: ByteArray): Long {
    val string = cstr(string0)
    val mp = strchrAt(string, '/')
    if (mp < 0) return 0
    val yp = strchrAt(string, '/', mp + 1)
    if (yp < 0) return 0
    val d = strtol(string, 10, 0).value.toInt()
    if (d < 1 || d > 31) return 0
    val m = strtol(string, 10, mp + 1).value.toInt()
    if (m < 1 || m > 12) return 0
    val y = strtol(string, 10, yp + 1).value.toInt()
    if (y == 0) return 0
    val jy: Int
    val jm: Int
    if (m > 2) {
        jy = y; jm = m + 1
    } else {
        jy = y - 1; jm = m + 13
    }
    var date: Long = if (jy > 0) d2l(365.25 * jy) else -d2l(-365.25 * (jy + 0.25))
    date += (d2i(30.6001 * jm) + d).toLong() + 1720995
    if (d.toLong() + 31 * (m.toLong() + 12 * y.toLong()) >= IGREG_DMY) {
        // 15/10/1582: Gregorian calendar correction
        val gcorr = d2i(0.01 * jy)
        date += (2 - gcorr + d2i(0.25 * gcorr)).toLong()
    }
    return date
}

/** [strdat] with a string. */
fun Wfdb.strdat(string: String): Long = strdat(string.latin1())

// ---------------------------------------------------------------------------
// Amplitude conversion

/**
 * wfdb-x: the gain of signal s for the unit conversion functions (named
 * func in error messages), or 0 after reporting an error if s is not a valid
 * signal number or the signal is uncalibrated. The C library assumed
 * WFDB_DEFGAIN (200 adu per physical unit) instead. In legacy mode, as in C:
 * WFDB_DEFGAIN for an uncalibrated signal or an invalid signal number,
 * without an error.
 */
private fun Wfdb.conversionGain(func: String, s: Int): Double {
    if (legacy) {
        // wfdb-x: legacy mode (original behavior)
        val g = baselineGainGain(s)
        return if (g == 0.0) WFDB_DEFGAIN else g
    }
    if (!validSignal(s)) {
        wfdb_error(cformat("%s: invalid signal number %u\n", func, s))
        return 0.0
    }
    val g = sig.vsd[s].info.gain
    if (g == 0.0) wfdb_error(cformat("%s: signal %u is uncalibrated\n", func, s))
    return g
}

/** Whether s is a valid signal number (C's unsigned comparison s < nvsig). */
private fun Wfdb.validSignal(s: Int): Boolean = s >= 0 && s < sig.nvsig

/** The baseline of signal s, or 0 if s is not a valid signal number (possible in legacy mode only). */
private fun Wfdb.baselineOf(s: Int): Int = if (validSignal(s)) sig.vsd[s].info.baseline else 0

/** The gain of signal s, or WFDB_DEFGAIN if s is not a valid signal number. */
private fun Wfdb.baselineGainGain(s: Int): Double = if (validSignal(s)) sig.vsd[s].info.gain else WFDB_DEFGAIN

/**
 * C `adumuv(s, a)`: converts ADC units to microvolts.
 *
 * wfdb-x: returns WFDB_INVALID_SAMPLE (after reporting an error) if s is
 * invalid or the signal is uncalibrated.
 *
 * Translation of the C function adumuv() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: an uncalibrated signal or an invalid
 * signal number is an error (the original assumed a gain of 200); see
 * docs/DIVERGENCES.md.
 */
fun Wfdb.adumuv(s: Int, a: Int): Int {
    val g = conversionGain("adumuv", s)
    if (g == 0.0) return WFDB_INVALID_SAMPLE
    val x = a * 1000.0 / g
    return if (x >= 0.0) d2i(x + 0.5) else d2i(x - 0.5)
}

/**
 * C `muvadu(s, v)`: converts microvolts to ADC units.
 *
 * wfdb-x: returns WFDB_INVALID_SAMPLE (after reporting an error) if s is
 * invalid or the signal is uncalibrated.
 *
 * Translation of the C function muvadu() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: an uncalibrated signal or an invalid
 * signal number is an error (the original assumed a gain of 200); see
 * docs/DIVERGENCES.md.
 */
fun Wfdb.muvadu(s: Int, v: Int): Int {
    val g = conversionGain("muvadu", s)
    if (g == 0.0) return WFDB_INVALID_SAMPLE
    val x = g * v * 0.001
    return if (x >= 0.0) d2i(x + 0.5) else d2i(x - 0.5)
}

/**
 * C `aduphys(s, a)`: converts ADC units to physical units.
 *
 * wfdb-x: returns NaN (after reporting an error) if s is invalid or the
 * signal is uncalibrated.
 *
 * Translation of the C function aduphys() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: an uncalibrated signal or an invalid
 * signal number is an error (the original assumed a gain of 200); see
 * docs/DIVERGENCES.md.
 */
fun Wfdb.aduphys(s: Int, a: Int): Double {
    val g = conversionGain("aduphys", s)
    if (g == 0.0) return Double.NaN
    val b = baselineOf(s).toDouble()
    return (a - b) / g
}

/**
 * C `physadu(s, v)`: converts physical units to ADC units.
 *
 * wfdb-x: returns WFDB_INVALID_SAMPLE (after reporting an error) if s is
 * invalid or the signal is uncalibrated.
 *
 * Translation of the C function physadu() (lib/signal.c, WFDB 10.7.0): same
 * arguments and results. Differences: an uncalibrated signal or an invalid
 * signal number is an error (the original assumed a gain of 200); see
 * docs/DIVERGENCES.md.
 */
fun Wfdb.physadu(s: Int, v0: Double): Int {
    val g = conversionGain("physadu", s)
    if (g == 0.0) return WFDB_INVALID_SAMPLE
    val b = baselineOf(s)
    val v = v0 * g
    return if (v >= 0.0) d2i(v + 0.5) + b else d2i(v - 0.5) + b
}

// ---------------------------------------------------------------------------
// Top-level functions (default instance)

/** C `setbasetime` on the default instance (see [Wfdb.setbasetime]). */
fun setbasetime(string: ByteArray?): Int = wfdbDefault().setbasetime(string)

/** C `setbasetime` on the default instance (see [Wfdb.setbasetime]). */
fun setbasetime(string: String): Int = wfdbDefault().setbasetime(string)

/** C `timstr` on the default instance (see [Wfdb.timstr]). */
fun timstr(t: Long): ByteArray = wfdbDefault().timstr(t)

/** C `mstimstr` on the default instance (see [Wfdb.mstimstr]). */
fun mstimstr(t: Long): ByteArray = wfdbDefault().mstimstr(t)

/** C `getcfreq` on the default instance (see [Wfdb.getcfreq]). */
fun getcfreq(): Double = wfdbDefault().getcfreq()

/** C `setcfreq` on the default instance (see [Wfdb.setcfreq]). */
fun setcfreq(freq: Double) = wfdbDefault().setcfreq(freq)

/** C `getbasecount` on the default instance (see [Wfdb.getbasecount]). */
fun getbasecount(): Double = wfdbDefault().getbasecount()

/** C `setbasecount` on the default instance (see [Wfdb.setbasecount]). */
fun setbasecount(counter: Double) = wfdbDefault().setbasecount(counter)

/** C `strtim` on the default instance (see [Wfdb.strtim]). */
fun strtim(string: ByteArray): Long = wfdbDefault().strtim(string)

/** C `strtim` on the default instance (see [Wfdb.strtim]). */
fun strtim(string: String): Long = wfdbDefault().strtim(string)

/** wfdb-x addition: `wfdbx_time_needs_freq` on the default instance (see [Wfdb.wfdbx_time_needs_freq]). */
fun wfdbx_time_needs_freq(string: ByteArray): Int = wfdbDefault().wfdbx_time_needs_freq(string)

/** wfdb-x addition: `wfdbx_time_needs_freq` on the default instance (see [Wfdb.wfdbx_time_needs_freq]). */
fun wfdbx_time_needs_freq(string: String): Int = wfdbDefault().wfdbx_time_needs_freq(string)

/** C `datstr` on the default instance (see [Wfdb.datstr]). */
fun datstr(date: Long): ByteArray = wfdbDefault().datstr(date)

/** C `strdat` on the default instance (see [Wfdb.strdat]). */
fun strdat(string: ByteArray): Long = wfdbDefault().strdat(string)

/** C `strdat` on the default instance (see [Wfdb.strdat]). */
fun strdat(string: String): Long = wfdbDefault().strdat(string)

/** C `adumuv` on the default instance (see [Wfdb.adumuv]). */
fun adumuv(s: Int, a: Int): Int = wfdbDefault().adumuv(s, a)

/** C `muvadu` on the default instance (see [Wfdb.muvadu]). */
fun muvadu(s: Int, v: Int): Int = wfdbDefault().muvadu(s, v)

/** C `aduphys` on the default instance (see [Wfdb.aduphys]). */
fun aduphys(s: Int, a: Int): Double = wfdbDefault().aduphys(s, a)

/** C `physadu` on the default instance (see [Wfdb.physadu]). */
fun physadu(s: Int, v: Double): Int = wfdbDefault().physadu(s, v)
