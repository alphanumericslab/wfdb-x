"""a2m: convert an AHA-format annotation file to MIT format.

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of convert/a2m.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: no built-in sampling frequency: the new option -F
FREQ gives it when the record has no header or its header gives none, and is
then required (the original assumed 250 Hz, or 1 sample per second without a
header); annotation times given in milliseconds (AHA file types 1 to 3) are
converted at the record's sampling frequency (the original assumed 4 ms per
sample); --legacy, as the first argument, restores the original behavior. Each
change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.

Original C program: convert/a2m.c, WFDB Software Package 10.7.0.
  Copyright (C) 1983-2010 George B. Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import os
import sys

import wfdbx as w
from wfdbx import _wfdbio as wio
from wfdbx._cstd import atoi, d2l, int8, sscanf
from ._common import Exit, eprintf, legacy, legacy_help, run

HELP = [
    "usage: %s -i AHAFILE [ OPTIONS ... ]\n",
    "where AHAFILE is the name of the AHA-format input annotation file,",
    "and OPTIONS may include:",
    " -a ANNOTATOR  specify the output annotator name (default: 'atr')",
    " -F FREQ       sampling frequency, if the record header does not specify",
    "                one (AHA database: 250)",
    " -h            print this usage summary",
    " -r RECORD     specify the name of the output RECORD (default: use the",
    "                input file name, less path info and extension, as RECORD)",
    " -s TIME       shift annotations by TIME",
    "                (defaults: 0 for TYPE 0,",
    "                      5:0 for TYPE 1, (or TYPE 3 if RECORD=x2xx or x3xx)",
    "                   2:30:0 for TYPE 2, (or TYPE 3 if RECORD=x0xx or x1xx)",
    " -t TYPE       specify type of file to be converted:",
    "                0 for files produced by WFDB applications in AHA format,",
    "                1 for short-format tape files,",
    "                2 for long-format tape files, or",
    "                3 for compressed files from AHA DB CD-ROMs or diskettes",
    "                (defaults: 3 if AHAFILE ends in .ANO or .ano, else 0)",
]

# wfdb-x: the help text of the original program, printed in legacy mode
LEGACY_HELP = legacy_help(HELP, {
    " -F FREQ       sampling frequency, if the record header does not specify":
    None,
    "                one (AHA database: 250)": None})


def help(pname):
    hs = LEGACY_HELP if legacy() else HELP     # wfdb-x
    eprintf(hs[0], pname)
    for s in hs[1:]:
        eprintf("%s\n", s)


def redirect_stdin(ifname, pname):
    """freopen(ifname, "rb", stdin): make the file the standard input."""
    if ifname == "-":
        return True
    if os.path.isdir(ifname):
        # (C reads a directory forever; wfdb-x reports it as unreadable)
        return False
    try:
        fd = os.open(ifname, os.O_RDONLY)
    except OSError:
        return False
    try:
        sys.stdin.flush()
    except (OSError, ValueError, AttributeError):
        pass
    os.dup2(fd, 0)
    os.close(fd)
    sys.stdin = open(0, "r", closefd=False)
    wio._stdin_file = None
    return True


def basename_record(ifname):
    k = ifname.rfind("/")
    rec = ifname[k + 1:]
    j = rec.find(".", 1)
    if j >= 1:
        rec = rec[:j]
    return rec


def _ms_to_samples(t):
    # Times in milliseconds are converted at the sampling frequency of the
    # record (wfdb-x; C assumed 4 ms per sample, i.e., 250 Hz, whatever the
    # record's frequency, as legacy mode does).
    if legacy():
        return t >> 2       # 4 msec/sample
    return d2l(t * w.sampfreq(None) / 1000.0)


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    ifname = record = None
    oann = "atr"
    typ = -1
    offset = 0
    ffreq = 0.0     # wfdb-x: -F
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "a":
                i += 1
                if i >= argc:
                    eprintf("%s: output annotator name must follow -a\n",
                            pname)
                    raise Exit(1)
                oann = argv[i]
            elif c == "F" and not legacy():    # sampling frequency (wfdb-x)
                i += 1
                n, v = sscanf(argv[i], "%lf") if i < argc else (0, [])
                if n != 1 or v[0] <= 0.0:
                    eprintf("%s: sampling frequency (> 0) must follow -F\n",
                            pname)
                    raise Exit(1)
                ffreq = v[0]
            elif c == "h":
                help(pname)
                raise Exit(1)
            elif c == "i":
                i += 1
                if i >= argc:
                    eprintf("%s: name of AHA-format input file must follow "
                            "-i\n", pname)
                    raise Exit(1)
                ifname = argv[i]
                if typ < 0 and len(ifname) > 4 and \
                        ifname[-4:] in (".ANO", ".ano"):
                    typ = 3
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: record name must follow -a\n", pname)
                    raise Exit(1)
                record = argv[i]
            elif c == "s":
                i += 1
                if i >= argc:
                    eprintf("%s: time shift must follow -s\n", pname)
                    raise Exit(1)
                offset = i
            elif c == "t":
                i += 1
                if i < argc:
                    typ = atoi(argv[i])
                if i >= argc or typ < 0 or typ > 3:
                    eprintf("%s: file type (0-3) must follow -t\n", pname)
                    raise Exit(1)
            else:
                eprintf("%s: unrecognized option %s\n", pname, a)
                raise Exit(1)
        else:
            eprintf("%s: unrecognized argument %s\n", pname, a)
            raise Exit(1)
        i += 1
    if ifname is None:
        help(pname)
        raise Exit(1)
    if not redirect_stdin(ifname, pname):
        eprintf("%s: can't read input file `%s'\n", pname, ifname)
        raise Exit(2)
    if record is None:
        record = basename_record(ifname)
    if typ < 0:
        typ = 0
    ai = [w.Anninfo(oann, w.WFDB_WRITE)]
    if typ != 3:
        ai.append(w.Anninfo("-", w.WFDB_AHA_READ))
    if w.annopen(record, ai, len(ai)) < 0:
        raise Exit(2)
    # wfdb-x: if the record header does not give the sampling frequency, -F
    # must give it.  (C assumed the rate of the AHA database, 250 Hz, if a
    # header without a frequency existed, and 1 sample per second if there
    # was no header, as legacy mode does.)
    if legacy():
        if w.sampfreq(record) == 0.0:
            w.setsampfreq(250.0)    # the AHA DB sampling frequency
    elif w.sampfreq(record) <= 0.0:
        if ffreq > 0.0:
            w.setsampfreq(ffreq)
        else:
            eprintf("%s: sampling frequency of record %s is not specified "
                    "(use -F)\n", pname, record)
            raise Exit(1)
    if offset:
        offset = w.strtim(argv[offset])
    else:
        if typ == 1:
            offset = w.strtim("5:0")
        elif typ == 2:
            offset = w.strtim("2:30:0")
        elif typ == 3:
            if len(record) == 4 and record[1] in "01":
                offset = w.strtim("2:30:0")
            elif len(record) == 4 and record[1] in "23":
                offset = w.strtim("5:0")
    annot = w.Annotation()
    if typ == 0:
        while w.getann(0, annot) >= 0:
            if annot.chan:
                annot.anntyp = int8(annot.chan)
                annot.chan = 0
            annot.time += offset
            if w.putann(0, annot) < 0:
                break
    elif typ in (1, 2):
        while w.getann(0, annot) >= 0:
            annot.time = _ms_to_samples(annot.time) + offset
            w.putann(0, annot)
    else:
        f = sys.stdin.buffer
        while True:
            # Compressed AHA format: the AHA label, the 24-bit time (most
            # significant byte first; 0xFF in the high byte marks a soft
            # EOF), and a 16-bit serial number (ignored).
            buf = f.read(6)
            if len(buf) != 6:           # hard EOF
                break
            if buf[1] == 0xFF:          # soft EOF
                break
            c0 = buf[0] - 256 if buf[0] > 127 else buf[0]   # signed char
            annot.anntyp = w.ammap(c0)
            if annot.anntyp == 0:
                break
            annot.subtyp = -1 if buf[0] == ord("U") else 0
            annot.time = (buf[1] << 16) | (buf[2] << 8) | buf[3]
            annot.time = _ms_to_samples(annot.time) + offset
            w.putann(0, annot)
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run a2m as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["a2m"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["a2m"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
