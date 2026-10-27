// Calibration list (port of lib/calib.c, from rust/src/calib.rs): calopen
// (reads a calibration file into the calibration list), getcal (finds an
// entry of the list), putcal (appends an entry), newcal (writes the list to
// a calibration file) and flushcal (empties the list). Calibration files
// are written with \r\n line separators.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of lib/calib.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language.
//
// Original C code: lib/calib.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1991-2013 George B. Moody; revised 2019-2022 by
//   Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

import wfdbx.cstd.ByteVec
import wfdbx.cstd.Strtok
import wfdbx.cstd.beq
import wfdbx.cstd.cformat
import wfdbx.cstd.cstr
import wfdbx.cstd.getenv
import wfdbx.cstd.latin1
import wfdbx.cstd.startsWith
import wfdbx.cstd.strtod

/** The state of calib.c (part of [Wfdb]): the calibration list. */
internal class CalState {
    val list = ArrayList<Calinfo>()
}

/**
 * C `calopen(cfname)`: reads a calibration file into the calibration list.
 * With null, the file named by the environment variable WFDBCAL (default
 * wfdbcal) is read. Unless the name begins with "+", the list is emptied
 * first. The file is found as wfdb_open finds files. Returns 0, or -2 if
 * the file cannot be read.
 *
 * Translation of the C function calopen() (lib/calib.c, WFDB 10.7.0): same
 * arguments and results. Differences: the calibration file is found only where
 * it is named, not by a search of the WFDB path; see docs/DIVERGENCES.md.
 */
fun Wfdb.calopen(cfname0: ByteArray?): Int {
    // If no calibration file is specified, use the default.
    var name = if (cfname0 != null) cstr(cfname0) else getenv("WFDBCAL") ?: DEFWFDBCAL.latin1()
    if (name.at0() == '+'.code) {
        // don't empty the calibration list
        name = name.copyOfRange(1, name.size) // discard the '+' prefix
    } else {
        flushcal() // empty the calibration list
    }

    // Quit if file can't be found or opened.
    val cfile = wfdb_open(name, null, WFDB_READ)
    if (cfile == null) {
        wfdb_error(cformat("calopen: can't read calibration file %s\n", name))
        return -2
    }

    // Read a line of the calibration file on each iteration. See wfdbcal(5)
    // for a description of the format.
    val line = ByteVec(256)
    while (cfile.getline(line) > 0) {
        val buf0 = cstr(line.toByteArray())
        // ignore leading whitespace
        var skip = 0
        while (skip < buf0.size && (buf0[skip] == ' '.code.toByte() || buf0[skip] == '\t'.code.toByte() || buf0[skip] == '\r'.code.toByte())) skip++
        val buf = buf0.copyOfRange(skip, buf0.size)
        // skip comments, empty lines, and improperly formatted lines
        if (buf.isNotEmpty() && buf[0] == '#'.code.toByte()) continue
        val tok = Strtok(buf)
        val p1 = tok.next("\t") ?: continue // type
        val p2 = tok.next(" \t") ?: continue // low
        val p3 = tok.next(" \t") ?: continue // high
        val p4 = tok.next(" \t") ?: continue // pulse
        val p5 = tok.next(" \t") ?: continue // scale
        val p6 = tok.next(" \t\r\n") ?: continue // units

        val c = Calinfo()
        // "*" is a wildcard that matches any signal type.
        c.sigtype = if (beq(p1, "*")) ByteArray(0) else p1
        if (beq(p2, "-")) {
            c.caltype = WFDB_AC_COUPLED
            c.low = 0.0
        } else {
            c.caltype = WFDB_DC_COUPLED
            c.low = strtod(p2).value
        }
        if (beq(p3, "-")) {
            c.high = 0.0
            c.low = 0.0
        } else {
            c.high = strtod(p3).value
        }
        when {
            beq(p4, "square") -> c.caltype = c.caltype or WFDB_CAL_SQUARE
            beq(p4, "sine") -> c.caltype = c.caltype or WFDB_CAL_SINE
            beq(p4, "sawtooth") -> c.caltype = c.caltype or WFDB_CAL_SAWTOOTH
            // otherwise pulse shape is undefined
        }
        c.scale = strtod(p5).value
        c.units = p6
        cal.list.add(c)
    }
    cfile.close()
    return 0
}

/** [calopen] with a string. */
fun Wfdb.calopen(cfname: String): Int = calopen(cfname.latin1())

