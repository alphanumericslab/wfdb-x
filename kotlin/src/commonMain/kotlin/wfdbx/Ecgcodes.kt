// Annotation codes (<wfdb/ecgcodes.h>) and the annotation code mapping
// functions of <wfdb/ecgmap.h> (isann, isqrs, map1, map2, ammap, mamap,
// annpos and their setters), ported from rust/src/ecgcodes.rs.
//
// The mapping tables can be modified (setisqrs, setmap1, ...), so they are
// part of the library state: the functions that use them are extension
// functions of Wfdb (w.wfdb_isqrs(code)), with top-level versions
// (isqrs(code), wfdb_isqrs(code)) that use the default instance. isann,
// ammap and mamap use constant tables and are plain functions.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of lib/ecgcodes.h, lib/ecgmap.h and the
// annotation code mapping functions of lib/annot.c (wfdb_isann, wfdb_isqrs,
// wfdb_map1, wfdb_map2, wfdb_ammap, wfdb_mamap, wfdb_annpos and their setters)
// from the WFDB Software Package 10.7.0, by T. Baker and George B. Moody
// (lib/ecgcodes.h) and George B. Moody (lib/ecgmap.h, lib/annot.c). The
// translation follows the logic and behavior of the original code, but it is
// new code, not the original C code.
//
// Changes from the original: none, apart from the language.
//
// Original C code: lib/ecgcodes.h, lib/ecgmap.h and lib/annot.c, WFDB Software
// Package 10.7.0.
//   lib/ecgcodes.h: Copyright (C) 1999 George B. Moody.
//   lib/ecgmap.h: Copyright (C) 1999 George B. Moody.
//   lib/annot.c: Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by
//   Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

/** Not-QRS (not a getann/putann code). */
const val NOTQRS: Int = 0

/** Normal beat. */
const val NORMAL: Int = 1

/** Left bundle branch block beat. */
const val LBBB: Int = 2

/** Right bundle branch block beat. */
const val RBBB: Int = 3

/** Aberrated atrial premature beat. */
const val ABERR: Int = 4

/** Premature ventricular contraction. */
const val PVC: Int = 5

/** Fusion of ventricular and normal beat. */
const val FUSION: Int = 6

/** Nodal (junctional) premature beat. */
const val NPC: Int = 7

/** Atrial premature contraction. */
const val APC: Int = 8

/** Premature or ectopic supraventricular beat. */
const val SVPB: Int = 9

/** Ventricular escape beat. */
const val VESC: Int = 10

/** Nodal (junctional) escape beat. */
const val NESC: Int = 11

/** Paced beat. */
const val PACE: Int = 12

/** Unclassifiable beat. */
const val UNKNOWN: Int = 13

/** Signal quality change. */
const val NOISE: Int = 14

/** Isolated QRS-like artifact. */
const val ARFCT: Int = 16

/** ST change. */
const val STCH: Int = 18

/** T-wave change. */
const val TCH: Int = 19

/** Systole. */
const val SYSTOLE: Int = 20

/** Diastole. */
const val DIASTOLE: Int = 21

/** Comment annotation. */
const val NOTE: Int = 22

/** Measurement annotation. */
const val MEASURE: Int = 23

/** P-wave peak. */
const val PWAVE: Int = 24

/** Left or right bundle branch block. */
const val BBB: Int = 25

/** Non-conducted pacer spike. */
const val PACESP: Int = 26

/** T-wave peak. */
const val TWAVE: Int = 27

/** Rhythm change. */
const val RHYTHM: Int = 28

/** U-wave peak. */
const val UWAVE: Int = 29

/** Learning. */
const val LEARN: Int = 30

/** Ventricular flutter wave. */
const val FLWAV: Int = 31

/** Start of ventricular flutter/fibrillation. */
const val VFON: Int = 32

/** End of ventricular flutter/fibrillation. */
const val VFOFF: Int = 33

/** Atrial escape beat. */
const val AESC: Int = 34

/** Supraventricular escape beat. */
const val SVESC: Int = 35

/** Link to external data (aux contains URL). */
const val LINK: Int = 36

/** Non-conducted P-wave (blocked APB). */
const val NAPC: Int = 37

/** Fusion of paced and normal beat. */
const val PFUS: Int = 38

