"""revise: convert an obsolete-format header file into a current one.

Copyright (C) 1999 George B. Moody (original C program, convert/revise.c;
revised 2018 by Benjamin Moody).
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
from wfdbx import _wfdbio as wio
from wfdbx._cstd import Strtok, atoi, atof, strtol, uint32
from ._common import Exit, eprintf, legacy, run

WFDB_MAXSIG = 32
LINEBUFLEN = 256        # size of the header line buffer, as in C


def readoldheader(record, si):
    sep = " \t\n"
    f = wio.wfdb_open("header", record, wio.WFDB_READ)
    if f is None:
        w.wfdb_error("init: can't open header for record %s\n", record)
        return -1

    def fgets():        # fgets(linebuf, 256, ...)
        b = f.fp.readline(LINEBUFLEN - 1)
        return b.decode("latin-1") if b else None

    while True:
        line = fgets()
        if line is None:
            w.wfdb_error("init: can't find record name in record %s header\n",
                         record)
            return -2
        tok = Strtok(line)
        p = tok.next(sep)
        if p is not None and not p.startswith("#"):
            break
    if not f.is_std and p != record:
        w.wfdb_error("init: record name in record %s header is incorrect\n",
                     record)
        return -2
    if tok.next(sep) is not None:
        eprintf("The header for record %s appears not to be an old-style "
                "header.\n", record)
        return -2

    def nexttok():
        line = fgets()
        if line is None:
            return None, None
        t = Strtok(line)
        return t, t.next(sep)

    t, p = nexttok()
    if p is None:
        w.wfdb_error("init: incorrect format in record %s header\n", record)
        return -2
    ng = atoi(p)
    nsamples = 0
    s = 0
    g = 0
    while g < ng:
        cur = w.Siginfo()
        cur.group = g
        t, p = nexttok()
        if p is None:
            w.wfdb_error("init: incorrect format in record %s header\n",
                         record)
            return -2
        cur.fname = p
        t, p = nexttok()
        if p is None:
            w.wfdb_error("init: incorrect format in record %s header\n",
                         record)
            return -2
        cur.gain = atof(p)
        t, p = nexttok()
        if p is None or atof(p) <= 0.0:
            w.wfdb_error("init: incorrect format in record %s header\n",
                         record)
            return -2
        w.setsampfreq(atof(p))
        t, p = nexttok()
        if p is None:
            w.wfdb_error("init: incorrect format in record %s header\n",
                         record)
            return -2
        i = uint32(atoi(p))
        p = t.next(sep)
        mpx = atoi(p) if p is not None else 1
        if mpx == 0:
            mpx = 1
        if i != 8 and i != 16:
            cur.bsize = i
            if mpx < 0:
                mpx = -mpx
                cur.fmt = 8
            else:
                cur.fmt = 16
        else:
            cur.fmt = i
            cur.bsize = 0
        p = t.next(sep)
        # wfdb-x: C (and legacy mode) assumed WFDB_DEFRES
        cur.adcres = atoi(p) if p is not None else \
            (w.WFDB_DEFRES if legacy() else 0)
        p = t.next(sep)
        cur.adczero = atoi(p) if p is not None else 0
        t, p = nexttok()
        if p is None:
            w.wfdb_error("init: incorrect format in record %s header\n",
                         record)
            return -2
        cur.initval = atoi(p)
        p = t.next(sep)
        ns = strtol(p)[0] if p is not None else 0
        if ns < 0:
            w.wfdb_error("init: incorrect format in record %s header\n",
                         record)
            return -2
        if nsamples == 0:
            nsamples = ns
        elif ns > 0 and ns != nsamples:
            w.wfdb_error("warning (init):\n")
            w.wfdb_error(" record %s durations are inconsistent\n", record)
            if nsamples > ns:
                nsamples = ns
        p = t.next(sep)
        if p is not None:
            cur.cksum = atoi(p)
            cur.nsamp = ns
        else:
            cur.cksum = 0
            cur.nsamp = 0
        si.append(cur)
        # while (++s < WFDB_MAXSIG && --mpx > 0): when s reaches
        # WFDB_MAXSIG, mpx is not decremented, so a record with exactly
        # WFDB_MAXSIG signals is rejected below (as in C).
        while True:
            s += 1
            if s >= WFDB_MAXSIG:
                break
            mpx -= 1
            if mpx <= 0:
                break
            si.append(si[-1].copy())
        if s == WFDB_MAXSIG and (mpx > 0 or g < ng - 1):
            w.wfdb_error("init: too many signals in record %s\n", record)
            return -2
        g += 1
    for k in range(s):
        si[k].desc = "record %s, signal %d" % (record, k)
    return s


def _main(argv):
    if len(argv) < 2:
        eprintf("usage: %s record\n", argv[0])
        eprintf(" This program converts obsolete-format header files into new "
                "ones.\n")
        raise Exit(1)
    record = argv[1]
    if record.startswith("header."):
        record = record[len("header."):]
    si = []
    nsig = readoldheader(record, si)
    if nsig < 0:
        raise Exit(2)
    w.setheader(record, si, nsig)
    return 0


def main(argv=None):
    """Run revise as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["revise"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["revise"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
