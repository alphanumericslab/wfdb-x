"""rdedfann: extract annotations from an EDF+ file (as text for wrann).

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of convert/rdedfann.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: none, apart from the language and the --legacy
option (as the first argument, it restores the original behavior).

Original C program: convert/rdedfann.c, WFDB Software Package 10.7.0.
  Copyright (C) 2008-2014 George B. Moody; bug fix and -x option contributed by
  Luca Citi, 2014.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

import wfdbx as w
from wfdbx._cstd import sscanf, atof
from ._common import Output, Exit, eprintf, run

HELP = [
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input EDF+ record, and OPTIONS may "
    "include:",
    " -F FREQ     set the sampling frequency to FREQ Hz\n",
    " -h          print this usage summary",
    " -v          print column headings",
    " -x          print EDF+ annotation text in aux (default: print in "
    "anntyp)",
]


def help(pname):
    eprintf(HELP[0], pname)
    for s in HELP[1:]:
        eprintf("%s\n", s)


def _cstr(b):
    k = b.find(b"\0")
    return (bytes(b) if k < 0 else bytes(b[:k])).decode("latin-1")


TALBUFLEN = 1024        # size of the onset, duration and text buffers
# Separators in an EDF+ time-stamped annotation list (TAL).
DURATION_SEP = 0o25     # ends the onset, when a duration follows
FIELD_SEP = 0o24        # ends the onset or duration, and the text


class _Parser:
    """The TAL state machine of rdedfann.c (with its static buffers)."""

    def __init__(self, out, pname, sfreq, xflag):
        self.out = out
        self.pname = pname
        self.sfreq = sfreq
        self.xflag = xflag
        self.state = 0
        self.onset = bytearray(TALBUFLEN)
        self.duration = bytearray(TALBUFLEN)
        self.text = bytearray(TALBUFLEN)
        self.op = self.dp = self.tp = 0

    def proc(self, x):
        x &= 0xFF
        st = self.state
        if st == 0:             # looking for a new TAL
            if x == 0:
                return
            if x != ord("+"):
                self.out.flush()
                eprintf("%s: unexpected character '%c' in input\n",
                        self.pname, chr(x))
            else:
                self.state = 1
                self.op = self.dp = self.tp = 0
                self.text[0] = 0
        elif st == 1:           # onset
            if x == DURATION_SEP:
                x = 0
                self.state = 2
            elif x == FIELD_SEP:
                x = 0
                self.state = 3
            self.onset[self.op] = x
            self.op += 1
        elif st == 2:           # duration
            if x == FIELD_SEP:
                x = 0
                self.state = 3
            self.duration[self.dp] = x
            self.dp += 1
        elif st == 3:           # annotation text
            if x == FIELD_SEP:
                x = 0
                self.state = 4
            self.text[self.tp] = x
            self.tp += 1
        elif st == 4:
            if self.text[0]:
                t = int(atof(_cstr(self.onset)) * self.sfreq + 0.5)
                txt = _cstr(self.text).replace(" ", "_").replace("\t", "_")
                k = len(txt)
                self.text[:k] = txt.encode("latin-1")
                self.out.write("%s  %7d %5s%5d%5d%5d\t%s" % (
                    w.mstimstr(t) if t else "    0:00.000", t,
                    "\"" if self.xflag else txt, 0, 0, 0,
                    txt if self.xflag else ""))
                if self.duration[0]:
                    self.out.write("%sduration: %s" % (
                        " " if self.xflag else "\t", _cstr(self.duration)))
                self.out.write("\n")
            if x:
                self.text[0] = x
                self.tp = 1
                self.state = 3
            else:
                self.state = 0


def _main(argv, out):
    pname = argv[0]
    argc = len(argv)
    record = None
    sfreq = 0.0
    vflag = xflag = 0
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "F":
                i += 1
                if i >= argc:
                    eprintf("%s: sampling frequency must follow -F\n", pname)
                    raise Exit(1)
                n, v = sscanf(argv[i], "%lf")
                if n == 1:
                    sfreq = v[0]
                if sfreq <= 0.0:
                    sfreq = 1.0
            elif c == "h":
                help(pname)
                raise Exit(0)
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            elif c == "v":
                vflag = 1
            elif c == "x":
                xflag = 1
            else:
                eprintf("%s: unrecognized option %s\n", pname, a)
                raise Exit(1)
        else:
            eprintf("%s: unrecognized argument %s\n", pname, a)
            raise Exit(1)
        i += 1
    if record is None:
        help(pname)
        raise Exit(1)
    w.setgvmode(w.WFDB_HIGHRES)
    nsig = w.isigopen(record, None, 0)
    if nsig <= 0:
        raise Exit(2)
    si = []
    nsig = w.isigopen(record, si, nsig)
    if nsig <= 0:
        raise Exit(2)
    aindex = alen = framelen = 0
    for s in si:
        if s.desc == "EDF Annotations":
            aindex = framelen
            alen = s.spf
        framelen += s.spf
    if alen == 0:
        eprintf("%s: record %s has no EDF annotations\n", pname, record)
        w.wfdbquit()
        raise Exit(3)
    frame = [0] * framelen
    if sfreq > 0.0:
        w.setgvmode(w.WFDB_LOWRES)
        w.setsampfreq(sfreq)
    else:
        sfreq = w.sampfreq(None)
    if vflag:
        out.write("      Time   Sample #  Type  Sub Chan  Num\tAux\n")
    P = _Parser(out, pname, sfreq, xflag)
    while w.getframe(frame) > 0:
        P.state = 0
        for k in range(alen):
            x = frame[aindex + k]
            if x or P.state:
                P.proc(x)
                P.proc(x >> 8)
            else:
                break
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run rdedfann as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["rdedfann"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["rdedfann"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
