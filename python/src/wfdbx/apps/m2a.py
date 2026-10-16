"""m2a: convert an MIT-format annotation file to AHA format.

Copyright (C) 2001 George B. Moody (original C program, convert/m2a.c).
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
from ._common import (Exit, eprintf, freq_not_specified, freq_option, legacy,
                      legacy_help, run)

HELP = [
    "usage: %s -r RECORD -a MIT-ANNOTATOR AHA-ANNOTATOR [ OPTIONS ... ]\n",
    "where RECORD is the record name, MIT-ANNOTATOR is the annotator name",
    "for the input annotation file, AHA-ANNOTATOR is the annotator name",
    "for the output (AHA format) annotation file, and OPTIONS may include:",
    " -F FREQ   sampling frequency, if the record header does not specify one",
    " -h        print this usage summary",
    " -s TIME   shift annotation times backwards by the specified TIME,",
    "            and convert them to milliseconds",
]

# wfdb-x: the help text of the original program, printed in legacy mode
LEGACY_HELP = legacy_help(HELP, {
    " -F FREQ   sampling frequency, if the record header does not specify one":
    None})


def help(pname):
    hs = LEGACY_HELP if legacy() else HELP     # wfdb-x
    eprintf(hs[0], pname)
    for s in hs[1:]:
        eprintf("%s\n", s)


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    ianame = oaname = record = shift = None
    ffreq = 0.0
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "a":
                i += 1
                if i >= argc - 1:
                    eprintf("%s: input and output annotator names must "
                            "follow -a\n", pname)
                    raise Exit(1)
                ianame = argv[i]
                i += 1
                oaname = argv[i]
            elif c == "F" and not legacy():    # sampling frequency (wfdb-x)
                i += 1
                ffreq = freq_option(argv, i, pname)
            elif c == "h":
                help(pname)
                raise Exit(1)
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            elif c == "s":
                i += 1
                if i >= argc:
                    eprintf("%s: time shift must follow -s\n", pname)
                    raise Exit(1)
                shift = argv[i]
            else:
                eprintf("%s: unrecognized option %s\n", pname, a)
                raise Exit(1)
        else:
            eprintf("%s: unrecognized argument %s\n", pname, a)
            raise Exit(1)
        i += 1
    if ianame is None or oaname is None or record is None:
        help(pname)
        raise Exit(1)
    if w.annopen(record, [w.Anninfo(ianame, w.WFDB_READ),
                          w.Anninfo(oaname, w.WFDB_AHA_WRITE)], 2) < 0:
        raise Exit(2)
    annot = w.Annotation()
    if shift is None:
        while w.getann(0, annot) >= 0:
            w.putann(0, annot)
    else:
        # wfdb-x: no default sampling frequency (C assumed 250 Hz if the
        # record header did not specify one, as legacy mode does); -F
        # specifies one.
        if w.sampfreq(record) <= 0.0:
            if legacy():
                w.setsampfreq(w.WFDB_DEFFREQ)
            elif ffreq > 0.0:
                w.setsampfreq(ffreq)
            else:
                freq_not_specified(pname, record, use_f=True)
                raise Exit(1)
        mssi = 1000.0 / w.strtim("1")
        dt = w.strtim(shift)
        while w.getann(0, annot) >= 0:
            if annot.time >= dt:
                annot.time = int((annot.time - dt) * mssi)
                w.putann(0, annot)
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run m2a as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["m2a"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["m2a"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