/** Waveform onset. */
const val WFON: Int = 39

/** PQ junction (beginning of QRS). */
const val PQ: Int = WFON

/** Waveform end. */
const val WFOFF: Int = 40

/** J point (end of QRS). */
const val JPT: Int = WFOFF

/** R-on-T premature ventricular contraction. */
const val RONT: Int = 41

/** Value of the largest valid annotation code (must be < 50). */
const val ACMAX: Int = 49

/** Annotation position: undefined annotation types. */
const val APUNDEF: Int = 0

/** Standard position. */
const val APSTD: Int = 1

/** A level above APSTD. */
const val APHIGH: Int = 2

/** A level below APSTD. */
const val APLOW: Int = 3

/** Attached to the signal specified by `chan`. */
const val APATT: Int = 4

/** A level above APATT. */
const val APAHIGH: Int = 5

/** A level below APATT. */
const val APALOW: Int = 6

private const val N = ACMAX + 1

private val QRS_TABLE = intArrayOf(
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
)

private val MP1_TABLE = intArrayOf(
    0, 1, 1, 1, 1, // NOTQRS, NORMAL, NORMAL, NORMAL, NORMAL: 0 - 4
    5, 6, 1, 1, 1, // PVC, FUSION, NORMAL, NORMAL, NORMAL: 5 - 9
    5, 1, 1, 1, 0, // PVC, NORMAL, NORMAL, NORMAL, NOTQRS: 10 - 14
    0, 0, 0, 0, 0, // 15 - 19
    0, 0, 0, 0, 0, // 20 - 24
    1, 0, 0, 0, 0, // NORMAL: 25 - 29
    30, 5, 0, 0, 1, // LEARN, PVC, NOTQRS, NOTQRS, NORMAL: 30 - 34
    1, 0, 0, 1, 0, // NORMAL, NOTQRS, NOTQRS, NORMAL, NOTQRS: 35 - 39
    0, 5, 0, 0, 0, // NOTQRS, PVC: 40 - 44
    0, 0, 0, 0, 0, // 45 - 49
)

private val MP2_TABLE = intArrayOf(
    0, 1, 1, 1, 9, // NOTQRS, NORMAL, NORMAL, NORMAL, SVPB: 0 - 4
    5, 6, 9, 9, 9, // PVC, FUSION, SVPB, SVPB, SVPB: 5 - 9
    5, 1, 1, 1, 0, // PVC, NORMAL, NORMAL, NORMAL, NOTQRS: 10 - 14
    0, 0, 0, 0, 0, // 15 - 19
    0, 0, 0, 0, 0, // 20 - 24
    1, 0, 0, 0, 0, // NORMAL: 25 - 29
    30, 5, 0, 0, 1, // LEARN, PVC, NOTQRS, NOTQRS, NORMAL: 30 - 34
    1, 0, 0, 1, 0, // 35 - 39
    0, 5, 0, 0, 0, // 40 - 44
    0, 0, 0, 0, 0, // 45 - 49
)

/** AHA code ('E'..']') to MIT code. */
private val AMMP_TABLE = intArrayOf(
    VESC, FUSION, 0, 0, 0, // 'E' - 'I'
    0, 0, 0, 0, NORMAL, // 'J' - 'N'
    NOTE, PACE, UNKNOWN, RONT, 0, // 'O' - 'S'
    0, NOISE, PVC, 0, 0, // 'T' - 'X'
    0, 0, VFON, 0, VFOFF, // 'Y' - ']'
)

/** MIT code to AHA code. */
private const val MAMP_TABLE = "ONNNNVFNNNENPQUOOOOOOOOOONOOOOQO[]NNOONOOROOOOOOOO"

private val ANNP_TABLE = intArrayOf(
    0, 1, 1, 1, 1,
    1, 1, 1, 1, 1,
    1, 1, 1, 1, 2,
    0, 2, 0, 2, 2,
    2, 2, 2, 2, 2,
    1, 2, 2, 3, 2,
    1, 1, 1, 1, 1,
    1, 2, 2, 1, 2,
    2, 1, 0, 0, 0,
    0, 0, 0, 0, 0,
)

