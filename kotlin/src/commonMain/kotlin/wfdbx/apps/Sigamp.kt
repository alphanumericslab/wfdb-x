// sigamp: measure signal amplitudes (port of app/sigamp.c, through
// rust/src/bin/sigamp.rs).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/sigamp.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency or gain: the
// record must give the sampling frequency (the measurement windows are in
// seconds), and with -p the gain of each signal (the original assumed 250 Hz
// and 200 adu/mV); --legacy, as the first argument, restores the original
// behavior. Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md
// gives the reasons.
//
// Original C program: app/sigamp.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1991-2009 George B. Moody; revised 2018 by Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*
import kotlin.math.sqrt

private const val SIGAMP_NMAX = 300

// values for timeunits
private const val SECONDS = 1
private const val MINUTES = 2
private const val HOURS = 3
private const val TIMSTR = 4
private const val HHMMSS = 7
private const val SAMPLES = 8

private val SIGAMP_HELP = arrayOf(
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where OPTIONS may include any of:",
    " -a ANN      specify annotator, measure amplitudes near QRS annotations",
    " -d DT1 DT2  set measurement window relative to QRS annotations",
    "              defaults: DT1 = 0.05 (seconds before annotation);",
    "              DT2 = 0.05 (seconds after annotation)",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -n NMAX     make up to NMAX measurements per signal (default: NMAX = 300)",
    " -p          print results in physical units (default: ADC units)",
    "              -p may be followed by a character to choose a time format:",
    "  -pd         print time of day and date if known",
    "  -pe         print elapsed time as <hours>:<minutes>:<seconds>",
    "  -ph         print elapsed time in hours",
    "  -pm         print elapsed time in minutes",
    "  -ps         print elapsed time in seconds (default)",
    "  -pS         print elapsed time in sample intervals",
    " -q          quick mode: print individual measurements only",
    " -t TIME     stop at specified time",
    " -v          verbose mode: print individual measurements and trimmed means",
    " -w DTW      set RMS amplitude measurement window",
    "              default: DTW = 1 (second)",
)

private fun sigampHelp(pname: ByteArray) {
    eprintf(SIGAMP_HELP[0], pname)
    for (k in 1 until SIGAMP_HELP.size) eprintf("%s\n", SIGAMP_HELP[k])
}

/** The program's global state. */
private class SigampState(
    val nsig: Int,
    val pflag: Boolean,
    val timeunits: Int,
    nmax: Int,
    val sfreq: Double,
    val si: Array<Siginfo>,
) {
    var namp = 0
    val v0 = IntArray(nsig)
    val vmax = IntArray(nsig)
    val vmin = IntArray(nsig)
    val vv = IntArray(nsig)
    val amp = Array(nsig) { DoubleArray(nmax) }
    val vmean = DoubleArray(nsig)
    val vsum = DoubleArray(nsig)
    var dt1 = 0L
    var dt2 = 0L
    var dtw = 0L
}

private fun Wfdb.getrms(st: SigampState, t: Long): Int {
    val n = st.nsig
    if (getvec(st.vv) < n) return -1
    for (i in 0 until n) {
        st.v0[i] = st.vv[i]
        st.vmean[i] = st.vv[i].toDouble()
        st.vsum[i] = 0.0
    }
    var tt = 1L
    while (tt < st.dtw) {
        if (getvec(st.vv) < n) return -1
        for (i in 0 until n) st.vmean[i] += st.vv[i].toDouble()
        tt++
    }

    if (isigsettime(t) < 0 || getvec(st.vv) < n) return -1

    // The quantity vv[i] - v0[i] is normally zero, but may be non-zero if
    // the signals are stored in difference format (since isigsettime may
    // introduce a DC error in this case). In the calculation of vmean[i]
    // below, this quantity is used to correct any such error.
    for (i in 0 until n) {
        st.vmean[i] = st.vmean[i] / st.dtw.toDouble() + st.vv[i].toDouble() - st.v0[i].toDouble()
        val v = d2i(st.vv[i].toDouble() - st.vmean[i])
        st.vsum[i] += v.toDouble() * v.toDouble()
    }

    tt = 1L
    while (tt < st.dtw) {
        if (getvec(st.vv) < n) return -1
        for (i in 0 until n) {
            val v = d2i(st.vv[i].toDouble() - st.vmean[i])
            st.vsum[i] += v.toDouble() * v.toDouble()
        }
        tt++
    }

    for (i in 0 until n) st.amp[i][st.namp] = sqrt(st.vsum[i] / st.dtw.toDouble())
    return 0
}

