"""signame: print names of signals of a record.

Copyright (C) 2008 George B. Moody (original C program, app/signame.c).
Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import sys

import wfdbx as w
from wfdbx._cstd import atoi
from ._common import Output, Exit, eprintf, run

HELP = [
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -h          print this usage summary",
    " -s SIGNAL [SIGNAL ...]  print signal name(s) for the specified "
    "signal(s)",
    "If no -s option is given, the names of all signals in the record are "
    "output.",
]


def help(pname, lines=None):
    lines = lines or HELP
    eprintf(lines[0], pname)
    for s in lines[1:]:
        eprintf("%s\n", s)


def parse_args(argv, needlist, helplines=None):
    """Option parsing shared by signame and signum."""
    pname = argv[0]
    argc = len(argv)
    record = None
    isiglist = nosig = 0
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "h":
                help(pname, helplines)
                raise Exit(0)
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            elif c == "s":
                isiglist = i + 1
                while i + 1 < argc and not argv[i + 1].startswith("-"):
                    i += 1
                    nosig += 1
                if nosig == 0:
                    eprintf("%s: signal list must follow -s\n", pname)
                    raise Exit(1)
            else:
                eprintf("%s: unrecognized option %s\n", pname, a)
                raise Exit(1)
        else:
            eprintf("%s: unrecognized argument %s\n", pname, a)
            raise Exit(1)
        i += 1
    if record is None or (needlist and isiglist == 0):
        help(pname, helplines)
        raise Exit(1)
    nsig = w.isigopen(record, None, 0)
    if nsig <= 0:
        raise Exit(2)
    si = []
    nsig = w.isigopen(record, si, -nsig)
    if nsig <= 0:
        raise Exit(2)
    return si, nsig, isiglist, nosig


def _main(argv, out):
    si, nsig, isiglist, nosig = parse_args(argv, False)
    if isiglist:
        for i in range(nosig):
            j = atoi(argv[isiglist + i])
            # (The C version also accepts j == nsig, reading past the end
            # of its array; see docs/KNOWN_C_BEHAVIORS.md.)
            p = si[j].desc if 0 <= j < nsig else "[INVALID]"
            out.write("%s\n" % p)
    else:
        for i in range(nsig):
            out.write("%s\n" % si[i].desc)
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run signame as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["signame"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["signame"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
