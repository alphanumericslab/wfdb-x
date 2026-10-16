"""ann2rr: extract a list of intervals from an annotation file.

Copyright (C) 1995-2009 George B. Moody (original C program, app/ann2rr.c;
revised 2018-2020 by Benjamin Moody).
Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency, gain,
ADC resolution or units. Values that the record or the user does not give are
never assumed (the original package assumed 250 Hz, 200 adu/mV, 12 bits and
millivolts), because a silently assumed value corrupts every result derived
from it. See docs/DIVERGENCES.md.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import sys

import wfdbx as w
from wfdbx._cstd import sscanf, int32
from ._common import (Output, Exit, eprintf, eprint, freq_not_specified,
                      freq_option, legacy, legacy_help, legacy_sampfreq,
                      run)

HELP = [
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -A      print all intervals between annotations (default: print only RR",
    "          intervals; overrides -c, -p)",
    " -c      print intervals between consecutive valid annotations only",
    " -f TIME start at specified TIME",
    " -F FREQ sampling frequency, if the record header does not specify one",
    " -h      print this usage summary",
    " -i FMT  print intervals using format FMT (see below for values of FMT)",
    " -p TYPE [TYPE ...]  print intervals ending with annotations of "
    "specified",
    "                      TYPEs only (use mnemonics such as N or V for TYPE)",
    " -P TYPE [TYPE ...]  print intervals beginning with specified types only",
    " -t TIME stop at specified TIME",
    " -v FMT  print times of ends of intervals using format FMT (see below)",
    " -V FMT  print times of beginnings of intervals using format FMT (see "
    "below)",
    " -w      print annotations that end intervals",
    " -W      print annotations that begin intervals",
    "By default, the output contains the RR intervals only, unless one or more",
    "of -v, -V, -w, or -W are used.  Intervals and times are printed in units "
    "of",
    "sample intervals, unless a format is specified using -i, -v, or -V.",
    "Formats can be 'h' (hours), 'm' (minutes), 's' (seconds), 't' "
    "(hh:mm:ss);",
    "when used with -v or -V, format 'T' yields dates and times if available,",
    "or the format can be omitted to obtain times in sample intervals.  "
    "Formats",
    "'h', 'm', and 's' may be followed by a number between 0 and 15, "
    "specifying",
    "the number of decimal places (default: 3).  For example, to obtain "
    "intervals",
    "in seconds with 8 decimal places, use '-i s8'.",
]

# wfdb-x: the help text of the original program, printed in legacy mode
LEGACY_HELP = legacy_help(HELP, {
    " -F FREQ sampling frequency, if the record header does not specify one":
    None})


def help(pname):
    hs = LEGACY_HELP if legacy() else HELP     # wfdb-x
    eprintf(hs[0], pname)
    for i in range(1, len(hs)):
        eprintf("%s\n", hs[i])
        if i % 23 == 0:         # pause after each screenful, as C does
            eprint("--More--")
            try:
                sys.stdin.buffer.readline(4)    # fgets(b, 5, stdin)
            except (OSError, ValueError):
                pass
            eprint("\033[A\033[2K")


def _digits(arg, default):
    n, v = sscanf(arg[1:], "%d")
    return int32(v[0]) if n == 1 else default


def _flag(table, a):
    return table[a] if 0 <= a < len(table) else 0


def _time_format_needs_freq(c):
    """wfdb-x: return True if output format c (for -i, -v or -V) is a unit
    of time, which needs the sampling frequency."""
    return c in ("h", "m", "s", "t", "T")


def _main(argv, out):
    pname = argv[0]
    argc = len(argv)
    record = ainame = None
    Aflag = a0flag = a1flag = cflag = 0
    previous_annot_valid = 0
    rrdigits = t0digits = t1digits = 3
    rrformat = t0format = t1format = ""
    t0flag = t1flag = 0
    a0f = [0] * (w.ACMAX + 1)
    a1f = [0] * (w.ACMAX + 1)
    a0f[0] = a1f[0] = 1
    frm = to = 0
    ffreq = 0.0
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "a":
                i += 1
                if i >= argc:
                    eprintf("%s: annotator must follow -a\n", pname)
                    raise Exit(1)
                ainame = argv[i]
            elif c == "A":
                Aflag = 1
            elif c == "c":
                cflag = 1
            elif c == "f":
                i += 1
                if i >= argc:
                    eprintf("%s: starting time must follow -f\n", pname)
                    raise Exit(1)
                frm = i
            elif c == "F" and not legacy():    # sampling frequency (wfdb-x)
                i += 1
                ffreq = freq_option(argv, i, pname)
            elif c == "h":
                help(pname)
                raise Exit(0)
            elif c == "i":
                i += 1
                if i >= argc or argv[i].startswith("-"):
                    eprintf("%s: interval output format must follow -i\n",
                            pname)
                    raise Exit(1)
                rrformat = argv[i][:1]
                rrdigits = _digits(argv[i], rrdigits)
            elif c in ("p", "P"):
                tbl = a1f if c == "p" else a0f
                i += 1
                j = w.strann(argv[i]) if i < argc else 0
                if i >= argc or not w.isann(j):
                    eprintf("%s: annotation mnemonic(s) must follow -%s\n",
                            pname, "P" if c == "p" else "p")
                    raise Exit(1)
                tbl[j] = 1
                i += 1
                while i < argc and not argv[i].startswith("-"):
                    j = w.strann(argv[i])
                    if w.isann(j):
                        tbl[j] = 1
                    i += 1
                if i == argc or argv[i].startswith("-"):
                    i -= 1
                tbl[0] = 0
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: input record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            elif c == "t":
                i += 1
                if i >= argc:
                    eprintf("%s: end time must follow -t\n", pname)
                    raise Exit(1)
                to = i
            elif c in ("v", "V"):
                if c == "v":
                    t1flag = 1
                else:
                    t0flag = 1
                i += 1
                if i >= argc or argv[i].startswith("-"):
                    i -= 1
                elif c == "v":
                    t1format = argv[i][:1]
                    t1digits = _digits(argv[i], t1digits)
                else:
                    t0format = argv[i][:1]
                    t0digits = _digits(argv[i], t0digits)
            elif c == "w":
                a1flag = 1
            elif c == "W":
                a0flag = 1
            else:
                eprintf("%s: unrecognized option %s\n", pname, a)
                raise Exit(1)
        else:
            eprintf("%s: unrecognized argument %s\n", pname, a)
            raise Exit(1)
        i += 1
    if record is None or ainame is None:
        help(pname)
        raise Exit(1)
    # wfdb-x: no default sampling frequency (C assumed 250 Hz if the record
    # had no header); -F specifies one.  It is needed for times and
    # intervals in units of time.
    # Legacy mode: as in the C program.
    if legacy():
        sps = legacy_sampfreq(record)
    else:
        sps = w.sampfreq(record)
    if sps <= 0.0 and ffreq > 0.0:
        sps = ffreq
        w.setsampfreq(sps)
    if sps <= 0.0 and not legacy() and (
            (frm and w.wfdbx_time_needs_freq(argv[frm])) or
            (to and w.wfdbx_time_needs_freq(argv[to])) or
            _time_format_needs_freq(rrformat) or
            (t0flag and _time_format_needs_freq(t0format)) or
            (t1flag and _time_format_needs_freq(t1format))):
        freq_not_specified(pname, record, use_f=True)
        raise Exit(1)
    spm = 60.0 * sps
    sph = 60.0 * spm
    if w.annopen(record, [w.Anninfo(ainame, w.WFDB_READ)], 1) < 0:
        raise Exit(2)
    if rrdigits < 0 or rrdigits > 15:   # 0-15 decimal places (see help)
        rrdigits = 3
    rrfstr = "%%.%df" % rrdigits
    if t0digits < 0 or t0digits > 15:
        t0digits = 3
    t0fstr = "%%.%df" % t0digits
    if t1digits < 0 or t1digits > 15:
        t1digits = 3
    t1fstr = "%%.%df" % t1digits
    if frm:
        frm = w.strtim(argv[frm])
        if frm < 0:
            frm = -frm
    if to:
        to = w.strtim(argv[to])
        if to < 0:
            to = -to
    if to > 0 and to < frm:
        frm, to = to, frm
    if frm > 0 and w.iannsettime(frm) < 0:
        raise Exit(2)
    a0 = w.NOTQRS
    t0 = frm
    annot = w.Annotation()
    mstimstr = w.mstimstr
    annstr = w.annstr
    isqrs = w.isqrs
    while w.getann(0, annot) == 0 and (to == 0 or annot.time <= to):
        a1 = annot.anntyp
        t1 = annot.time
        if Aflag or (a1f[0] and isqrs(a1)) or _flag(a1f, a1):
            if cflag == 0 or previous_annot_valid == 1:
                if t0flag:
                    if t0format == "h":
                        out.write(t0fstr % (t0 / sph))
                    elif t0format == "m":
                        out.write(t0fstr % (t0 / spm))
                    elif t0format == "s":
                        out.write(t0fstr % (t0 / sps))
                    elif t0format == "t":
                        out.write("    0:00.000" if t0 == 0 else mstimstr(t0))
                    elif t0format == "T":
                        out.write(mstimstr(-t0))
                    else:
                        out.write("%d" % t0)
                    out.write("\t")
                if a0flag:
                    if a0 == w.NOTQRS:
                        out.write("[0]\t")
                    else:
                        out.write("%s\t" % annstr(a0))
                rr = t1 - t0
                if rrformat in ("h", "m", "s"):
                    unit = {"h": sph, "m": spm, "s": sps}[rrformat]
                    rrstr = (rrfstr % (rr / unit))[:19]  # C: char rrstr[20]
                    out.write(rrstr)
                    n, v = sscanf(rrstr, "%lf")
                    frr = v[0] if n == 1 else 0.0
                    t1 = int(t0 + frr * unit + 0.5)
                elif rrformat == "t":
                    out.write(mstimstr(t1))
                else:
                    out.write("%d" % rr)
                if a1flag:
                    out.write("\t%s" % annstr(a1))
                if t1flag:
                    out.write("\t")
                    if t1format == "h":
                        out.write(t1fstr % (t1 / sph))
                    elif t1format == "m":
                        out.write(t1fstr % (t1 / spm))
                    elif t1format == "s":
                        out.write(t1fstr % (t1 / sps))
                    elif t1format == "t":
                        out.write(mstimstr(t1))
                    elif t1format == "T":
                        out.write(mstimstr(-t1))
                    else:
                        out.write("%d" % t1)
                out.write("\n")
        if Aflag or (a0f[0] and isqrs(a1)) or _flag(a0f, a1):
            a0 = a1
            t0 = t1
            previous_annot_valid = 1
        elif cflag:
            previous_annot_valid = 0
    return 0


def main(argv=None):
    """Run ann2rr as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["ann2rr"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["ann2rr"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
