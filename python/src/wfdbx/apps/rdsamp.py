"""rdsamp: print an arbitrary number of samples from each signal.

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of app/rdsamp.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: no built-in sampling frequency or gain: the sampling
frequency is required for time arguments, time columns and XML output (-X), and
the gain of each selected signal for physical units (-p, -P) (the original
assumed 250 Hz and 200 adu/mV); unspecified units are shown as "nd" (the
original showed "mV"); --legacy, as the first argument, restores the original
behavior. Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md
gives the reasons.

Original C program: app/rdsamp.c, WFDB Software Package 10.7.0.
  Copyright (C) 1983-2010 George B. Moody; revised 2017-2020 by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import math
import sys

import numpy as np

import wfdbx as w
from wfdbx._signal import getframes
from ._common import Output, Exit, eprintf, legacy, legacy_gains, run

SECONDS, MINUTES, HOURS, TIMSTR, MSTIMSTR, SHORTTIMSTR, HHMMSS, SAMPLES = \
    range(1, 9)

WFDBXMLPROLOG = (
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<?xml-stylesheet type=\"text/xsl\" href=\"wfdb.xsl\"?>\n"
    "<!DOCTYPE wfdbsampleset PUBLIC \"-//PhysioNet//DTD WFDB 1.0//EN\""
    " \"http://physionet.org/physiobank/database/XML/wfdb.dtd\">\n")

CHUNK = 4096            # frames read (and printed) per block

HELP = [
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -c          use CSV (comma-separated value) output format",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -l INTERVAL truncate output after the specified time interval "
    "(hh:mm:ss)",
    " -p          print times and samples in physical units (default: raw "
    "units)",
    " -P          same as -p, but with greater precision",
    "              -p and -P may be followed by a character to choose a time",
    "              format;  choices are:",
    "  -pd (or -Pd)  print time of day and date if known",
    "  -pe (or -Pe)  print elapsed time as <hours>:<minutes>:<seconds>",
    "  -ph (or -Ph)  print elapsed time in hours",
    "  -pm (or -Pm)  print elapsed time in minutes",
    "  -ps (or -Ps)  print elapsed time in seconds",
    "  -pS (or -PS)  print elapsed time in sample intervals",
    " -s SIGNAL [SIGNAL ...]  print only the specified signal(s)",
    " -S SIGNAL   search for a valid sample of the specified SIGNAL at or "
    "after",
    "\t\tthe time specified with -f, and begin printing then",
    " -t TIME     stop at specified time",
    " -v          print column headings",
    " -X          output in WFDB-XML format",
]


def help(pname):
    eprintf(HELP[0], pname)
    for s in HELP[1:]:
        eprintf("%s\n", s)


def escapify(s):
    """Escape quotes and backslashes for CSV column headings.

    (The C version of this function does not terminate for most strings
    that contain these characters; see docs/KNOWN_C_BEHAVIORS.md.)
    """
    return s.replace("\\", "\\\\").replace("'", "\\'")


def _main(argv, out):
    pname = argv[0]
    record = search = None
    cflag = highres = pflag = vflag = xflag = 0
    nosig = 0
    isiglist = 0
    timeunits = SECONDS
    from_i = maxl_i = to_i = 0
    argc = len(argv)
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "c":
                cflag = 1
            elif c == "f":
                i += 1
                if i >= argc:
                    eprintf("%s: time must follow -f\n", pname)
                    raise Exit(1)
                from_i = i
            elif c == "h":
                help(pname)
                raise Exit(0)
            elif c == "H":
                highres = 1
            elif c == "l":
                i += 1
                if i >= argc:
                    eprintf("%s: max output length must follow -l\n", pname)
                    raise Exit(1)
                maxl_i = i
            elif c in ("P", "p"):
                pflag += 2 if c == "P" else 1
                d = a[2:3]
                timeunits = {"d": TIMSTR, "e": HHMMSS, "h": HOURS,
                             "m": MINUTES, "S": SAMPLES}.get(d, SECONDS)
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            elif c == "s":
                isiglist = i + 1
                while i + 1 < argc and not argv[i + 1].startswith("-"):
                    i += 1
                    nosig += 1
                if nosig == 0:
                    eprintf("%s: signal list must follow -s\n", pname)
                    raise Exit(1)
            elif c == "S":
                i += 1
                if i >= argc:
                    eprintf("%s: signal name or number must follow -S\n",
                            pname)
                    raise Exit(1)
                search = argv[i]
            elif c == "t":
                i += 1
                if i >= argc:
                    eprintf("%s: time must follow -t\n", pname)
                    raise Exit(1)
                to_i = i
            elif c == "v":
                vflag = 1
            elif c == "X":
                xflag = cflag = vflag = 1
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
    nsig = w.isigopen(record, None, 0)
    if nsig <= 0:
        raise Exit(2)
    si = []
    nsig = w.isigopen(record, si, nsig)
    if nsig <= 0:
        raise Exit(2)
    if legacy():    # wfdb-x: the C program's default gain
        legacy_gains(si)
    if highres:
        w.setgvmode(w.WFDB_HIGHRES)
    freq = w.sampfreq(None)
    # wfdb-x: no default sampling frequency (C assumed 250 Hz if the header
    # did not specify one, as legacy mode does).
    if not legacy() and freq <= 0.0 and (
            (from_i > 0 and w.wfdbx_time_needs_freq(argv[from_i])) or
            (to_i > 0 and w.wfdbx_time_needs_freq(argv[to_i])) or
            (maxl_i > 0 and w.wfdbx_time_needs_freq(argv[maxl_i])) or
            xflag or (pflag and (timeunits != SAMPLES or vflag))):
        eprintf("%s: sampling frequency of record %s is not specified\n",
                pname, record)
        raise Exit(2)
    frm = 0
    if from_i > 0:
        frm = w.strtim(argv[from_i])
        if frm < 0:
            frm = -frm
    if w.isigsettime(frm) < 0:
        raise Exit(2)
    to = 0
    if to_i > 0:
        to = w.strtim(argv[to_i])
        if to < 0:
            to = -to
    if nosig:
        sig = []
        for k in range(nosig):
            s = w.findsig(argv[isiglist + k])
            if s < 0:
                eprintf("%s: can't read signal '%s'\n", pname,
                        argv[isiglist + k])
                raise Exit(2)
            sig.append(s)
        nsig = nosig
    else:
        sig = list(range(nsig))
    # wfdb-x: no default gain (C assumed 200 adu/mV for uncalibrated
    # signals, as legacy mode does).
    if pflag and not legacy():
        for k in range(nsig):
            if si[sig[k]].gain == 0.0:
                eprintf("%s: signal %d of record %s is uncalibrated\n",
                        pname, sig[k], record)
                raise Exit(2)
    if search is not None:
        s = w.findsig(search)
        if s >= 0:
            frm = w.tnextvec(s, frm)
        if s < 0 or frm < 0:
            eprintf("%s: can't read signal '%s'\n", pname, search)
            raise Exit(2)
    maxl = 0
    if maxl_i > 0:
        maxl = w.strtim(argv[maxl_i])
        if maxl < 0:
            maxl = -maxl
    if maxl and (to == 0 or to > frm + maxl):
        to = frm + maxl
    if timeunits == TIMSTR:
        p = w.timstr(0)
        if not p.startswith("["):
            timeunits = HHMMSS
        elif len(p) < 16:
            timeunits = SHORTTIMSTR
        elif freq > 1.0:
            timeunits = MSTIMSTR
    if timeunits == HOURS:
        freq *= 3600.0
    elif timeunits == MINUTES:
        freq *= 60.0
    tufmt = tnfmt = tfmt = vfmt = invalid = snfmt = None
    # sampling interval (inf, as in C, if the frequency is not specified;
    # it is then not printed)
    speriod_s = 1.0 / freq if freq != 0.0 else math.inf
    if cflag:
        snfmt = ",'%s'"
        if pflag:
            if timeunits == SAMPLES:
                tnfmt = "'sample interval'"
                tufmt = "'%g sec'" % speriod_s
            elif timeunits == SHORTTIMSTR:
                tnfmt, tufmt = "'Time'", "'hh:mm:ss.mmm'"
            elif timeunits == TIMSTR:
                tnfmt, tufmt = "'Time and date'", "'hh:mm:ss dd/mm/yyyy'"
            elif timeunits == MSTIMSTR:
                tnfmt, tufmt = "'Time and date'", "'hh:mm:ss.mmm dd/mm/yyyy'"
            elif timeunits == HHMMSS:
                tnfmt, tufmt = "'Elapsed time'", "'hh:mm:ss.mmm'"
            elif timeunits == HOURS:
                tnfmt, tufmt = "'Elapsed time'", "'hours'"
            elif timeunits == MINUTES:
                tnfmt, tufmt = "'Elapsed time'", "'minutes'"
            else:
                tnfmt, tufmt = "'Elapsed time'", "'seconds'"
            invalid = ",-"
            vfmt = ",%.8f" if pflag > 1 else ",%.3f"
        else:
            tnfmt = "'sample #'"
            tfmt = "%d"
            vfmt = ",%d"
    else:
        if pflag:
            if timeunits == SAMPLES:
                tnfmt = "sample interval"
                speriod = ("(%g" % speriod_s)[:10]
                tufmt = "%10s sec)" % speriod
            elif timeunits == SHORTTIMSTR:
                tnfmt, tufmt = "     Time", "(hh:mm:ss.mmm)"
            elif timeunits == TIMSTR:
                tnfmt, tufmt = "   Time      Date    ", \
                    "(hh:mm:ss dd/mm/yyyy)"
            elif timeunits == MSTIMSTR:
                tnfmt, tufmt = "      Time      Date    ", \
                    "(hh:mm:ss.mmm dd/mm/yyyy)"
            elif timeunits == HHMMSS:
                tnfmt, tufmt = "   Elapsed time", "   hh:mm:ss.mmm"
            elif timeunits == HOURS:
                tnfmt, tufmt = "   Elapsed time", "        (hours)"
            elif timeunits == MINUTES:
                tnfmt, tufmt = "   Elapsed time", "      (minutes)"
            else:
                tnfmt, tufmt = "   Elapsed time", "      (seconds)"
            if pflag > 1:
                snfmt = "\t%15s"
                invalid = "\t              -"
                vfmt = "\t%15.8f"
            else:
                snfmt = "\t%7s"
                invalid = "\t      -"
                vfmt = "\t%7.3f"
        else:
            snfmt = "\t%7s"
            tnfmt = "       sample #"
            tfmt = "%15d"
            vfmt = "\t%7d"
    if xflag:
        out.write(WFDBXMLPROLOG)
        out.write("<wfdbsampleset>\n"
                  "<samplingfrequency>%g</samplingfrequency>\n"
                  "<signals>%d</signals>\n<description>" % (freq, nsig))
    if vflag:
        out.write(tnfmt)
        for k in range(nsig):
            p = si[sig[k]].desc
            if ", signal " in p:
                p = "sig %d" % sig[k]
            if cflag == 0:      # keep the end of p, to fit the column
                ln = len(p)
                if pflag > 1:
                    if ln > 15:
                        p = p[ln - 15:]
                else:
                    if ln > 7:
                        p = p[ln - 7:]
            else:
                p = escapify(p)
            out.write(snfmt % p)
        if xflag:
            out.write("</description>")
        out.write("\n")
    if pflag:
        if vflag:
            if xflag:
                out.write("<units>")
            out.write(tufmt)
            for k in range(nsig):
                p = si[sig[k]].units
                if p is None:   # wfdb-x: shown as "nd" (C, legacy mode: mV)
                    p = "mV" if legacy() else "nd"
                if cflag == 0:  # "(units)" must fit the column
                    ln = len(p)
                    if pflag > 1:
                        if ln > 13:
                            ln = 13
                    elif ln > 5:
                        ln = 5
                    ustring = "(" + p[:ln]
                    out.write(("\t%14s)" if pflag > 1 else "\t%6s)") % ustring)
                else:
                    out.write(",'%s'" % escapify(p))
            if xflag:
                out.write("</units>")
            out.write("\n")
        if xflag:
            out.write("<samplevectors>\n")
        base = np.array([float(si[s].baseline) for s in sig])
        gain = np.array([si[s].gain for s in sig])
        if cflag == 0:
            if timeunits == TIMSTR:
                tsf = lambda t: w.timstr(-t)
            elif timeunits in (SHORTTIMSTR, MSTIMSTR):
                tsf = lambda t: w.mstimstr(-t)
            elif timeunits == HHMMSS:
                tsf = lambda t: "%15s" % ("0:00.000" if t == 0
                                          else w.mstimstr(t))
            else:
                tsf = None
                tfmt = {SAMPLES: "%15d", MINUTES: "%15.5f",
                        HOURS: "%15.7f"}.get(timeunits, "%15.3f")
        else:
            if timeunits == TIMSTR:
                tsf = lambda t: "'%s'" % w.timstr(-t).lstrip(" ")
            elif timeunits in (SHORTTIMSTR, MSTIMSTR):
                tsf = lambda t: "'%s'" % w.mstimstr(-t).lstrip(" ")
            elif timeunits == HHMMSS:
                tsf = lambda t: "'0:00.000'" if t == 0 else \
                    "'%s'" % w.mstimstr(t).lstrip(" ")
            else:
                tsf = None
                tfmt = {SAMPLES: "%d", MINUTES: "%.5f",
                        HOURS: "%.7f"}.get(timeunits, "%.3f")
        while to == 0 or frm < to:
            k = CHUNK if to == 0 else min(CHUNK, to - frm)
            arr, stat = getframes(k)
            m = len(arr)
            if m:
                t = np.arange(frm, frm + m)
                if tsf is not None:
                    tcol = [tsf(int(x)) for x in t]
                elif timeunits == SAMPLES:
                    tcol = [tfmt % x for x in t.tolist()]
                else:
                    tcol = [tfmt % x for x in (t / freq).tolist()]
                sel = arr[:, sig]
                phys = (sel.astype(np.float64) - base) / gain
                inv = sel == w.WFDB_INVALID_SAMPLE
                obj = np.empty((m, nsig + 1), object)
                obj[:, 0] = tcol
                if inv.any():
                    vals = [[invalid if bad else vfmt % x
                             for x, bad in zip(row, irow)]
                            for row, irow in zip(phys.tolist(),
                                                 inv.tolist())]
                    obj[:, 1:] = vals
                    lfmt = "%s" * (nsig + 1) + "\n"
                else:
                    obj[:, 1:] = phys
                    lfmt = "%s" + vfmt * nsig + "\n"
                out.write((lfmt * m) % tuple(obj.ravel().tolist()))
                frm += m
            if m < k:
                break
    else:
        if xflag:
            out.write("<samplevectors>\n")
        lfmt = tfmt + (vfmt * nsig) + "\n"
        while to == 0 or frm < to:
            k = CHUNK if to == 0 else min(CHUNK, to - frm)
            arr, stat = getframes(k)
            m = len(arr)
            if m:
                obj = np.empty((m, nsig + 1), np.int64)
                obj[:, 0] = np.arange(frm, frm + m)
                obj[:, 1:] = arr[:, sig]
                out.write((lfmt * m) % tuple(obj.ravel().tolist()))
                frm += m
            if m < k:
                break
    if xflag:
        out.write("</samplevectors>\n</wfdbsampleset>\n")
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run rdsamp as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["rdsamp"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["rdsamp"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