/** The modifiable annotation code mapping tables of <ecgmap.h> (part of the Wfdb state; not reset by wfdbquit). Values are C chars. */
internal class EcgMaps {
    val qrs = QRS_TABLE.copyOf()
    val mp1 = MP1_TABLE.copyOf()
    val mp2 = MP2_TABLE.copyOf()
    val annp = ANNP_TABLE.copyOf()
}

/**
 * C `isann(code)`: 1 if [code] is a legal annotation code.
 *
 * Translation of the C function wfdb_isann() (lib/annot.c) and the macro isann() (lib/ecgmap.h), WFDB 10.7.0: same arguments and results.
 */
fun wfdb_isann(code: Int): Int = if (0 < code && code <= ACMAX) 1 else 0

/** Alias of [wfdb_isann] (the <ecgmap.h> macro name). */
fun isann(code: Int): Int = wfdb_isann(code)

/**
 * C `ammap(code)`: maps an AHA code (a character) to an MIT code.
 *
 * Translation of the C function wfdb_ammap() (lib/annot.c) and the macro ammap() (lib/ecgmap.h), WFDB 10.7.0: same arguments and results.
 */
fun wfdb_ammap(code: Int): Int =
    if ('D'.code < code && code <= ']'.code) AMMP_TABLE[code - 'E'.code] else NOTQRS

/** Alias of [wfdb_ammap]. */
fun ammap(code: Int): Int = wfdb_ammap(code)

/**
 * C `mamap(code, subtype)`: maps an MIT code to an AHA code.
 *
 * Translation of the C function wfdb_mamap() (lib/annot.c) and the macro mamap() (lib/ecgmap.h), WFDB 10.7.0: same arguments and results.
 */
fun wfdb_mamap(code: Int, subtype: Int): Int {
    if (wfdb_isann(code) == 0) return 'O'.code
    val m = MAMP_TABLE[code]
    return if (m == 'U' && subtype != -1) 'O'.code else m.code
}

/** Alias of [wfdb_mamap]. */
fun mamap(code: Int, subtype: Int): Int = wfdb_mamap(code, subtype)

/**
 * C `isqrs(code)`: 1 if [code] denotes a QRS complex.
 *
 * Translation of the C function wfdb_isqrs() (lib/annot.c) and the macro isqrs() (lib/ecgmap.h), WFDB 10.7.0: same arguments and results.
 */
fun Wfdb.wfdb_isqrs(code: Int): Int = if (wfdb_isann(code) != 0) maps.qrs[code] else 0

/**
 * C `setisqrs(code, newval)` (the value is stored as a char, so setisqrs(2,
 * 300) returns 44).
 *
 * Translation of the C function wfdb_setisqrs() (lib/annot.c) and the macro setisqrs() (lib/ecgmap.h), WFDB 10.7.0: same arguments and results.
 */
fun Wfdb.wfdb_setisqrs(code: Int, newval: Int): Int {
    if (wfdb_isann(code) == 0) return 0
    maps.qrs[code] = newval.toByte().toInt()
    return maps.qrs[code]
}

/**
 * C `map1(code)`: maps to one of NORMAL, PVC, FUSION, LEARN, NOTQRS.
 *
 * Translation of the C function wfdb_map1() (lib/annot.c) and the macro map1() (lib/ecgmap.h), WFDB 10.7.0: same arguments and results.
 */
fun Wfdb.wfdb_map1(code: Int): Int = if (wfdb_isann(code) != 0) maps.mp1[code] else NOTQRS

/**
 * C `setmap1(code, newval)`: returns newval (as a C char), or NOTQRS if code is
 * not an annotation type.
 *
 * Translation of the C function wfdb_setmap1() (lib/annot.c) and the macro setmap1() (lib/ecgmap.h), WFDB 10.7.0: same arguments and results.
 */
fun Wfdb.wfdb_setmap1(code: Int, newval: Int): Int {
    if (wfdb_isann(code) == 0) return NOTQRS
    maps.mp1[code] = newval.toByte().toInt()
    return maps.mp1[code]
}

/**
 * C `map2(code)`: maps to one of NORMAL, SVPB, PVC, FUSION, LEARN, NOTQRS.
 *
 * Translation of the C function wfdb_map2() (lib/annot.c) and the macro map2() (lib/ecgmap.h), WFDB 10.7.0: same arguments and results.
 */
