"""sortann: rearrange annotations in canonical order.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of app/sortann.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: no built-in sampling frequency: the new option -F
FREQ gives it when the record has no header or its header gives none, and is
then required for the -f and -t times (the original assumed 250 Hz); an
out-of-order annotation at time 0 (num 0, chan 0) is no longer lost, nor are
those inserted after it; --legacy, as the first argument, restores the original
behavior. Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md
gives the reasons.

Original C program: app/sortann.c, WFDB Software Package 10.7.0.
  Copyright (C) 1997-2010 George B. Moody; revised 2017-2018 by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import os
import sys

import wfdbx as w
from .._annot import _AnnList
from ._common import (Exit, eprintf, freq_not_specified, freq_option, legacy,
                      legacy_help, legacy_sampfreq, run)

HELP = [
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -f TIME    start at specified TIME",
    " -F FREQ    sampling frequency, if the record header does not specify one",
    " -h         print this usage summary",
    " -o OUTANN  write output as annotator OUTANN (required with -f or -t)",
    " -t TIME    stop at specified TIME",
    "The sorted output replaces the input if -o is omitted, the input is in",
    "the current directory, and the input is not already sorted.",
]

# WFDB-x: the help text of the original program, printed in legacy mode
LEGACY_HELP = legacy_help(HELP, {HELP[3]: None})     # (-F)


def help(pname):
    hs = LEGACY_HELP if legacy() else HELP     # WFDB-x
    eprintf(hs[0], pname)
    for s in hs[1:]:
        eprintf("%s\n", s)


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    record = None
    in_name = out_name = None
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
                in_name = argv[i]
            elif c == "f":
                i += 1
                if i >= argc:
                    eprintf("%s: starting time must follow -f\n", pname)
                    raise Exit(1)
                frm = i
            elif c == "F" and not legacy():    # sampling frequency (WFDB-x)
                i += 1
                ffreq = freq_option(argv, i, pname)
            elif c == "h":
                help(pname)
                raise Exit(0)
            elif c == "o":
                i += 1
                if i >= argc:
                    eprintf("%s: annotator must follow -o\n", pname)
                    raise Exit(1)
                out_name = argv[i]
            elif c == "r":
                if len(a) > 2:
                    w.setwfdb(a[2:])
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
            else:
                eprintf("%s: unrecognized option %s\n", pname, a)
                raise Exit(1)
        else:
            eprintf("%s: unrecognized argument %s\n", pname, a)
            raise Exit(1)
        i += 1
    if record is None or in_name is None:
        help(pname)
        raise Exit(1)
    if (frm or to) and out_name is None:
        eprintf("%s: -o required when using -f or -t options\n", pname)
        raise Exit(1)
    if out_name is not None and in_name == out_name:
        eprintf("%s: must specify different annotator names after -a and "
                "-o\n", pname)
        raise Exit(1)
    os.environ["WFDBANNSORT"] = "0"
    # WFDB-x: no default sampling frequency (C assumed 250 Hz if the record
    # had no header); -F specifies one.  It is needed only to convert the -f
    # and -t times.
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
            (to and w.wfdbx_time_needs_freq(argv[to]))):
        freq_not_specified(pname, record, use_f=True)
        raise Exit(1)
    if w.annopen(record, [w.Anninfo(in_name, w.WFDB_READ)], 1) < 0:
        raise Exit(2)
    if frm:
        frm = w.strtim(argv[frm])
        if frm < 0:
            frm = -frm
    if to:
        to = w.strtim(argv[to])
        if to < 0:
            to = -to
    tps = w.getiaorigfreq(0)
    if tps > 0:
        w.setafreq(tps)
        w.setiafreq(0, tps)
        if legacy() or sps > 0.0:
            frm = int(frm * tps / sps + 0.5)
            to = int(to * tps / sps + 0.5)
        elif frm or to:     # WFDB-x: no default sampling frequency
            freq_not_specified(pname, record, use_f=True)
            raise Exit(1)
    alist = _AnnList(legacy())     # (WFDB-x: no annotation lost)
    annot = w.Annotation()
    while w.getann(0, annot) == 0:
        if annot.time < frm or (to > 0 and annot.time >= to):
            continue
        alist.insert(annot)
    w.iannclose(0)
    if alist.in_order and out_name is None:
        eprintf("%s: input is already ordered -- no output written\n", pname)
        raise Exit(0)
    if frm == 0 and to == 0 and out_name is None:
        out_name = in_name
    if w.annopen(record, [w.Anninfo(out_name, w.WFDB_WRITE)], 1) < 0:
        raise Exit(2)
    for ann in alist:
        if ann.anntyp != w.NOTQRS:
            w.putann(0, ann)
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run sortann as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["sortann"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["sortann"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
