"""rr2ann: convert a series of RR intervals to an annotation file.

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of app/rr2ann.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: no built-in sampling frequency: -F FREQ is required
when the record has no header or its header gives none (the original assumed
250 Hz); --legacy, as the first argument, restores the original behavior. Each
change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.

Original C program: app/rr2ann.c, WFDB Software Package 10.7.0.
  Copyright (C) 2000 George B. Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

import wfdbx as w
from wfdbx._cstd import atof, fgets_lines, sscanf
from ._common import Exit, eprintf, legacy, legacy_help, run

MAXLINELEN = 1024       # longer input lines are silently split

HELP = [
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...] <TEXT-FILE\n",
    "where RECORD and ANNOTATOR specify the output, and OPTIONS may include:",
    " -F FREQ     use FREQ as the sampling frequency (effective only if the"
    "               header file does not exist or does not specify it)",
    " -h          print this usage summary",
    " -T          TEXT-FILE contains times of occurrence, not RR intervals",
    " -x N        multiply input by N to obtain RR in sample intervals",
    "               (default: N = 1)",
    " -w          copy annotation types from second column of input",
    "TEXT-FILE should contain a column of RR intervals (or times of "
    "occurrence,",
    "if the -T option is specified), in units of sample intervals (unless the",
    "-x option is used to specify a conversion factor).   The first token on",
    "each line is taken as an RR interval, and (if the -w option is "
    "specified)",
    "the second token is taken as an annotation mnemonic (N, V, etc.);  "
    "anything",
    "else on the same line is ignored, as are empty lines, spaces and tabs at",
    "the beginning of a line non-numeric tokens and anything following them "
    "on",
    "the same line, negative intervals, and zero intervals.  The output "
    "consists",
    "of a binary annotation file (RECORD.ANNOTATOR), and (if it does not "
    "exist",
    "already) a text header file (RECORD.hea).",
]

# wfdb-x: the help text of the original program, printed in legacy mode
LEGACY_HELP = legacy_help(HELP, {
    " -F FREQ     use FREQ as the sampling frequency (effective only if the"
    "               header file does not exist or does not specify it)":
    " -F FREQ     use FREQ as the sampling frequency (effective only if no"
    "               header file exists;  default: 250)"})


def help(pname):
    hs = LEGACY_HELP if legacy() else HELP     # wfdb-x
    eprintf(hs[0], pname)
    for s in hs[1:]:
        eprintf("%s\n", s)


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    record = ainame = None
    sps = 0.0
    t = 0.0
    xfactor = 1.0
    Tflag = wflag = 0
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
            elif c == "F":
                i += 1
                if i < argc:
                    sps = atof(argv[i])
                if i >= argc or sps <= 0.0:
                    eprintf("%s: sampling frequency (> 0) must follow -F\n",
                            pname)
                    raise Exit(1)
            elif c == "h":
                help(pname)
                raise Exit(0)
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            elif c == "T":
                Tflag = 1
            elif c == "x":
                i += 1
                if i < argc:
                    xfactor = atof(argv[i])
                if i >= argc or xfactor <= 0.0:
                    eprintf("%s: an input multiplier (> 0) must follow -x\n",
                            pname)
                    raise Exit(1)
            elif c == "w":
                wflag = 1
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
    w.wfdbquiet()
    # wfdb-x: no default sampling frequency (C assumed 250 Hz); -F specifies
    # one if the record header does not.
    f = w.sampfreq(record)
    if f <= 0.0:
        w.wfdbverbose()
        if sps == 0.0 and legacy():
            sps = w.WFDB_DEFFREQ    # wfdb-x: legacy mode (original behavior)
        elif sps == 0.0:
            eprintf("%s: sampling frequency of record %s is not specified "
                    "(use -F)\n", pname, record)
            raise Exit(1)
        w.setsampfreq(sps)
        # no header: create one (the C program: in any case)
        if (f < 0.0 or legacy()) and w.newheader(record) < 0:
            raise Exit(2)
    else:
        w.wfdbverbose()
        if sps != 0.0:
            eprintf("%s (warning): -F option ignored (using %g for sampling "
                    "frequency)\n", pname, w.sampfreq(None))
    if w.annopen(record, [w.Anninfo(ainame, w.WFDB_WRITE)], 1) < 0:
        raise Exit(3)
    annot = w.Annotation(anntyp=w.NORMAL)
    rr = 0.0
    data = sys.stdin.buffer.read()
    for line in fgets_lines(data, MAXLINELEN):
        if not wflag:
            n, v = sscanf(line, "%lf")
            if n == 0:
                continue
            if n > 0:
                rr = v[0]
        else:
            n, v = sscanf(line, "%lf%s")
            if v:
                rr = v[0]
            if n < 2:
                continue
            annot.anntyp = w.strann(v[1])
            if annot.anntyp == w.NOTQRS:
                continue
        if rr <= 0.0:
            continue
        elif Tflag:
            t = rr * xfactor
        else:
            t += rr * xfactor
        annot.time = int(t + 0.5)
        w.putann(0, annot)
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run rr2ann as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["rr2ann"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["rr2ann"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
