"""wfdbcat: copy WFDB files (found in the WFDB path) to the standard output.

Copyright (C) 2000 George B. Moody (original C program, app/wfdbcat.c; revised
2018 by Benjamin Moody).
Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import sys

from wfdbx import _wfdbio as wio
from ._common import Exit, eprintf, run

BUFSIZE = 1024          # bytes read at a time


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    if argc < 2 or (argc == 2 and argv[1] == "-h"):
        eprintf("usage: %s FILE [FILE ...]\n", pname)
        raise Exit(1)
    out = sys.stdout.buffer
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
