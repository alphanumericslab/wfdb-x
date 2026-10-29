"""sampfreq: print the sampling frequency of a record.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of app/sampfreq.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: none, apart from the language and the --legacy
option (as the first argument, it restores the original behavior). Through the
library, a record whose header gives no sampling frequency has the frequency 0,
which is printed (the original printed 250); see docs/DIVERGENCES.md.

Original C program: app/sampfreq.c, WFDB Software Package 10.7.0.
  Copyright (C) 1998-2012 George B. Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

import wfdbx as w
from wfdbx._cstd import cfmt_float
from ._common import Output, Exit, eprintf, run


def help(pname):
    eprintf("usage: %s [OPTION] RECORD\n", pname)
    eprintf(" where RECORD is the name of the input record\n"
            " and OPTION may be either of:\n"
            "  -a   list all signals and their sampling frequencies\n"
            "  -h   show this help\n"
            "  -H   show the maximum sampling frequency of a multifrequency "
            "record)\n"
            " If no OPTION is used, show the base sampling frequency (frame "
            "rate).\n")


def _main(argv, out):
    pname = argv[0]
    argc = len(argv)
    if argc == 1:
        help(pname)
        raise Exit(1)
    if argc == 2:
        out.write("%g\n" % w.sampfreq(argv[1]))
        raise Exit(0)
    if argc == 3 and argv[1] in ("-a", "-H"):
        si = []
        nsig = w.isigopen(argv[2], None, 0)
        if nsig > 0:
            w.isigopen(argv[2], si, nsig)
        if argv[1][1] == "H":
            w.setgvmode(w.WFDB_HIGHRES)
            out.write("%g\n" % w.sampfreq(None))
            raise Exit(0)
        w.setgvmode(w.WFDB_LOWRES)
        freq = w.sampfreq(None)
        for i in range(max(nsig, 0)):
            if i < len(si):
                out.write("%s\t%g\n" % (si[i].desc, si[i].spf * freq))
            else:   # (a signal that could not be opened: C prints the
                # zeroed entry of its array: spf 0 times freq, which is
                # nan if freq is nan, and -nan if it is infinite)
                out.write("(null)\t%s\n" % cfmt_float("%g", 0.0 * freq))
    return 0


def main(argv=None):
    """Run sampfreq as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["sampfreq"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["sampfreq"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
