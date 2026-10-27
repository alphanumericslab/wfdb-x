"""wfdbwhich: find a WFDB file and print its pathname.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of app/wfdbwhich.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: none, apart from the language and the --legacy
option (as the first argument, it restores the original behavior). Through the
library, the file is looked for only where it is named (the input directory, a
full path or a URL), not by a search of the WFDB path; see docs/DIVERGENCES.md.

Original C program: app/wfdbwhich.c, WFDB Software Package 10.7.0.
  Copyright (C) 1999 George B. Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

import wfdbx as w
from ._common import Output, Exit, eprintf, run


def _main(argv, out):
    pname = argv[0]
    argc = len(argv)
    status = 0
    if argc == 2 and argv[1] == "-h":
        argc = 0
    if argc == 2:
        filename = w.wfdbfile(argv[1], None)
        if filename is not None:
            out.write("%s\n" % filename)
        else:
            out.flush()
            eprintf("`%s' not found\n", argv[1])
            eprintf("(WFDB path = %s)\n", w.getwfdb())
            status = 2
    elif argc == 3:
        w.wfdbquiet()
        w.isigopen(argv[2], None, 0)
        filename = w.wfdbfile(argv[1], argv[2])
        if filename is not None:
            out.write("%s\n" % filename)
        else:
            eprintf("No file of type `%s' found for record `%s'\n",
                    argv[1], argv[2])
            eprintf("(WFDB path = %s)\n", w.getwfdb())
            status = 2
    else:
        if argc != 4 or argv[1] != "-r":
            eprintf("usage: %s [-r RECORD ] FILENAME\n", pname)
            eprintf(" -or-  %s FILE-TYPE RECORD\n", pname)
            status = 1
        else:
            w.isigopen(argv[2], None, 0)
            filename = w.wfdbfile(argv[3], None)
            if filename is not None:
                out.write("%s\n" % filename)
            else:
                eprintf("`%s' not found\n", argv[3])
                eprintf("(WFDB path = %s)\n", w.getwfdb())
                status = 2
    raise Exit(status)


def main(argv=None):
    """Run wfdbwhich as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["wfdbwhich"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["wfdbwhich"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
