"""readid: read an AHA-format ID block.

Copyright (C) 1983-2005 George B. Moody (original C program, convert/readid.c).
Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import sys

from wfdbx._cstd import atoi, sscanf, cdiv
from ._common import Output, Exit, eprintf, run


def _main(argv, out):
    if len(argv) < 3:
        eprintf("usage: %s data-block-size annot-block-size\n", argv[0])
        raise Exit(1)
    dasize = atoi(argv[1])
    ansize = atoi(argv[2])
    if dasize < 1:
        dasize = 1
    if ansize < 1:
        ansize = 1
    # The ID block written by makeid: the record ID (bytes 1-8), the number
    # of 512-byte blocks of sample data (bytes 25-26) and of annotations
    # (bytes 41-42).
    f = sys.stdin.buffer
    buf = bytearray(512)
    b = f.read(24)
    buf[:len(b)] = b
    k = bytes(buf).find(b"\0")
    n, v = sscanf(bytes(buf[:k]).decode("latin-1"), "%s")
    # (name[9] overflows in the C version for longer IDs; the whole ID is
    # printed there, as here.)
    name = v[0] if n == 1 else ""

    def g16():          # a 16-bit integer (little-endian; 0xFF at EOF)
        lo = f.read(1)
        hi = f.read(1)
        lo = lo[0] if lo else 0xFF
        hi = hi[0] if hi else 0xFF
        return (hi << 8) | lo

    dcount = cdiv(g16() * 512 + dasize - 1, dasize)
    f.read(14)
    acount = cdiv(g16() * 512 + ansize - 1, ansize)
    out.write("%s %d %d\n" % (name, dcount, acount))
    return 0


def main(argv=None):
    """Run readid as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["readid"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["readid"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
