"""time2sec: convert a time interval to seconds.

Copyright (C) 2003-2009 George B. Moody (original C program, app/time2sec.c).
Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import sys

import wfdbx as w
from ._common import Output, Exit, eprintf, run


def _main(argv, out):
    argc = len(argv)
    if argc == 4 and argv[1] == "-r":
        w.isigopen(argv[2], None, 0)
        t = float(w.strtim(argv[3]))
        if t < 0:
            t = -t
        sf = w.sampfreq(None)
        seconds = int(t / sf)
        t -= float(seconds * sf)
        milliseconds = int((t * 1000.0) / sf + 0.5)
        if milliseconds >= 1000:
            seconds += 1
            milliseconds -= 1000
        out.write("%d" % seconds)
        if milliseconds:
            out.write(".%03d" % milliseconds)
        out.write("\n")
        raise Exit(0)
    elif argc == 2 and not argv[1].startswith("-"):
        w.setsampfreq(1000.0)
        out.write("%.12g\n" % (w.strtim(argv[1]) / 1000.0))
        raise Exit(0)
    eprintf("usage: %s [-r RECORD] TIME\n", argv[0])
    eprintf(" where TIME (in hh:mm:ss format) is a time interval\n")
    eprintf(" to be converted into seconds.  Enclose TIME in\n")
    eprintf(" square brackets (e.g., [9:0:0]) to convert a time\n")
    eprintf(" of day to the elapsed time in seconds from the\n")
    eprintf(" beginning of the (optionally) specified RECORD.\n")
    raise Exit(1)


def main(argv=None):
    """Run time2sec as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["time2sec"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["time2sec"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