private fun ByteArray.at0(): Int = if (isEmpty()) 0 else this[0].toInt() and 0xff

/**
 * C `getcal(desc, units, &cal)`: finds the first calibration list entry
 * whose signal type is a prefix of [desc] and whose units are [units] (a
 * null argument matches anything), and copies it into [cal]. Returns 0, or
 * -1 if there is none.
 *
 * Translation of the C function getcal() (lib/calib.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.getcal(desc0: ByteArray?, units0: ByteArray?, cal: Calinfo): Int {
    val desc = desc0?.let { cstr(it) }
    val units = units0?.let { cstr(it) }
    for (c in this.cal.list) {
        val sigtype = c.sigtype ?: ByteArray(0)
        val dmatch = desc == null || desc.startsWith(sigtype)
        val umatch = units == null || beq(c.units, units)
        if (dmatch && umatch) {
            cal.set(c)
            return 0
        }
    }
    return -1
}

/** [getcal] with strings. */
fun Wfdb.getcal(desc: String?, units: String?, cal: Calinfo): Int = getcal(desc?.latin1(), units?.latin1(), cal)

/**
 * C `putcal(&cal)`: appends (a copy of) an entry to the calibration list.
 *
 * Translation of the C function putcal() (lib/calib.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.putcal(c: Calinfo): Int {
    cal.list.add(c.copy())
    return 0
}

/**
 * C `newcal(cfname)`: writes the calibration list to a calibration file.
 * Returns 0, or -1 on errors.
 *
 * Translation of the C function newcal() (lib/calib.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.newcal(cfname0: ByteArray): Int {
    val cfname = cstr(cfname0)
    if (wfdb_checkname(cfname, "calibration file") < 0) return -1
    val cfile = wfdb_open(cfname, null, WFDB_WRITE)
    if (cfile == null) {
        wfdb_error(cformat("newcal: can't create calibration file %s\n", cfname))
        return -1
    }
    for (c in cal.list) {
        // If sigtype is an empty string (matches anything), write it as "*".
        val sigtype = c.sigtype ?: ByteArray(0)
        cfile.printf("%s\t", if (sigtype.isEmpty()) "*".latin1() else sigtype)
        if ((c.caltype and WFDB_DC_COUPLED) != 0) cfile.printf("%g ", c.low) else cfile.printf("- ")
        if (c.high != c.low) cfile.printf("%g ", c.high) else cfile.printf("- ")
        val pulsetype = when (c.caltype and WFDB_DC_COUPLED.inv()) {
            WFDB_CAL_SQUARE -> "square"
            WFDB_CAL_SINE -> "sine"
            WFDB_CAL_SAWTOOTH -> "sawtooth"
            else -> "undefined"
        }
        cfile.printf("%s %g %s\r\n", pulsetype, c.scale, c.units ?: "(null)".latin1())
    }
    var errflag = cfile.error()
    if (cfile.close() != 0) errflag = true
    if (errflag) {
        wfdb_error("newcal: write error in calibration file\n")
        return -1
    }
    return 0
}

/** [newcal] with a string. */
fun Wfdb.newcal(cfname: String): Int = newcal(cfname.latin1())

/**
 * C `flushcal()`: empties the calibration list.
 *
 * Translation of the C function flushcal() (lib/calib.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.flushcal() {
    cal.list.clear()
}

/** C `calopen` on the default instance. */
fun calopen(cfname: ByteArray?): Int = wfdbDefault().calopen(cfname)

/** C `calopen` on the default instance. */
fun calopen(cfname: String): Int = wfdbDefault().calopen(cfname)

/** C `getcal` on the default instance. */
fun getcal(desc: ByteArray?, units: ByteArray?, cal: Calinfo): Int = wfdbDefault().getcal(desc, units, cal)

/** C `getcal` on the default instance. */
fun getcal(desc: String?, units: String?, cal: Calinfo): Int = wfdbDefault().getcal(desc, units, cal)

/** C `putcal` on the default instance. */
fun putcal(cal: Calinfo): Int = wfdbDefault().putcal(cal)

/** C `newcal` on the default instance. */
fun newcal(cfname: ByteArray): Int = wfdbDefault().newcal(cfname)

/** C `newcal` on the default instance. */
fun newcal(cfname: String): Int = wfdbDefault().newcal(cfname)

/** C `flushcal` on the default instance. */
fun flushcal() = wfdbDefault().flushcal()
