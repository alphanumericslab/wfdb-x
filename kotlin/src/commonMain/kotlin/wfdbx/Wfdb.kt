// The library object Wfdb, which holds all the state of the C library, and
// the default instance used by the top-level functions (port of
// rust/src/wfdb.rs).
//
// Organization: each C library function is an extension function of Wfdb
// with the C name, defined in the file that ports the corresponding C
// source (Wfdbio.kt, Signal.kt, Annot.kt, Calib.kt, Wfdbinit.kt,
// Ecgcodes.kt), and also a top-level function with the same name and
// arguments operating on the default instance of the calling thread. The
// state of each C source file is a field of Wfdb whose class is defined in
// the file that ports it:
//
//   io    IoState    Wfdbio.kt   (input/output directories, network access,
//                                 WFDB path, errors, current record name)
//   sig   SigState   Signal.kt   (headers, signals, time base, info)
//   ann   AnnState   Annot.kt    (annotators, mnemonic tables)
//   cal   CalState   Calib.kt    (calibration list)
//   maps  EcgMaps    Ecgcodes.kt (<ecgmap.h> tables)
//
// plus the legacy-mode flag, used by all of them.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

/**
 * The state of the WFDB library: what the C library keeps in global
 * variables (the WFDB path, open records, signals, annotators, calibration
 * list, ...).
 *
 * Each C library function is an extension function of Wfdb with the C name
 * and arguments (`w.isigopen(...)`, `w.getann(...)`). Several independent
 * instances may be used at once, each with its own state (unlike the C
 * library, where there is only one).
 *
 * The same functions are also top-level functions that use a default
 * instance, one per thread ([wfdbDefault]); use them for line-by-line ports
 * of C programs, and an explicit Wfdb otherwise.
 *
 * A Wfdb is not thread-safe: use each instance from one thread at a time
 * (it may be handed from one thread to another).
 *
 * Output files left open are flushed by [wfdbx.cstd.exit], as C's exit
 * flushes every stream, but nothing else is done (no annotation end marks,
 * no header updates): call [wfdbquit] first to close records properly.
 */
class Wfdb {
    /** I/O state (Wfdbio.kt). */
    internal val io = IoState()

    /** Signal state (Signal.kt). */
    internal val sig = SigState()

    /** Annotation state (Annot.kt). */
    internal val ann = AnnState()

    /** Calibration state (Calib.kt). */
    internal val cal = CalState()

    /** <ecgmap.h> tables (Ecgcodes.kt). */
    internal val maps = EcgMaps()

    /** WFDB-x: legacy mode (see [wfdbx_set_legacy]). */
    internal var legacy = false
}

/** The default instance of the calling thread (one per thread). */
internal expect fun threadDefaultWfdb(): Wfdb

/**
 * The default instance of the calling thread: the [Wfdb] used by the
 * top-level functions (`isigopen(...)`, `getann(...)`, ...).
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbDefault(): Wfdb = threadDefaultWfdb()

/**
 * Runs [f] with the default instance of the calling thread and returns its
 * result.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
inline fun <R> withDefault(f: (Wfdb) -> R): R = f(wfdbDefault())
