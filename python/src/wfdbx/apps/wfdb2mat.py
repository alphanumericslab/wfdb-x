"""wfdb2mat: convert a WFDB record into a MATLAB/Octave .mat file.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of convert/wfdb2mat.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: no built-in sampling frequency, gain or units: the
record must give the sampling frequency (the original assumed 250 Hz),
uncalibrated signals stay uncalibrated in the output header (the original wrote
200 adu/mV), and unspecified units are written as "nd" (the original wrote
"mV"); --legacy, as the first argument, restores the original behavior. Each
change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.

Original C program: convert/wfdb2mat.c, WFDB Software Package 10.7.0.
  Copyright (C) 2009-2013 George B. Moody; revised 2014-2021 by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

import wfdbx as w
from wfdbx._signal import WFDB_TIME_MAX
from ._common import (Output, Exit, eprintf, freq_not_specified, legacy,
                      legacy_gains, run)

# Output .mat data storage types (sub4 tag), from the .mat specification.
MAT8 = 2                # 8 bits per sample unsigned (miUINT8)
MAT16 = 3               # 16 bits per sample signed (miINT16)
MAT32 = 5               # 32 bits per sample signed (miINT32)
MASTERTYPE = 14         # miMATRIX
SUB1TYPE = 6            # miUINT32 (array flags)
SUB1CLASS = 6           # mxDOUBLE_CLASS (the class of the MATLAB array)
SUB2TYPE = 5            # miINT32 (dimensions)
SUB3TYPE = 1            # miINT8 (array name)
FIELDVERSION = 0x0100   # .mat file version
PROLOGLEN = 192         # length of the .mat file prolog

HELP = [
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -l INTERVAL truncate output after the specified time interval "
    "(hh:mm:ss)",
    " -s SIGNAL   [SIGNAL ...]  convert only the specified signal(s)",
    " -S SIGNAL   search for a valid sample of the specified SIGNAL at or "
    "after",
    "\t\tthe time specified with -f, and begin converting then",
    " -t TIME     stop at specified time",
    "Outputs are written to the current directory as RECORD.mat and "
    "RECORDm.hea.",
]


def help(pname):
    eprintf(HELP[0], pname)
    for s in HELP[1:]:
        eprintf("%s\n", s)


def _main(argv, out):
    pname = argv[0]
    argc = len(argv)
    record = search = None
    highres = 0
    nosig = isiglist = 0
    frm = maxl = to = 0
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "f":
                i += 1
                if i >= argc:
                    eprintf("%s: time must follow -f\n", pname)
                    raise Exit(1)
                frm = i
            elif c == "h":
                help(pname)
                raise Exit(0)
            elif c == "H":
                highres = 1
            elif c == "l":
                i += 1
                if i >= argc:
                    eprintf("%s: max output length must follow -l\n", pname)
                    raise Exit(1)
                maxl = i
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            elif c == "s":
                isiglist = i + 1
                while i + 1 < argc and not argv[i + 1].startswith("-"):
                    i += 1
                    nosig += 1
                if nosig == 0:
                    eprintf("%s: signal list must follow -s\n", pname)
                    raise Exit(1)
            elif c == "S":
                i += 1
                if i >= argc:
                    eprintf("%s: signal name or number must follow -S\n",
                            pname)
                    raise Exit(1)
                search = argv[i]
            elif c == "t":
                i += 1
                if i >= argc:
                    eprintf("%s: time must follow -t\n", pname)
                    raise Exit(1)
                to = i
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
    nisig = w.isigopen(record, None, 0)
    if nisig <= 0:
        raise Exit(2)
    si = []
    nisig = w.isigopen(record, si, nisig)
    if nisig <= 0:
        raise Exit(2)
    vi = [0] * nisig
    # WFDB-x: uncalibrated signals remain uncalibrated in the output (C
    # assumed 200 adu/mV), and the output header needs the sampling
    # frequency (C assumed 250 Hz).  Legacy mode: as in the C program.
    if legacy():
        legacy_gains(si)
    if highres:
        w.setgvmode(w.WFDB_HIGHRES)
    freq = w.sampfreq(None)
    if freq <= 0.0 and not legacy():
        freq_not_specified(pname, record)
        raise Exit(2)
    if frm > 0:
        frm = w.strtim(argv[frm])
        if frm < 0:
            frm = -frm
    if w.isigsettime(frm) < 0:
        raise Exit(2)
    if to > 0:
        to = w.strtim(argv[to])
        if to < 0:
            to = -to
    if nosig:
        sig = []
        for k in range(nosig):
            s = w.findsig(argv[isiglist + k])
            if s < 0:
                eprintf("%s: can't read signal '%s'\n", pname,
                        argv[isiglist + k])
                raise Exit(2)
            sig.append(s)
    else:
        nosig = nisig
        sig = list(range(nosig))
    if search is not None:
        s = w.findsig(search)
        if s >= 0:
            frm = w.tnextvec(s, frm)
        if s < 0 or frm < 0:
            eprintf("%s: can't read signal '%s'\n", pname, search)
            raise Exit(2)
    if maxl > 0:
        maxl = w.strtim(argv[maxl])
        if maxl < 0:
            maxl = -maxl
    if maxl and (to == 0 or to > frm + maxl):
        to = frm + maxl
    t = w.strtim("e")
    if t == 0:
        w.wfdbquiet()
        lower = 0
        upper = WFDB_TIME_MAX
        t = 16 * 1024
        while lower < upper:    # find the length by a binary search
            if w.isigsettime(t) >= 0 and w.getvec(vi) > 0:
                lower = t + 1
            else:
                upper = t
            if upper == WFDB_TIME_MAX and t < WFDB_TIME_MAX // 2:
                t *= 2
            else:
                t = lower + (upper - lower) // 2
        w.wfdbverbose()
        if w.isigsettime(frm) < 0:
            raise Exit(2)
    if to == 0 or to > t:
        to = t
    if to <= frm:
        w.wfdbquit()
        eprintf("%s: no output\n", pname)
        eprintf(" Use the -f and -t options to specify time limits\n"
                "(or type '%s -h' for help)\n", pname)
        raise Exit(1)
    sfname = 1 if record.endswith("/") else 0
    p = len(record) - 1
    while True:
        p -= 1
        if not p > 0:
            break
        if record[p] == "/":
            p += 1
            break
    if p < 0:
        p = 0
    base = record[p:]
    orec = base[:len(base) - sfname].replace(".", "_") + "m"
    matname = "%s.mat" % orec
    nbytes = 1
    for k in range(nosig):
        s = si[sig[k]]
        if s.adcres > 0:
            if s.adcres > 16:
                nbytes = 4
            elif s.adcres > 8 and nbytes < 2:
                nbytes = 2
        else:
            if s.fmt in (24, 32):
                nbytes = 4
            elif s.fmt != 80 and nbytes < 2:
                nbytes = 2
    if nbytes == 1:
        sub4type, wfdbtype = MAT8, 80
    elif nbytes == 2:
        sub4type, wfdbtype = MAT16, 16
    else:
        sub4type, wfdbtype = MAT32, 32
    so = []
    for k in range(nosig):
        o = si[sig[k]].copy()
        o.fname = matname
        o.group = 0
        o.spf = 1
        o.fmt = wfdbtype
        o.adczero = 0
        o.baseline -= si[sig[k]].adczero
        if o.units is None:     # WFDB-x: not assumed to be millivolts
            o.units = "mV" if legacy() else "nd"    # (C, legacy mode: mV)
        elif len(o.units) == 0:
            o.units = "nd"
        so.append(o)
    # Ensure the signal size does not exceed the 2^31 byte limit.
    max_length = 2147483648 // nbytes // nosig
    if (to - frm) > max_length:
        eprintf("%s: cannot write mat file - data size exceeds 2GB limit\n",
                pname)
        raise Exit(1)
    # nbytesmaster (the size of all content after the master tag) =
    # (8 + 8) + (8 + 8) + (8 + 8) + (8 + nbytesofdata) + padding to a
    # multiple of 8 bytes.
    nbytesofdata = nbytes * nosig * (to - frm)
    lremain = nbytesofdata % 8
    if lremain == 0:
        nbytesmaster = nbytesofdata + 56
    else:
        nbytesmaster = nbytesofdata + 64 - lremain
        for o in so:
            o.bsize = 8
    if w.osigfopen(so, nosig) != nosig:
        w.wfdbquit()
        raise Exit(1)
    # The .mat file prolog: a 128-byte header, the 8-byte master tag, and
    # 56 bytes of subelements (bytes not set below are zero).
    prolog = bytearray(PROLOGLEN)

    def put32(off, x):
        prolog[off:off + 4] = (x & 0xFFFFFFFF).to_bytes(4, "little")

    prolog[0:10] = b"MATLAB 5.0"        # descriptive text
    prolog[124] = FIELDVERSION & 0xFF   # version (0x0100)
    prolog[125] = FIELDVERSION >> 8
    prolog[126:128] = b"IM"             # little-endian
    prolog[128] = MASTERTYPE            # master tag: type and size
    put32(132, nbytesmaster)
    prolog[136] = SUB1TYPE              # subelement 1: array flags
    prolog[140] = 8
    prolog[144] = SUB1CLASS
    prolog[152] = SUB2TYPE              # subelement 2: dimensions
    prolog[156] = 8
    put32(160, nosig)                   # rows
    put32(164, to - frm)                # columns
    prolog[168] = SUB3TYPE              # subelement 3: array name
    prolog[172] = 3
    prolog[176:179] = b"val"
    prolog[184] = sub4type              # subelement 4: the data
    put32(188, nbytesofdata)
    w.wfdbputprolog(bytes(prolog), PROLOGLEN, 0)
    vo = [0] * nosig
    stat = 0
    t = frm
    while t < to and stat >= 0:
        stat = w.getvec(vi)
        for k in range(nosig):
            vo[k] = vi[sig[k]] - si[sig[k]].adczero
        if w.putvec(vo) != nosig:
            break
        t += 1
    if t != to:
        eprintf("%s (warning): final %d columns are invalid\n", pname, to - t)
        for k in range(nosig):
            vo[k] = w.WFDB_INVALID_SAMPLE
        while t < to:
            t += 1
            w.putvec(vo)
    w.setsampfreq(freq)
    p = w.mstimstr(-frm)
    if p.startswith("["):
        w.setbasetime(p[1:])
    w.newheader(orec)
    p = w.getinfo(None)
    while p is not None:
        w.putinfo(p)
        p = w.getinfo(None)
    w.putinfo("Creator: %s" % pname)
    p = "Source: record %s" % record
    q = w.mstimstr(0).lstrip(" ")
    if frm != 0 or q.startswith("["):
        p += "  Start: " + q
    w.putinfo(p)
    offset = 128 if wfdbtype == 80 else 0   # format 80 is offset binary
    out.write("%s\n" % p)
    out.write("val has %d row%s (signal%s) and %d column%s (sample%s/signal)"
              "\n" % (nosig, "" if nosig == 1 else "s",
                      "" if nosig == 1 else "s", to - frm,
                      "" if to == frm + 1 else "s",
                      "" if to == frm + 1 else "s"))
    out.write("Duration: %s\n" % w.timstr(to - frm))
    out.write("Sampling frequency: %s Hz  Sampling interval: %s sec\n" % (
        "%.12g" % freq, "%.10g" % (1 / freq)))
    out.write("Row\tSignal\tGain\tBase\tUnits\n")
    for k in range(nosig):
        out.write("%d\t%s\t%s\t%d\t%s\n" % (k + 1, so[k].desc,
                                            "%.12g" % so[k].gain,
                                            so[k].baseline + offset,
                                            so[k].units))
    out.write("\nTo convert from raw units to the physical units shown\n"
              "above, call the 'rdmat.m' function from the wfdb-matlab\n"
              "toolbox: https://physionet.org/physiotools/matlab/"
              "wfdb-app-matlab/\n")
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run wfdb2mat as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["wfdb2mat"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["wfdb2mat"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
