"""wfdbcat: copy WFDB files to the standard output.

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of app/wfdbcat.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: none, apart from the language and the --legacy
option (as the first argument, it restores the original behavior). Through the
library, each file is read from where it is named (the input directory, a full
path or a URL), not found by a search of the WFDB path; see
docs/DIVERGENCES.md.

Original C program: app/wfdbcat.c, WFDB Software Package 10.7.0.
  Copyright (C) 2000 George B. Moody; revised 2018 by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

from wfdbx import _wfdbio as wio
from ._common import Exit, RawOutput, eprintf, run

BUFSIZE = 1024          # bytes read at a time


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    if argc < 2 or (argc == 2 and argv[1] == "-h"):
        eprintf("usage: %s FILE [FILE ...]\n", pname)
        raise Exit(1)
    out = RawOutput()
    for i in range(1, argc):
        f = wio.wfdb_open(argv[i], None, wio.WFDB_READ)
        if f is None:
            out.flush()
            eprintf("%s: `%s' not found\n", pname, argv[i])
        else:
            while True:
                b = f.read(BUFSIZE)
                if not b:
                    break
                out.write(b)
            f.close()
    out.flush()
    return 0


def main(argv=None):
    """Run wfdbcat as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["wfdbcat"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["wfdbcat"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
