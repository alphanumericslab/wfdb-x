"""md2a: convert an MIT-format signal file to AHA format.

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of convert/md2a.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: none, apart from the language and the --legacy
option (as the first argument, it restores the original behavior).

Original C program: convert/md2a.c, WFDB Software Package 10.7.0.
  Copyright (C) 2001 George B. Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

import wfdbx as w
from ._common import Exit, eprintf, run

EODF = 0o100000
WFDB_MAXSIG = 32
HELP = [
    "usage: %s -o AHAFILE -r RECORD [ OPTIONS ... ]\n",
    "where AHAFILE is the name of the AHA-format output signal file,",
    "RECORD is the record name, and OPTIONS may include:",
    " -h         print this usage summary",
    " -n NEWREC  create a header file for the output signal file, so it",
    "             may be read as record NEWREC",
]


def help(pname):
    eprintf(HELP[0], pname)
    for s in HELP[1:]:
        eprintf("%s\n", s)


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    nrec = ofname = record = None
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "h":
                help(pname)
                raise Exit(1)
            elif c == "n":
                i += 1
                if i >= argc:
                    eprintf("%s: new record name must follow -n\n", pname)
                    raise Exit(1)
                nrec = argv[i]
            elif c == "o":
                i += 1
                if i >= argc:
                    eprintf("%s: name of AHA-format output file must follow "
                            "-o\n", pname)
                    raise Exit(1)
                ofname = argv[i]
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            else:
                eprintf("%s: unrecognized option %s\n", pname, a)
                raise Exit(1)
        else:
            eprintf("%s: unrecognized argument %s\n", pname, a)
            raise Exit(1)
        i += 1
    if ofname is None or record is None:
        help(pname)
        raise Exit(1)
    s = []
    nsig = w.isigopen(record, s, WFDB_MAXSIG)
    if nsig < 1:
        raise Exit(2)
    if nrec is not None and w.newheader(nrec) < 0:
        raise Exit(3)
    for si in s:
        si.fname = ofname
        si.desc = ""
        si.group = 0
        si.fmt = 16
    if w.osigfopen(s, nsig) < nsig:
        raise Exit(4)
    # x has one element per output sample of a frame (at least
    # WFDB_MAXSIG); getvec sets the first nsig, the others stay zero.  (In
    # C, x is an uninitialized array of WFDB_MAXSIG; see "Undefined
    # behaviors" in docs/KNOWN_C_BEHAVIORS.md.)
    nout = sum(max(si.spf, 1) for si in s[:nsig])
    x = [0] * max(nout, WFDB_MAXSIG)
    while w.getvec(x) == nsig and w.putvec(x) == nsig:
        pass
    if nrec is not None:
        w.newheader(nrec)
    for k in range(nsig):
        x[k] = EODF
    w.putvec(x)
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run md2a as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["md2a"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["md2a"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
