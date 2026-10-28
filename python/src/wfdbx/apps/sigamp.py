"""sigamp: measure signal amplitudes.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of app/sigamp.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: no built-in sampling frequency or gain: the record
must give the sampling frequency (the measurement windows are in seconds), and
with -p the gain of each signal (the original assumed 250 Hz and 200 adu/mV);
--legacy, as the first argument, restores the original behavior. Each change is
marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.

Original C program: app/sigamp.c, WFDB Software Package 10.7.0.
  Copyright (C) 1991-2009 George B. Moody; revised 2018 by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import math
import os
import sys

import wfdbx as w
from wfdbx._cstd import atoi, d2i, cfmt_float
from ._common import Output, Exit, eprintf, legacy, legacy_gains, run

NMAX = 300              # default maximum number of measurements per signal
SECONDS, MINUTES, HOURS, TIMSTR, MSTIMSTR, SHORTTIMSTR, HHMMSS, SAMPLES = \
    range(1, 9)

HELP = [
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where OPTIONS may include any of:",
    " -a ANN      specify annotator, measure amplitudes near QRS annotations",
    " -d DT1 DT2  set measurement window relative to QRS annotations",
    "              defaults: DT1 = 0.05 (seconds before annotation);",
    "              DT2 = 0.05 (seconds after annotation)",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -n NMAX     make up to NMAX measurements per signal (default: NMAX = "
    "300)",
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
    " -v          verbose mode: print individual measurements and trimmed "
    "means",
    " -w DTW      set RMS amplitude measurement window",
    "              default: DTW = 1 (second)",
]


def help(pname):
    eprintf(HELP[0], pname)
    for s in HELP[1:]:
        eprintf("%s\n", s)


def _main(argv, out):
    pname = argv[0]
    argc = len(argv)
    ainame = record = None
    dt1 = dt2 = dtw = 0
    frm = to = 0
    gvmode = 0
    nmax = NMAX
    pflag = qflag = vflag = 0
    timeunits = SECONDS
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "a":
                i += 1
                if i >= argc:
                    eprintf("%s: annotator name must follow -a\n", pname)
                    raise Exit(1)
                ainame = argv[i]
            elif c == "d":
                i += 1
                if i >= argc - 1:
                    eprintf("%s: DT1 and DT2 must follow -d\n", pname)
                    raise Exit(1)
                dt1 = i
                i += 1
            elif c == "f":
                i += 1
                if i >= argc:
                    eprintf("%s: start time must follow -f\n", pname)
                    raise Exit(1)
                frm = i
            elif c == "h":
                help(pname)
                raise Exit(0)
            elif c == "H":
                gvmode = w.WFDB_HIGHRES
            elif c == "n":
                i += 1
                if i >= argc:
                    eprintf("%s: number of measurements must follow -n\n",
                            pname)
                    raise Exit(1)
                nmax = atoi(argv[i])
                if nmax < 1:
                    nmax = NMAX
            elif c == "p":
                pflag = 1
                timeunits = {"d": TIMSTR, "e": HHMMSS, "h": HOURS,
                             "m": MINUTES, "S": SAMPLES}.get(a[2:3], SECONDS)
            elif c == "q":
                qflag = 1
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            elif c == "t":
                i += 1
                if i >= argc:
                    eprintf("%s: stop time must follow -t\n", pname)
                    raise Exit(1)
                to = i
            elif c == "v":
                vflag = 1
            elif c == "w":
                i += 1
                if i >= argc:
                    eprintf("%s: window size must follow -w\n", pname)
                    raise Exit(1)
                dtw = i
            else:
                eprintf("%s: unrecognized option %s\n", pname, a)
                raise Exit(1)
        else:
            eprintf("%s: unrecognized argument %s\n", pname, a)
            raise Exit(1)
        i += 1
    if record is None:
        help(pname)
        raise Exit(1)
    if gvmode == 0:
        p = os.environ.get("WFDBGVMODE")
        if p is not None:
            gvmode = atoi(p)
    w.setgvmode(gvmode | w.WFDB_GVPAD)
    nsig = w.isigopen(record, None, 0)
    if nsig <= 0:
        raise Exit(2)
    si = []
    if w.isigopen(record, si, nsig) != nsig:
        raise Exit(2)
    # WFDB-x: no default gain (C assumed 200 adu/mV for uncalibrated
    # signals, as legacy mode does).
    if legacy():
        legacy_gains(si)
    for k, s in enumerate(si):
        if pflag and s.gain == 0.0:
            eprintf("%s: signal %d of record %s is uncalibrated\n", pname, k,
                    record)
            raise Exit(2)
    amp = [[0.0] * nmax for _ in range(nsig)]
    # WFDB-x: no default sampling frequency (C assumed 250 Hz); the
    # measurement windows are defined in seconds.
    sfreq = w.sampfreq(None)
    if sfreq <= 0.0 and legacy():
        sfreq = w.WFDB_DEFFREQ
    elif sfreq <= 0.0:
        eprintf("%s: sampling frequency of record %s is not specified\n",
                pname, record)
        raise Exit(2)
    if timeunits in (TIMSTR, HHMMSS):
        if not w.timstr(0).startswith("["):
            timeunits = HHMMSS
    if timeunits == HOURS:
        sfreq *= 3600.0
    elif timeunits == MINUTES:
        sfreq *= 60.0
    if frm > 0:
        frm = w.strtim(argv[frm])
    if to > 0:
        to = w.strtim(argv[to])
    if frm < 0:
        frm = -frm
    if to < 0:
        to = -to
    if frm >= to:
        to = w.strtim("e")
    vv = [0] * nsig
    namp = 0

    def printamp(t):
        if timeunits == TIMSTR:
            out.write(w.mstimstr(-t))
        elif timeunits == HHMMSS:
            out.write(w.mstimstr(t))
        elif timeunits == SAMPLES:
            out.write("%d" % t)
        else:
            out.write(cfmt_float("%f", t / sfreq))
        for k in range(nsig):
            x = amp[k][namp] / si[k].gain if pflag else amp[k][namp]
            out.write("\t" + cfmt_float("%g", x))
        out.write("\n")

    if ainame is not None:
        if dtw > 0:
            eprintf("%s: -a and -w options cannot be used together;\n", pname)
            eprintf("  -w option is being ignored\n")
        if w.annopen(record, [w.Anninfo(ainame, w.WFDB_READ)], 1) < 0:
            raise Exit(2)
        if dt1 == 0:
            dt2 = w.strtim("0.05")
            dt1 = -dt2
        else:
            p = argv[dt1 + 1]
            dt2 = -w.strtim(p[1:]) if p.startswith("-") else w.strtim(p)
            p = argv[dt1]
            dt1 = w.strtim(p[1:]) if p.startswith("-") else -w.strtim(p)
            if dt1 > dt2:
                dt1, dt2 = dt2, dt1
        if dt1 == dt2:
            dt2 += 1
        if w.iannsettime(frm) < 0:
            raise Exit(2)
        annot = w.Annotation()
        vmin = [0] * nsig
        while w.getann(0, annot) == 0 and namp < nmax and \
                (to == 0 or annot.time < to):
            if w.map1(annot.anntyp) == w.NORMAL:
                # getptp()
                t = annot.time
                if w.isigsettime(t + dt1) < 0 or w.getvec(vmin) < nsig:
                    break
                vmax = list(vmin)
                ok = True
                tt = dt1
                while tt < dt2:
                    if w.getvec(vv) < nsig:
                        ok = False
                        break
                    for k in range(nsig):
                        if vv[k] < vmin[k]:
                            vmin[k] = vv[k]
                        elif vv[k] > vmax[k]:
                            vmax[k] = vv[k]
                    tt += 1
                if not ok:
                    break
                for k in range(nsig):
                    amp[k][namp] = float(vmax[k] - vmin[k])
                if vflag or qflag:
                    printamp(t)
                namp += 1
    else:
        if dt1 > 0:
            eprintf("%s: -d option must be used with -a;\n", pname)
            eprintf("  -d option is being ignored\n")
        if dtw != 0:
            dtw = w.strtim(argv[dtw])
        if dtw <= 0:
            dtw = w.strtim("1")
        if frm > 0 and w.isigsettime(frm) < 0:
            raise Exit(2)
        t = frm
        v0 = [0] * nsig
        vmean = [0.0] * nsig
        vsum = [0.0] * nsig
        while namp < nmax and (to == 0 or t < to):
            # getrms()
            if w.getvec(vv) < nsig:
                break
            for k in range(nsig):
                vmean[k] = float(vv[k])
                v0[k] = vv[k]
                vsum[k] = 0.0
            ok = True
            tt = 1
            while tt < dtw:
                if w.getvec(vv) < nsig:
                    ok = False
                    break
                for k in range(nsig):
                    vmean[k] += vv[k]
                tt += 1
            if not ok:
                break
            if w.isigsettime(t) < 0 or w.getvec(vv) < nsig:
                break
            for k in range(nsig):
                vmean[k] = vmean[k] / dtw + vv[k] - v0[k]
                v = d2i(vv[k] - vmean[k])
                vsum[k] += float(v) * v
            tt = 1
            while tt < dtw:
                if w.getvec(vv) < nsig:
                    ok = False
                    break
                for k in range(nsig):
                    v = d2i(vv[k] - vmean[k])
                    vsum[k] += float(v) * v
                tt += 1
            if not ok:
                break
            for k in range(nsig):
                amp[k][namp] = math.sqrt(vsum[k] / dtw)
            if vflag or qflag:
                printamp(t)
            namp += 1
            t += dtw
    if qflag == 0:
        jlow = namp // 20       # trim the lowest and highest 5%
        jhigh = namp - jlow
        if vflag:
            out.write("Trimmed mean")
        for k in range(nsig):
            vals = sorted(amp[k][:namp])
            a = 0.0
            for j in range(jlow, jhigh):
                a += vals[j]
            if jhigh - jlow == 0:
                a = -math.nan     # 0.0/0.0 yields a negative NaN on x86
            else:
                a /= jhigh - jlow
            out.write("\t" + cfmt_float("%g", a / si[k].gain if pflag
                                        else a))
        out.write("\n")
    return 0


def main(argv=None):
    """Run sigamp as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["sigamp"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["sigamp"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
