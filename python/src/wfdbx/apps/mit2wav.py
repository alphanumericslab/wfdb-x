"""mit2wav: convert a WFDB record to .wav format.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of convert/mit2wav.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: no built-in sampling frequency: the record must give
it (the original assumed 250 Hz); --legacy, as the first argument, restores the
original behavior. Each change is marked "wfdb-x:" in the code;
docs/DIVERGENCES.md gives the reasons.

Original C program: convert/mit2wav.c, WFDB Software Package 10.7.0.
  Copyright (C) 2003-2010 George B. Moody; revised 2018 by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import struct
import sys

import wfdbx as w
from wfdbx._cstd import int32
from ._common import Exit, eprintf, freq_not_specified, legacy, run

WAVHDRLEN = 44          # length of the .wav header (RIFF, fmt and data)

HELP = [
    "usage: %s -o FILE.wav -r RECORD [ OPTIONS ... ]\n",
    "where FILE.wav is the name of the wav-format output signal file,",
    "RECORD is the record name, and OPTIONS may include:",
    " -h         print this usage summary",
    " -n NEWREC  create a header file for the output signal file, so it",
    "             may be read as record NEWREC",
]


def help(pname):
    eprintf(HELP[0], pname)
    for s in HELP[1:]:
        eprintf("%s\n", s)


def _u32(x):
    return struct.pack("<I", x & 0xFFFFFFFF)


def _u16(x):
    return struct.pack("<H", x & 0xFFFF)


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    nrec = ofname = record = None
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "h":
                help(pname)
                raise Exit(1)
            elif c == "n":
                i += 1
                if i >= argc:
                    eprintf("%s: new record name must follow -n\n", pname)
                    raise Exit(1)
                nrec = argv[i]
            elif c == "o":
                i += 1
                if i >= argc:
                    eprintf("%s: name of wav-format output file must follow "
                            "-o\n", pname)
                    raise Exit(1)
                ofname = argv[i]
                if len(ofname) < 5 or not ofname.endswith(".wav"):
                    eprintf("%s: name of output file must end in '.wav'\n",
                            pname)
                    raise Exit(1)
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            else:
                eprintf("%s: unrecognized option %s\n", pname, a)
                raise Exit(1)
        else:
            eprintf("%s: unrecognized argument %s\n", pname, a)
            raise Exit(1)
        i += 1
    if ofname is None or record is None:
        help(pname)
        raise Exit(1)
    if nrec is not None and record == nrec:
        eprintf("%s: names of input and output records must not be "
                "identical\n", pname)
        raise Exit(1)
    nsig = w.isigopen(record, None, 0)
    if nsig <= 0:
        raise Exit(2)
    s = []
    nsig = w.isigopen(record, s, nsig)
    if nsig <= 0:
        raise Exit(3)
    # wfdb-x: no default frequency (legacy mode: no check, as in C)
    if not legacy() and w.sampfreq(None) <= 0.0:
        freq_not_specified(pname, record)
        raise Exit(3)
    if nrec is not None and w.newheader(nrec) < 0:
        raise Exit(3)
    bitspersample = 0
    offset = [0] * nsig
    shift = [0] * nsig
    for k in range(nsig):
        si = s[k]
        if si.adcres > bitspersample:
            bitspersample = si.adcres
        offset[k] = si.adczero
        si.adczero = 0
        shift[k] = 16 - si.adcres
        si.adcres = 16
        mag = int32(1 << shift[k]) if shift[k] >= 0 else 0
        si.gain *= mag
        si.baseline -= offset[k]
        si.baseline = int32(si.baseline * mag)
        si.fname = ofname
        si.group = 0
        si.fmt = 16
        si.spf = 1
    nsamp = w.strtim("e")
    sps = w.strtim("1")
    framelen = nsig * 2
    if w.osigfopen(s, nsig) < nsig:
        raise Exit(4)
    for k in range(nsig):
        w.wfdbsetstart(k, WAVHDRLEN)
    # The RIFF chunk size counts the samples and the rest of the header
    # (WAVHDRLEN - 8 bytes); the format chunk has 16 bytes, format tag 1.
    hdr = b"".join([b"RIFF", _u32(nsamp * framelen + WAVHDRLEN - 8),
                    b"WAVEfmt ", _u32(16), _u16(1), _u16(nsig), _u32(sps),
                    _u32(sps * framelen), _u16(framelen),
                    _u16(bitspersample), b"data", _u32(nsamp * framelen)])
    x = [0] * nsig
    y = [0] * nsig
    while w.getvec(x) == nsig:
        for k in range(nsig):
            y[k] = int32((x[k] - offset[k]) << shift[k]) if shift[k] >= 0 \
                else int32((x[k] - offset[k]) >> -shift[k])
        if w.putvec(y) != nsig:
            break
    w.setsampfreq(w.sampfreq(None))
    if nrec is not None:
        w.newheader(nrec)
    w.wfdbquit()
    # Prepend the wav header to the signal file (the C version does this
    # using a temporary file and the 'mv', 'cat', and 'rm' commands).
    try:
        with open(ofname, "rb") as f:
            data = f.read()
    except OSError:
        data = b""
    with open(ofname, "wb") as f:
        f.write(hdr + data)
    return 0


def main(argv=None):
    """Run mit2wav as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["mit2wav"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["mit2wav"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
