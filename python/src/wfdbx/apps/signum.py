"""signum: print numbers of signals with given names of a record.

Copyright (C) 2008 George B. Moody (original C program, app/signum.c; revised
2021 by Benjamin Moody).
Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import sys

import wfdbx as w
from ._common import Output, run
from . import signame

HELP = [
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -h          print this usage summary",
    " -s SIGNAL [SIGNAL ...]  print signal number(s) for the specified "
    "signal(s)",
]


def _main(argv, out):
    si, nsig, isiglist, nosig = signame.parse_args(argv, True, HELP)
    for i in range(nosig):
        found = 0
        for j in range(nsig):
            if si[j].desc is not None and argv[isiglist + i] == si[j].desc:
                if found:
                    out.write("\t")
                out.write("%d" % j)
                found = 1
        if not found:
            out.write("X")
        out.write("\n")
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run signum as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["signum"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["signum"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