fun Wfdb.wfdb_map2(code: Int): Int = if (wfdb_isann(code) != 0) maps.mp2[code] else NOTQRS

/**
 * C `setmap2(code, newval)`: returns newval (as a C char), or NOTQRS if code is
 * not an annotation type.
 *
 * Translation of the C function wfdb_setmap2() (lib/annot.c) and the macro setmap2() (lib/ecgmap.h), WFDB 10.7.0: same arguments and results.
 */
fun Wfdb.wfdb_setmap2(code: Int, newval: Int): Int {
    if (wfdb_isann(code) == 0) return NOTQRS
    maps.mp2[code] = newval.toByte().toInt()
    return maps.mp2[code]
}

/**
 * C `annpos(code)`: the display position of an annotation type.
 *
 * Translation of the C function wfdb_annpos() (lib/annot.c) and the macro annpos() (lib/ecgmap.h), WFDB 10.7.0: same arguments and results.
 */
fun Wfdb.wfdb_annpos(code: Int): Int = if (wfdb_isann(code) != 0) maps.annp[code] else 0

/**
 * C `setannpos(code, newval)`: returns newval (as a C char), or 0 if code is
 * not an annotation type.
 *
 * Translation of the C function wfdb_setannpos() (lib/annot.c) and the macro setannpos() (lib/ecgmap.h), WFDB 10.7.0: same arguments and results.
 */
fun Wfdb.wfdb_setannpos(code: Int, newval: Int): Int {
    if (wfdb_isann(code) == 0) return 0
    maps.annp[code] = newval.toByte().toInt()
    return maps.annp[code]
}

/** C `isqrs(code)` on the default instance. */
fun isqrs(code: Int): Int = wfdbDefault().wfdb_isqrs(code)

/** C `wfdb_isqrs(code)` on the default instance. */
fun wfdb_isqrs(code: Int): Int = wfdbDefault().wfdb_isqrs(code)

/** C `setisqrs(code, newval)` on the default instance. */
fun setisqrs(code: Int, newval: Int): Int = wfdbDefault().wfdb_setisqrs(code, newval)

/** C `wfdb_setisqrs` on the default instance. */
fun wfdb_setisqrs(code: Int, newval: Int): Int = wfdbDefault().wfdb_setisqrs(code, newval)

/** C `map1(code)` on the default instance. */
fun map1(code: Int): Int = wfdbDefault().wfdb_map1(code)

/** C `wfdb_map1` on the default instance. */
fun wfdb_map1(code: Int): Int = wfdbDefault().wfdb_map1(code)

/** C `setmap1(code, newval)` on the default instance. */
fun setmap1(code: Int, newval: Int): Int = wfdbDefault().wfdb_setmap1(code, newval)

/** C `wfdb_setmap1` on the default instance. */
fun wfdb_setmap1(code: Int, newval: Int): Int = wfdbDefault().wfdb_setmap1(code, newval)

/** C `map2(code)` on the default instance. */
fun map2(code: Int): Int = wfdbDefault().wfdb_map2(code)

/** C `wfdb_map2` on the default instance. */
fun wfdb_map2(code: Int): Int = wfdbDefault().wfdb_map2(code)

/** C `setmap2(code, newval)` on the default instance. */
fun setmap2(code: Int, newval: Int): Int = wfdbDefault().wfdb_setmap2(code, newval)

/** C `wfdb_setmap2` on the default instance. */
fun wfdb_setmap2(code: Int, newval: Int): Int = wfdbDefault().wfdb_setmap2(code, newval)

/** C `annpos(code)` on the default instance. */
fun annpos(code: Int): Int = wfdbDefault().wfdb_annpos(code)

/** C `wfdb_annpos` on the default instance. */
fun wfdb_annpos(code: Int): Int = wfdbDefault().wfdb_annpos(code)

/** C `setannpos(code, newval)` on the default instance. */
fun setannpos(code: Int, newval: Int): Int = wfdbDefault().wfdb_setannpos(code, newval)

/** C `wfdb_setannpos` on the default instance. */
fun wfdb_setannpos(code: Int, newval: Int): Int = wfdbDefault().wfdb_setannpos(code, newval)
