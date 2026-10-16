"""makeid: make an AHA-format ID block for a record.

Copyright (C) 2003 George B. Moody (original C program, convert/makeid.c).
Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import sys

import wfdbx as w
from ._common import Exit, eprintf, run


def _p16(x):
    """A 16-bit integer in PDP-11 (little-endian) byte order."""
    return bytes((x & 0xFF, (x >> 8) & 0xFF))


def _p32(x):
    """A 32-bit integer in PDP-11 order (high 16-bit word first)."""
    return _p16((x >> 16) & 0xFFFF) + _p16(x & 0xFFFF)


def _main(argv):
    if len(argv) < 3:
        eprintf("usage: %s annotator record\n", argv[0])
        raise Exit(1)
    rec = argv[2]
    ln = len(rec)
    if ln > 8:
        eprintf("record name must be 8 characters or less\n")
        raise Exit(1)
    dfarray = []
    if w.wfdbinit(rec, [w.Anninfo(argv[1], w.WFDB_READ)], 1, dfarray, 2) < 1:
        raise Exit(2)
    nsamp = dfarray[0].nsamp
    annot = w.Annotation()
    w.getann(0, annot)
    first = annot.time
    last = 0
    nann = 1
    while w.getann(0, annot) >= 0:
        last = annot.time
        nann += 1
    w.wfdbquit()
    # The 512-byte ID block (byte numbers as in the C source).
    out = sys.stdout.buffer
    out.write(rec.encode("latin-1"))        # bytes 1-8: record ID
    if ln < 8:
        out.write(b"\0" * (8 - ln))
    eprintf("%s\n", rec)
    out.write(_p16(nann))                   # bytes 9-10: annotations
    eprintf("%d annotations\n", nann)
    out.write(b"\0" * 6)                    # bytes 11-16: unused
    out.write(_p32(0))                      # bytes 17-20: segment start
    eprintf("Annotated segment begins at sample 0\n")
    out.write(_p32(nsamp))                  # bytes 21-24: segment end
    eprintf("Annotated segment ends at sample %d\n", nsamp)
    # Bytes 25-26: 512-byte blocks of sample data (2 signals, 2 bytes per
    # sample, rounded upward).
    blocks = (nsamp + 127) >> 7
    out.write(_p16(blocks))
    eprintf("%d blocks of sample data\n", blocks)
    out.write(b"\0" * 6)                    # bytes 27-32: unused
    out.write(_p32(first))                  # bytes 33-36: first annotation
    eprintf("First annotation is at sample %d\n", first)
    out.write(_p32(last))                   # bytes 37-40: last annotation
    eprintf("Last annotation is at sample %d\n", last)
    # Bytes 41-42: 512-byte blocks of annotations (16 bytes each, rounded
    # upward).
    blocks = (nann + 31) >> 5
    out.write(_p16(blocks))
    eprintf("%d blocks of annotations\n", blocks)
    out.write(b"\0" * 6)                    # bytes 43-48: unused
    out.write(b"\0" * 464)                  # bytes 49-512: unused
    out.flush()
    return 0


def main(argv=None):
    """Run makeid as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["makeid"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["makeid"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