private fun Wfdb.getptp(st: SigampState, t: Long): Int {
    val n = st.nsig
    if (isigsettime(t + st.dt1) < 0) return -1
    if (getvec(st.vmin) < n) return -1
    st.vmin.copyInto(st.vmax, 0, 0, n)
    var tt = st.dt1
    while (tt < st.dt2) {
        if (getvec(st.vv) < n) return -1
        for (i in 0 until n) {
            if (st.vv[i] < st.vmin[i]) st.vmin[i] = st.vv[i]
            else if (st.vv[i] > st.vmax[i]) st.vmax[i] = st.vv[i]
        }
        tt++
    }
    for (i in 0 until n) st.amp[i][st.namp] = (st.vmax[i] - st.vmin[i]).toDouble()
    return 0
}

private fun Wfdb.printamp(st: SigampState, t: Long) {
    when (st.timeunits) {
        TIMSTR -> printf("%s", mstimstr(-t))
        HHMMSS -> printf("%s", mstimstr(t))
        SAMPLES -> printf("%lld", t)
        else -> printf("%lf", t.toDouble() / st.sfreq)
    }
    for (i in 0 until st.nsig) {
        val a = st.amp[i][st.namp]
        printf("\t%g", if (st.pflag) a / st.si[i].gain else a)
    }
    printf("\n")
}

