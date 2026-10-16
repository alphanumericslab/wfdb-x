"""wfdbtime: convert between times and sample numbers.

Copyright (C) 2001 George B. Moody (original C program, app/wfdbtime.c; revised
2017-2018 by Benjamin Moody).
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
from ._common import Output, Exit, eprintf, legacy, run


def _main(argv, out):
    record = None
    argc = len(argv)
    i = 1
    while i < argc:
        if argv[i] == "-r":
            if record is not None:
                w.wfdbquit()
            i += 1
            if i == argc:
                break
            record = argv[i]
            if w.isigopen(record, None, 0) < 0:
                raise Exit(2)
            # wfdb-x: no default frequency (legacy mode: no check)
            if not legacy() and w.sampfreq(None) <= 0.0:
                eprintf("%s: sampling frequency of record %s is not "
                        "specified\n", argv[0], record)
                raise Exit(2)
        elif record is not None:
            t = w.strtim(argv[i])
            if t < 0:
                t = -t
            sbuf = "s%d" % t
            out.write("%15s\t%15s" % (sbuf, "0:00.000" if t == 0
                                      else w.mstimstr(t)))
            out.write("\t%15s\n" % w.mstimstr(-t))
        i += 1
    if record is None:
        eprintf("usage: %s [ -r RECORD [ TIME ] ]\n", argv[0])
        eprintf(" where RECORD is the name of the input record\n")
        eprintf(" Each TIME is a time to be converted\n")
        raise Exit(1)
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run wfdbtime as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["wfdbtime"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["wfdbtime"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
