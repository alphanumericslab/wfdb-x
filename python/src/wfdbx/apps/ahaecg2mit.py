"""ahaecg2mit: convert AHA DB files (from the AHA DVD) to WFDB format.

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of convert/ahaecg2mit.c from the WFDB Software
Package 10.7.0, by George B. Moody. The translation follows the logic and
behavior of the original program, but it is new code, not the original C code.

Changes from the original: no built-in signal parameters: the new options -F
FREQ, -G GAIN, -R BITS and -U UNITS give the sampling frequency, gain, ADC
resolution and units, and are required (-U unless the gain is 0; the original
assumed those of the AHA database: 250 Hz, 400 adu/mV, 12 bits and millivolts);
the options precede the input files, in any order; the short-format part of a
long-format file (skipped by -s) is located from -F; --legacy, as the first
argument, restores the original behavior. Each change is marked "wfdb-x:" in
the code; docs/DIVERGENCES.md gives the reasons.

Original C program: convert/ahaecg2mit.c, WFDB Software Package 10.7.0.
  By George B. Moody (2008); revised 2017 by Benjamin Moody. The C source has
  no copyright or license notice.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

import wfdbx as w
from wfdbx._cstd import sscanf, int32, int8
from ._common import Exit, eprintf, legacy, run


# A long-format AHA record begins with 145 minutes that are not part of the
# short-format (35-minute) record; each sample frame of a binary (.ecg) file
# is 5 bytes long.
SKIPMIN = 145           # minutes skipped by -s (to make a short record)
BINFRAMELEN = 5         # bytes per frame of a binary (.ecg) input file


class _Conv:
    """The input file and conversion state of one AHA DVD record."""

    def __init__(self, f, fmt, params):
        self.f = f
        # wfdb-x: the signal parameters (-F, -G, -R, -U); C assumed those of
        # the AHA database (250 Hz, 400 adu/mV, 12 bits, millivolts).
        self.freq, self.gain, self.res, self.units = params
        self.format = fmt
        self.a = w.Annotation()
        self.v = [0, 0]
        # readtxtdata() reads each line into a 16-byte buffer that keeps the
        # contents of previous (longer) lines; it is not NUL-terminated.
        self.buf = bytearray(16)

    def readbindata(self):
        # Two 16-bit samples (little-endian) and an AHA annotation code
        # ('.' if none).
        data = self.f.read(BINFRAMELEN)
        if len(data) != BINFRAMELEN:
            return 0
        d = [int8(x) for x in data]
        self.v[0] = (d[0] & 0xFF) | ((d[1] << 8) & 0xFF00)
        self.v[1] = (d[2] & 0xFF) | ((d[3] << 8) & 0xFF00)
        if data[4] == ord("."):
            return 1
        self.a.anntyp = w.ammap(d[4])
        self.a.subtyp = -1 if data[4] == ord("U") else 0
        return 2

    def readtxtdata(self):
        c = None
        for i in range(16):
            b = self.f.read(1)
            c = int8(b[0]) if b else -1
            if c in (13, -1, 10):       # '\r', EOF, '\n'
                break
            self.buf[i] = c & 0xFF
        if c == -1:
            return 0
        k = self.buf.find(0)
        s = bytes(self.buf if k < 0 else self.buf[:k]).decode("latin-1")
        n, vals = sscanf(s, "%d,%d,\"%c")
        if len(vals) > 0:
            self.v[0] = int32(vals[0])
        if len(vals) > 1:
            self.v[1] = int32(vals[1])
        if n < 3:
            cc = vals[2] if len(vals) > 2 else chr(c & 0xFF)
            eprintf("Error: improperly formatted input!\n")
            eprintf(" n = %d, buf = |%s|, v[0] = %d, v[1] = %d, c = |%s|\n",
                    n, s, self.v[0], self.v[1], cc)
            return 0
        c = vals[2]
        if c == '"':
            return 1
        self.a.anntyp = w.ammap(int8(ord(c)))
        self.a.subtyp = -1 if c == "U" else 0
        return 2

    def process(self, record):
        w.setsampfreq(self.freq)        # wfdb-x: -F (C set 250 Hz)
        ofname = "%s.dat" % record
        si0 = w.Siginfo(fname=ofname, desc="ECG0", units=self.units,
                        gain=self.gain, fmt=212, adcres=self.res, spf=0)
        si1 = si0.copy()
        si1.desc = "ECG1"
        if w.osigfopen([si0, si1], 2) != 2 or \
                w.annopen(record, [w.Anninfo("atr", w.WFDB_WRITE)], 1) < 0:
            w.wfdbquit()
            return
        t = -1
        if self.format == 1:
            while True:
                stat = self.readbindata()
                if not stat:
                    break
                w.putvec(self.v)
                if stat > 1:
                    self.a.time = t
                    w.putann(0, self.a)
                t += 1
        else:
            while True:
                stat = self.readtxtdata()
                if not stat:
                    break
                t += 1
                w.putvec(self.v)
                if stat > 1:
                    self.a.time = t
                    w.putann(0, self.a)
        w.newheader(record)
        w.wfdbquit()
        eprintf("wrote %s.atr, %s.dat, and %s.hea\n", record, record, record)


def _main(argv):
    argv = list(argv)       # the C version modifies its arguments in place
    argc = len(argv)
    if argc < 2 or argv[1] == "-h":
        if legacy():    # wfdb-x: the usage of the C program
            eprintf("usage: %s [-s] RECORD.XXX [RECORD.XXX]...\n", argv[0])
        else:
            eprintf("usage: %s [-s] -F FREQ -G GAIN -R BITS -U UNITS"
                    " RECORD.XXX [RECORD.XXX]...\n", argv[0])
        eprintf(" where RECORD.XXX is the name of the AHA DVD input file to"
                " be converted\n"
                " ('RECORD' is one of the 4-digit AHA DB record names, and"
                " 'XXX' may be either\n 'ecg' or 'txt', depending on the"
                " version of the AHA DVD.)\n"
                " Output files are RECORD.hea (text), RECORD.atr (binary),"
                " RECORD.dat (binary).\n"
                " Two or more input files may be converted in a single run.\n"
                " Use -s to make short-format (35-minute) records from"
                " long-format (2.5 hour)\n input files.  When using -s, the"
                " second digit in the output record name is\n"
                " incremented by 2.\n")
        if not legacy():
            eprintf(" -F, -G, -R and -U give the sampling frequency (Hz), gain"
                    " (adu per physical\n unit), ADC resolution (bits) and"
                    " units of the signals; for the AHA DVD\n files, use -F"
                    " 250 -G 400 -R 12 -U mV.\n")
        raise Exit(1)
    # wfdb-x: options (-s and the signal parameters) precede the input
    # files, in any order.
    pname = argv[0]
    sflag = 0
    ffreq = ggain = 0.0
    gset = rres = 0
    uunits = None
    i = 1
    if legacy():
        # wfdb-x: in legacy mode, the option of the C program (-s only, as
        # the first argument), and the parameters of the AHA database that it
        # set (250 Hz, 400 adu/mV, 12 bits, millivolts).
        if argv[1] == "-s":
            sflag = 1   # produce short-format (35-minute) records
            i = 2
        ffreq, ggain, gset, rres, uunits = 250.0, 400.0, 1, 12, "mV"
    while not legacy() and i < argc and len(argv[i]) == 2 and \
            argv[i][0] == "-" and argv[i][1] in "sFGRU":
        c = argv[i][1]
        if c == "s":
            sflag = 1   # produce short-format (35-minute) records
        elif c == "F":  # sampling frequency (wfdb-x)
            i += 1
            n, v = sscanf(argv[i], "%lf") if i < argc else (0, [])
            if n != 1 or v[0] <= 0.0:
                eprintf("%s: sampling frequency (> 0) must follow -F\n",
                        pname)
                raise Exit(1)
            ffreq = v[0]
        elif c == "G":  # gain in adu per physical unit (wfdb-x)
            i += 1
            n, v = sscanf(argv[i], "%lf") if i < argc else (0, [])
            if n != 1 or v[0] < 0.0:
                eprintf("%s: gain (>= 0) must follow -G\n", pname)
                raise Exit(1)
            ggain = v[0]
            gset = 1
        elif c == "R":  # ADC resolution in bits (wfdb-x)
            i += 1
            n, v = sscanf(argv[i], "%d") if i < argc else (0, [])
            if n != 1 or not 1 <= int32(v[0]) <= 32:
                eprintf("%s: ADC resolution (1-32 bits) must follow -R\n",
                        pname)
                raise Exit(1)
            rres = int32(v[0])
        elif c == "U":  # physical units (wfdb-x)
            i += 1
            if i >= argc:
                eprintf("%s: units must follow -U\n", pname)
                raise Exit(1)
            uunits = argv[i]
        i += 1
    # wfdb-x: the signal parameters must be given explicitly (see
    # docs/DIVERGENCES.md); in legacy mode, these checks pass.
    if ffreq <= 0.0:
        eprintf("%s: the sampling frequency must be specified (-F)\n", pname)
        raise Exit(1)
    if not gset:
        eprintf("%s: the gain must be specified (-G)\n", pname)
        raise Exit(1)
    if rres < 1:
        eprintf("%s: the ADC resolution must be specified (-R)\n", pname)
        raise Exit(1)
    if ggain != 0.0 and uunits is None:
        eprintf("%s: the units must be specified (-U)\n", pname)
        raise Exit(1)
    params = (ffreq, ggain, rres, uunits)
    while i < argc:
        name = argv[i]
        ext = name[-4:]
        if ext in (".ecg", ".ECG"):
            fmt = 1
        elif ext in (".txt", ".TXT"):
            fmt = 2
        else:
            eprintf("%s: ignoring '%s'\n", argv[0], name)
            i += 1
            continue
        try:
            f = open(name, "rb")
        except OSError:
            eprintf("%s: can't open '%s'\n", argv[0], argv[1])
            i += 1
            continue
        argv[i] = name[:-4]     # (*p = '\0' strips the extension)
        record = name[:-4][-4:]
        C = _Conv(f, fmt, params)
        if sflag:   # skip the first 145 minutes to make a short record
            nskip = int(SKIPMIN * 60 * ffreq)     # samples (C: long)
            if fmt == 1:
                f.seek(nskip * BINFRAMELEN, 0)
            else:
                for t in range(nskip):
                    C.readtxtdata()
            # (a record name shorter than 2 characters is left unchanged)
            if len(record) > 1:
                record = record[0] + chr((ord(record[1]) + 2) & 0xFF) + \
                    record[2:]
        C.process(record)
        f.close()
        i += 1
    return 0


def main(argv=None):
    """Run ahaecg2mit as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["ahaecg2mit"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["ahaecg2mit"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