/** The sigamp tool. */
fun Wfdb.sigampMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    var record: ByteArray? = null
    var ainame: ByteArray? = null
    var gvmode = 0
    var nmax = SIGAMP_NMAX
    var qflag = false
    var vflag = false
    var timeunits = SECONDS
    var pflag = false
    var dt1 = 0L
    var dtw = 0L
    var dt2: Long
    var from = 0L
    var to = 0L

    // Interpret command-line arguments.
    var i = 1
    while (i < argc) {
        val a = argv[i]
        if (a.at(0) == '-'.code) {
            when (a.at(1).toChar()) {
                'a' -> {
                    if (++i >= argc) {
                        eprintf("%s: annotator name must follow -a\n", pname)
                        exit(1)
                    }
                    ainame = argv[i]
                }
                'd' -> {
                    if (++i >= argc - 1) {
                        eprintf("%s: DT1 and DT2 must follow -d\n", pname)
                        exit(1)
                    }
                    // save arg list index, convert arguments to samples later
                    // (after record has been opened and sampling frequency is
                    // known)
                    dt1 = i.toLong()
                    i++
                }
                'f' -> {
                    if (++i >= argc) {
                        eprintf("%s: start time must follow -f\n", pname)
                        exit(1)
                    }
                    // save arg list index, convert argument to samples later
                    from = i.toLong()
                }
                'h' -> { // help requested
                    sigampHelp(pname)
                    exit(0)
                }
                'H' -> gvmode = WFDB_HIGHRES // operate in WFDB_HIGHRES mode
                'n' -> {
                    if (++i >= argc) {
                        eprintf("%s: number of measurements must follow -n\n", pname)
                        exit(1)
                    }
                    nmax = atoi(argv[i])
                    if (nmax < 1) nmax = SIGAMP_NMAX
                }
                'p' -> {
                    pflag = true
                    timeunits = when (a.at(2).toChar()) {
                        'd' -> TIMSTR
                        'e' -> HHMMSS
                        'h' -> HOURS
                        'm' -> MINUTES
                        'S' -> SAMPLES
                        else -> SECONDS
                    }
                }
                'q' -> qflag = true
                'r' -> {
                    if (++i >= argc) {
                        eprintf("%s: record name must follow -r\n", pname)
                        exit(1)
                    }
                    record = argv[i]
                }
                't' -> {
                    if (++i >= argc) {
                        eprintf("%s: stop time must follow -t\n", pname)
                        exit(1)
                    }
                    // save arg list index, convert argument to samples later
                    to = i.toLong()
                }
                'v' -> vflag = true
                'w' -> {
                    if (++i >= argc) {
                        eprintf("%s: window size must follow -w\n", pname)
                        exit(1)
                    }
                    // save arg list index, convert argument to samples later
                    dtw = i.toLong()
                }
                else -> {
                    eprintf("%s: unrecognized option %s\n", pname, a)
                    exit(1)
                }
            }
        } else {
            eprintf("%s: unrecognized argument %s\n", pname, a)
            exit(1)
        }
        i++
    }
    if (record == null) {
        sigampHelp(pname)
        exit(1)
    }

    // Finish initialization.
    if (gvmode == 0) {
        val p = getenv("WFDBGVMODE")
        if (p != null) gvmode = atoi(p)
    }
    setgvmode(gvmode or WFDB_GVPAD)

    val nsig = isigopen(record, null, 0)
    if (nsig <= 0) exit(2)
    val si = Array(nsig) { Siginfo() }
    if (isigopen(record, si, nsig) != nsig) exit(2)
    // WFDB-x: no default gain (the C program assumed 200 adu/mV for
    // uncalibrated signals, as legacy mode does).
    if (legacy) {
        for (s in si) if (s.gain == 0.0) s.gain = WFDB_DEFGAIN
    } else if (pflag) {
        val k = si.indexOfFirst { it.gain == 0.0 }
        if (k >= 0) {
            eprintf("%s: signal %d of record %s is uncalibrated\n", pname, k, record)
            exit(2)
        }
    }
    // WFDB-x: no default sampling frequency (the C program assumed 250 Hz,
    // as legacy mode does); the measurement windows are defined in seconds.
    var sfreq = sampfreq(null)
    if (sfreq <= 0.0 && legacy) {
        sfreq = WFDB_DEFFREQ
    } else if (sfreq <= 0.0) {
        eprintf("%s: sampling frequency of record %s is not specified\n", pname, record)
        exit(2)
    }

    // Adjust timeunits if starting time is undefined.
    if ((timeunits == TIMSTR || timeunits == HHMMSS) && timstr(0).at(0) != '['.code) timeunits = HHMMSS
    if (timeunits == HOURS) sfreq *= 3600.0
    else if (timeunits == MINUTES) sfreq *= 60.0

    if (from > 0) from = strtim(argv[from.toInt()])
    if (to > 0) to = strtim(argv[to.toInt()])
    if (from < 0) from = -from
    if (to < 0) to = -to
    if (from >= to) to = strtim("e")

    val st = SigampState(nsig, pflag, timeunits, nmax, sfreq, si)

    // Collect amplitudes, print them if qflag or vflag set.
    if (ainame != null) {
        // windows are relative to annotations
        val annot = Annotation()
        val ai = Anninfo(ainame, WFDB_READ)
        if (dtw > 0) {
            eprintf("%s: -a and -w options cannot be used together;\n", pname)
            eprintf("  -w option is being ignored\n")
        }
        if (annopen(record, arrayOf(ai), 1) < 0) exit(2)
        if (dt1 == 0L) {
            dt2 = strtim("0.05")
            dt1 = -dt2
        } else {
            var p = argv[dt1.toInt() + 1]
            dt2 = if (p.at(0) == '-'.code) -strtim(p.copyOfRange(1, p.size)) else strtim(p)
            p = argv[dt1.toInt()]
            dt1 = if (p.at(0) == '-'.code) strtim(p.copyOfRange(1, p.size)) else -strtim(p)
            if (dt1 > dt2) {
                val x = dt1
                dt1 = dt2
                dt2 = x
            }
        }
        if (dt1 == dt2) dt2++
        st.dt1 = dt1
        st.dt2 = dt2
        if (iannsettime(from) < 0) exit(2)
        while (getann(0, annot) == 0 && st.namp < nmax && (to == 0L || annot.time < to)) {
            if (wfdb_map1(annot.anntyp) == NORMAL) {
                if (getptp(st, annot.time) < 0) break
                if (vflag || qflag) printamp(st, annot.time)
                st.namp++
            }
        }
    } else {
        // windows are consecutive nonoverlapping segments
        if (dt1 > 0) {
            eprintf("%s: -d option must be used with -a;\n", pname)
            eprintf("  -d option is being ignored\n")
        }
        if (dtw != 0L) dtw = strtim(argv[dtw.toInt()])
        if (dtw <= 0) dtw = strtim("1")
        st.dtw = dtw
        if (from > 0 && isigsettime(from) < 0) exit(2)
        var t = from
        while (st.namp < nmax && (to == 0L || t < to)) {
            if (getrms(st, t) < 0) break
            if (vflag || qflag) printamp(st, t)
            st.namp++
            t += dtw
        }
    }

    // Calculate trimmed means of collected amplitudes unless -q option set.
    if (!qflag) {
        val namp = st.namp
        val jlow = namp / 20 // trim the smallest and largest 5%
        val jhigh = namp - jlow
        if (vflag) printf("Trimmed mean")
        for (k in 0 until nsig) {
            val amp = st.amp[k]
            amp.sort(0, namp)
            var a = 0.0
            for (j in jlow until jhigh) a += amp[j]
            if (jhigh == jlow) {
                a = NEG_NAN // 0.0/0.0 gives a negative NaN on x86
            } else {
                a /= (jhigh - jlow).toDouble()
            }
            printf("\t%g", if (st.pflag) a / st.si[k].gain else a)
        }
        printf("\n")
    }
    exit(0)
}

/** The NaN of 0.0/0.0 on x86 (sign bit set). */
private val NEG_NAN = Double.fromBits(-0x8000000000000L)
