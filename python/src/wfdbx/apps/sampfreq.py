"""sampfreq: print the sampling frequency of a record.

Copyright (C) 1998-2012 George B. Moody (original C program, app/sampfreq.c).
Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency, gain,
ADC resolution or units. Values that the record or the user does not give are
never assumed (the original package assumed 250 Hz, 200 adu/mV, 12 bits and
millivolts), because a silently assumed value corrupts every result derived
from it. See docs/DIVERGENCES.md.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import sys

import wfdbx as w
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
            out.write("%s\t%g\n" % (si[i].desc, si[i].spf * freq))
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
