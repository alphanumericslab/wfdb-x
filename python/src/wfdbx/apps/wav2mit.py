"""wav2mit: create a header file for a .wav file, so it can be read as a record.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of convert/wav2mit.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: no built-in gain or units: the new options -G GAIN
(required) and -U UNITS (required unless the gain is 0) give them (the original
wrote 12.5 adu/mV for 8-bit and 6400 adu/mV for 16-bit files, in millivolts);
--legacy, as the first argument, restores the original behavior. Each change is
marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.

Original C program: convert/wav2mit.c, WFDB Software Package 10.7.0.
  Copyright (C) 2003-2004 George B. Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

import wfdbx as w
from wfdbx._cstd import int16, sscanf
from ._common import Exit, eprintf, legacy, legacy_help, run

WAVHDRLEN = 44          # length of the .wav header (RIFF, fmt and data)

HELP = [
    "usage: %s -i FILE.wav -r RECORD [ OPTIONS ... ]\n",
    "where FILE.wav is the name of the wav-format input signal file,",
    "and OPTIONS may include:",
    " -G GAIN    gain in adu per physical unit (required; 0: uncalibrated)",
    " -h         print this usage summary",
    " -r RECORD  create RECORD.hea (default: FILE.hea)",
    " -U UNITS   physical units (required unless the gain is 0)",
]

# WFDB-x: the help text of the original program, printed in legacy mode
LEGACY_HELP = legacy_help(HELP, {
    " -G GAIN    gain in adu per physical unit (required; 0: uncalibrated)":
    None,
    " -U UNITS   physical units (required unless the gain is 0)": None})


def help(pname):
    hs = LEGACY_HELP if legacy() else HELP     # WFDB-x
    eprintf(hs[0], pname)
    for s in hs[1:]:
        eprintf("%s\n", s)


class _Reader:
    def __init__(self, f):
        self.f = f

    def in16(self):
        b = self.f.read(2)
        if len(b) < 2:
            return -1
        return int16(b[0] | (b[1] << 8))

    def in32(self):
        b = self.f.read(4)
        if len(b) < 4:
            return -1
        return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    ifname = record = None
    uunits = None       # WFDB-x: -U
    ggain = 0.0         # WFDB-x: -G
    gset = 0
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "G" and not legacy():  # gain (WFDB-x)
                i += 1
                n, v = sscanf(argv[i], "%lf") if i < argc else (0, [])
                if n != 1 or v[0] < 0.0:
                    eprintf("%s: gain (>= 0) must follow -G\n", pname)
                    raise Exit(1)
                ggain = v[0]
                gset = 1
            elif c == "h":
                help(pname)
                raise Exit(1)
            elif c == "i":
                i += 1
                if i >= argc:
                    eprintf("%s: name of wav-format input file must follow "
                            "-i\n", pname)
                    raise Exit(1)
                ifname = argv[i]
                if len(ifname) < 5 or not ifname.endswith(".wav"):
                    eprintf("%s: name of input file must end in '.wav'\n",
                            pname)
                    raise Exit(1)
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            elif c == "U" and not legacy():    # physical units (WFDB-x)
                i += 1
                if i >= argc:
                    eprintf("%s: units must follow -U\n", pname)
                    raise Exit(1)
                uunits = argv[i]
            else:
                eprintf("%s: unrecognized option %s\n", pname, a)
                raise Exit(1)
        else:
            eprintf("%s: unrecognized argument %s\n", pname, a)
            raise Exit(1)
        i += 1
    if ifname is None:
        help(pname)
        raise Exit(1)
    # WFDB-x: the gain and units must be given explicitly; C wrote 12.5
    # adu/mV for 8-bit and 6400 adu/mV for 16-bit files, with no units
    # (millivolts).  (The sampling frequency and the resolution are those
    # given in the file.)  Legacy mode: as in the C program.
    if not gset and not legacy():
        eprintf("%s: the gain must be specified (-G)\n", pname)
        raise Exit(1)
    if ggain != 0.0 and uunits is None and not legacy():
        eprintf("%s: the units must be specified (-U)\n", pname)
        raise Exit(1)
    if record is None:
        record = ifname[:-4]
    try:
        f = open(ifname, "rb")
    except OSError:
        eprintf("%s: can't open %s\n", pname, ifname)
        raise Exit(2)
    f.seek(0, 2)
    flen = f.tell()
    f.seek(0, 0)
    r = _Reader(f)
    if f.read(4) != b"RIFF":
        eprintf("%s: %s is not a .wav-format file\n", pname, ifname)
        raise Exit(3)
    ln = r.in32() + 8
    if ln != flen:
        eprintf("%s: header chunk of %s has incorrect length (%d, should be "
                "%d)\n", pname, ifname, ln, flen)
        raise Exit(3)
    if f.read(4) != b"WAVE":
        eprintf("%s: %s is not a .wav-format file\n", pname, ifname)
        raise Exit(3)
    if f.read(4) != b"fmt ":
        eprintf("%s: format chunk missing or corrupt in %s\n", pname, ifname)
        raise Exit(3)
    ln = r.in32()
    tag = r.in16()
    if ln != 16 or tag != 1:
        eprintf("%s: unsupported format %d in %s\n", pname, tag, ifname)
        raise Exit(3)
    nsig = r.in16()
    sps = float(r.in32())
    r.in32()
    framelen = r.in16()
    bitspersample = r.in16()
    if bitspersample <= 8:
        wres = 8
        if legacy():
            ggain = 12.5    # WFDB-x: the C program's gain
    elif bitspersample <= 16:
        wres = 16
        if legacy():
            ggain = 6400.0  # WFDB-x: the C program's gain
    else:
        eprintf("%s: unsupported resolution (%d bits/sample) in %s\n",
                pname, bitspersample, ifname)
        raise Exit(3)
    if framelen != nsig * wres // 8:
        eprintf("%s: format chunk of %s has incorrect frame length\n",
                pname, ifname)
        raise Exit(3)
    if f.read(4) != b"data":
        eprintf("%s: data chunk missing or corrupt in %s\n", pname, ifname)
        raise Exit(3)
    ln = r.in32()
    wnsamp = ln // framelen if framelen else 0
    f.close()
    s = []
    for k in range(nsig):
        s.append(w.Siginfo(fname=ifname, desc=None, units=uunits, gain=ggain,
                           initval=0, group=0,
                           fmt=16 if wres == 16 else 80, spf=1, bsize=0,
                           adcres=wres, adczero=0 if wres == 16 else 128,
                           nsamp=wnsamp, cksum=0))
        s[k].baseline = s[k].adczero
        w.wfdbsetstart(k, WAVHDRLEN)
    w.setsampfreq(sps)
    if w.setheader(record, s, nsig):
        raise Exit(4)
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run wav2mit as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["wav2mit"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["wav2mit"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
