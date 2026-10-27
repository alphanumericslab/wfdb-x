"""wrann: translate an ASCII annotation file (as made by rdann) to binary.

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of app/wrann.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: none, apart from the language and the --legacy
option (as the first argument, it restores the original behavior).

Original C program: app/wrann.c, WFDB Software Package 10.7.0.
  Copyright (C) 1983-2010 George B. Moody; revised 2018 by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

import wfdbx as w
from wfdbx._cstd import fgets_lines, int8, uint8, int32, sscanf
from ._common import Exit, eprintf, run

LINELEN = 400           # size of the input line buffer (fgets), as in C
AUXBUFLEN = 256         # size of the aux string buffer, as in C


def help(pname):
    eprintf("usage: %s -r RECORD -a ANNOTATOR <TEXT-FILE\n", pname)
    eprintf("TEXT-FILE should be in the format produced by `rdann'.\n")


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    record = ainame = None
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "a":
                i += 1
                if i >= argc:
                    eprintf("%s: annotator must follow -a\n", pname)
                    raise Exit(1)
                ainame = argv[i]
            elif c == "h":
                help(pname)
                raise Exit(0)
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: input record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            else:
                eprintf("%s: unrecognized option %s\n", pname, a)
                raise Exit(1)
        else:
            eprintf("%s: unrecognized argument %s\n", pname, a)
            raise Exit(1)
        i += 1
    if record is None or ainame is None:
        help(pname)
        raise Exit(1)
    w.setafreq(w.sampfreq(record))
    if w.annopen(record, [w.Anninfo(ainame, w.WFDB_WRITE)], 1) < 0:
        raise Exit(2)
    annot = w.Annotation()
    # These variables keep their values from line to line, as in the C
    # version (sscanf leaves them unchanged when a conversion fails).
    tm = sub = ch = nm = 0
    annstr = ""
    data = sys.stdin.buffer.read()
    for line in fgets_lines(data, LINELEN):
        p = 9           # skip the time column (as C does)
        n = len(line)
        if line.startswith("["):
            while p < n and line[p] != "]":
                p += 1
        while p < n and line[p] != " ":
            p += 1
        rest = line[p + 1:]
        cnt, vals = sscanf(rest, "%lld%s%d%d%d")
        for k, v in enumerate(vals):
            if k == 0:
                tm = v
            elif k == 1:
                annstr = v
            elif k == 2:
                sub = int32(v)
            elif k == 3:
                ch = int32(v)
            elif k == 4:
                nm = int32(v)
        annot.anntyp = w.strann(annstr)
        if line.startswith("["):
            annot.time = -w.strtim(line)
            if annot.time < 0:
                continue
        else:
            annot.time = tm
        annot.subtyp = int8(sub)
        annot.chan = uint8(ch)
        annot.num = int8(nm)
        if annot.anntyp == w.NOTQRS:
            annot.anntyp = w.NOTE
            astr = annstr
        else:
            # C empties its mnemonic buffer here, so a later line without
            # a mnemonic writes a NOTE annotation.
            annstr = astr = ""
        k = rest.find("\t")
        ap = rest[k:] if k >= 0 else None
        if ap is not None:
            if len(astr) + len(ap) + 2 > AUXBUFLEN:
                ap = ap[:AUXBUFLEN - len(astr) - 3]
            else:
                ap = ap[:-1]
        if astr or ap is not None:
            if astr and ap is not None:
                s = "%s %s" % (astr, ap[1:])
            elif astr:
                s = astr
            else:
                s = ap[1:]
            b = s.encode("latin-1")
            annot.aux = bytes((len(b) & 0xFF,)) + b
        else:
            annot.aux = None
        w.putann(0, annot)
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run wrann as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["wrann"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["wrann"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
