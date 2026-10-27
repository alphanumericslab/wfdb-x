"""wfdbdesc: describe signal specifications.

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of app/wfdbdesc.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: no built-in sampling frequency, gain, ADC resolution
or units: an unspecified sampling frequency or ADC resolution is shown as "not
specified" (lengths are then given in sample intervals only), a gain of 0 as
"uncalibrated" (the original: "uncalibrated; assume 200"), and unspecified
units as "adu/nd" (the original assumed 250 Hz, 12 bits and millivolts);
--legacy, as the first argument, restores the original behavior. Each change is
marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.

Original C program: app/wfdbdesc.c, WFDB Software Package 10.7.0.
  Copyright (C) 1989-2012 George B. Moody; revised 2018-2020 by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import os
import sys

import wfdbx as w
from wfdbx._cstd import cdiv
from ._common import Output, Exit, eprintf, legacy, run


def _main(argv, out):
    pname = argv[0]
    argc = len(argv)
    msrec = 0
    if argc < 2:
        eprintf("usage: %s RECORD [-readable]\n", pname)
        raise Exit(1)
    rec = argv[1]
    nsig = w.isigopen(rec, None, 0)
    if nsig < 0:
        raise Exit(2)
    s = []
    if nsig > 0 and argc > 2 and "-readable".startswith(argv[2]):
        nsig = w.isigopen(rec, s, nsig)
    elif nsig > 0:
        nsig = w.isigopen(rec, s, -nsig)
    out.write("Record %s" % rec)
    w.setgvmode(w.WFDB_LOWRES)
    t = w.strtim("e")
    if nsig > 0 and (s[0].fmt == 0 or s[0].nsamp != 0) and s[0].nsamp != t:
        msrec = 1
        out.write(" (a %s-layout multi-segment record)\n" %
                  ("variable" if s[0].nsamp == 0 else "fixed"))
        if s[0].nsamp != 0:
            out.write("----------------------------------------------\n")
            out.write("The following data apply to the entire record:\n")
            out.write("----------------------------------------------")
    info = w.getinfo(rec)
    if info is not None:
        out.write("\nNotes\n=====\n")
        while info is not None:
            out.write(info + "\n")
            info = w.getinfo(None)
        out.write("=====\n")
    # wfdb-x: if the sampling frequency is not specified, times are not
    # shown (C assumed 250 Hz).  In legacy mode, the output is that of the
    # C program.
    freq = w.sampfreq(None)
    timed = freq > 0.0 or legacy()
    p = w.mstimstr(0) if timed else ""
    out.write("\nStarting time: %s\n" % (p if p.startswith("[")
                                         else "not specified"))
    out.write("Length: ")
    done = False
    if not timed and (nsig < 1 or t > 0):
        out.write("%d sample intervals\n" % t)
        done = True
    elif nsig < 1 or t > 0:
        out.write("%s (%d sample intervals)\n" %
                  (w.mstimstr(t) if t > 0 else "0", t))
        done = True
    elif s[0].fmt:
        try:
            nbytes = os.path.getsize(s[0].fname) if \
                os.path.isfile(s[0].fname) else None
        except OSError:
            nbytes = None
        if nbytes is not None:
            nbytes -= w.wfdbgetstart(0)
            framesize = 0
            for k in range(nsig):
                if s[k].group != 0:
                    break
                framesize += s[k].spf
            f = s[0].fmt
            if f in (8, 80):
                t = cdiv(nbytes, framesize)
            elif f in (16, 61, 160):
                t = cdiv(nbytes, 2 * framesize)
            elif f == 24:
                t = cdiv(nbytes, 3 * framesize)
            elif f == 32:
                t = cdiv(nbytes, 4 * framesize)
            elif f == 212:
                t = cdiv(2 * nbytes, 3 * framesize)
            elif f in (310, 311):
                t = cdiv(3 * nbytes, 4 * framesize)
            else:
                t = -1
            if t >= 0 and not timed:
                out.write("%d sample intervals [from signal file size]\n"
                          % t)
            elif t >= 0:
                out.write("%s (%d sample intervals) [from signal file size]\n"
                          % (w.mstimstr(t), t))
            else:
                out.write("not specified\n")
            done = True
    if not done:
        out.write("not specified\n")
    if timed:
        out.write("Sampling frequency: %.12g Hz\n" % freq)
    else:
        out.write("Sampling frequency: not specified\n")
    out.write("%d signal%s\n" % (nsig, "" if nsig == 1 else "s"))
    if nsig < 1:
        raise Exit(2)
    if msrec and s[0].nsamp != 0:
        out.write("----------------------------------------------\n")
        out.write("The following data apply to the first segment:\n")
        out.write("----------------------------------------------\n")
        if timed:
            out.write("Segment length: %s (%d sample intervals)\n" %
                      (w.mstimstr(s[0].nsamp), s[0].nsamp))
        else:
            out.write("Segment length: %d sample intervals\n" % s[0].nsamp)
    for i in range(nsig):
        si = s[i]
        out.write("Group %d, Signal %d:\n" % (si.group, i))
        out.write(" File: %s\n" % (si.fname if si.fmt else "[none]"))
        out.write(" Description: %s\n" % si.desc)
        out.write(" Gain: ")
        if legacy():    # wfdb-x: legacy mode, as in the C program
            out.write("uncalibrated; assume %g" % w.WFDB_DEFGAIN
                      if si.gain == 0.0 else "%.12g" % si.gain)
            out.write(" adu/%s\n" % (si.units if si.units is not None
                                     else "mV"))
        elif si.gain == 0.0:   # wfdb-x: no default gain
            out.write("uncalibrated\n")
        else:
            # wfdb-x: unspecified units are shown as "nd" (C assumed mV)
            out.write("%.12g adu/%s\n" % (si.gain, si.units if si.units
                                           is not None else "nd"))
        out.write(" Initial value: %d\n" % si.initval)
        if si.fmt != 0:
            out.write(" Storage format: %d" % si.fmt)
        if si.spf > 1:
            out.write(" (%d samples per frame)" % si.spf)
        if si.fmt != 0 or si.spf > 1:
            out.write("\n")
        out.write(" I/O: ")
        if si.bsize == 0:
            out.write("can be unbuffered\n")
        else:
            out.write("%d-byte blocks\n" % si.bsize)
        if si.adcres > 0 or legacy():
            out.write(" ADC resolution: %d bits\n" % si.adcres)
        else:               # wfdb-x: no default resolution
            out.write(" ADC resolution: not specified\n")
        out.write(" ADC zero: %d\n" % si.adczero)
        out.write(" Baseline: %d\n" % si.baseline)
        if si.nsamp > 0:
            out.write(" Checksum: %d\n" % si.cksum)
    return 0


def main(argv=None):
    """Run wfdbdesc as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["wfdbdesc"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["wfdbdesc"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
