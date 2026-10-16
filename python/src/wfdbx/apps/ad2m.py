"""ad2m: convert an AHA-format signal file to MIT format.

Copyright (C) 1983-2007 George B. Moody (original C program, convert/ad2m.c).
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
from wfdbx._cstd import int32, sscanf
from ._common import Exit, eprintf, legacy, legacy_help, run
from .a2m import redirect_stdin, basename_record

EODF = 0o100000
HELP = [
    "usage: %s -i AHAFILE [ OPTIONS ... ]\n",
    "where AHAFILE is the name of the AHA-format input signal file,",
    "and OPTIONS may include:",
    " -c         process a compressed input file (default if AHAFILE ends",
    "             with .CMP or .cmp;  otherwise old AHA tape format assumed)",
    " -f TIME    begin at specified TIME (default: 0, i.e., the beginning",
    "             of the input file)",
    " -F FREQ    sampling frequency in Hz (required; AHA database: 250)",
    " -G GAIN    gain in adu per physical unit (required; AHA database: 400)",
    " -h         print this usage summary",
    " -r RECORD  specify the name of the output RECORD (default: use the,"
    "            input file name, less path info and extension, as RECORD)",
    " -R BITS    ADC resolution in bits (required; AHA database: 12)",
    " -t TIME    stop at specified TIME (default: 35 minutes after the",
    "             starting time if RECORD=x2xx or x3xx, 3 hours if",
    "             RECORD=x0xx or x1xx, or the end of the input file)",
    " -U UNITS   physical units (required unless the gain is 0; AHA: mV)",
]

# wfdb-x: the help text of the original program, printed in legacy mode
LEGACY_HELP = legacy_help(HELP, {
    " -F FREQ    sampling frequency in Hz (required; AHA database: 250)": None,
    " -G GAIN    gain in adu per physical unit (required; AHA database: 400)":
    None,
    " -R BITS    ADC resolution in bits (required; AHA database: 12)": None,
    " -U UNITS   physical units (required unless the gain is 0; AHA: mV)":
    None})


def help(pname):
    hs = LEGACY_HELP if legacy() else HELP     # wfdb-x
    eprintf(hs[0], pname)
    for s in hs[1:]:
        eprintf("%s\n", s)


class _CReader:
    """getcvec(): decode the compressed AHA signal format from stdin."""

    def __init__(self, f):
        self.f = f
        self.v0 = 0
        self.v1 = 0

    def getchar(self):
        b = self.f.read(1)
        return b[0] if b else -1

    def getcvec(self, v):
        """Read the first differences of the two signals: if the high bit
        of the first byte is 0, two bytes hold 7-bit and 8-bit differences;
        otherwise four bytes hold 15-bit and 16-bit differences."""
        x = self.getchar()
        if x < 0:
            return 0
        y = self.getchar()
        if y < 0:
            eprintf("unexpected EOF in input file\n")
            return 0
        if (x & 0x80) == 0:
            self.v0 += x & 0x7F
            if x & 0x40:
                self.v0 -= 128
            self.v1 += y
            if y & 0x80:
                self.v1 -= 256
        else:
            if x & 0x40:
                x |= ~0x3F
            else:
                x &= 0x7F
            self.v0 += (x << 8) + y
            x = self.getchar()
            y = self.getchar() if x >= 0 else -1
            if x < 0 or y < 0:
                eprintf("unexpected EOF in input file\n")
                return 0
            if x & 0x80:
                x |= ~0xFF
            self.v1 += (x << 8) + y
        self.v0 = int32(self.v0)
        self.v1 = int32(self.v1)
        v[0] = self.v0
        v[1] = self.v1
        return 2


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    cflag = 0
    # wfdb-x: -F, -G, -R and -U (C assumed 250 Hz, 400 adu/mV, 12 bits and
    # millivolts); -f and -t are converted once -F is known.
    uunits = fstr = tstr = None
    ffreq = ggain = 0.0
    gset = rres = 0
    if legacy():
        # wfdb-x: in legacy mode, the parameters of the AHA database, set by
        # the C program (250 Hz, 400 adu/mV, 12 bits, and no units, i.e.,
        # millivolts); -F, -G, -R and -U are not options then.
        ffreq, ggain, gset, rres = 250.0, 400.0, 1, 12
        w.setsampfreq(250.0)
    ifname = record = None
    t = start_time = end_time = 0
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "c":
                cflag = 1
            elif c == "f":
                i += 1
                if i >= argc:
                    eprintf("%s: start time must follow -f\n", pname)
                    raise Exit(1)
                if legacy():    # wfdb-x: as in the C program
                    start_time = w.strtim(argv[i])
                else:
                    fstr = argv[i]  # converted once -F is known
            elif c == "h":
                help(pname)
                raise Exit(1)
            elif c == "i":
                i += 1
                if i >= argc:
                    eprintf("%s: name of AHA-format input file must follow "
                            "-i\n", pname)
                    raise Exit(1)
                ifname = argv[i]
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            elif c == "t":
                i += 1
                if i >= argc:
                    eprintf("%s: end time must follow -t\n", pname)
                    raise Exit(1)
                if legacy():    # wfdb-x: as in the C program
                    end_time = w.strtim(argv[i])
                else:
                    tstr = argv[i]  # converted once -F is known
            elif c == "F" and not legacy():    # sampling frequency (wfdb-x)
                i += 1
                n, v = sscanf(argv[i], "%lf") if i < argc else (0, [])
                if n != 1 or v[0] <= 0.0:
                    eprintf("%s: sampling frequency (> 0) must follow -F\n",
                            pname)
                    raise Exit(1)
                ffreq = v[0]
            elif c == "G" and not legacy():    # gain (wfdb-x)
                i += 1
                n, v = sscanf(argv[i], "%lf") if i < argc else (0, [])
                if n != 1 or v[0] < 0.0:
                    eprintf("%s: gain (>= 0) must follow -G\n", pname)
                    raise Exit(1)
                ggain = v[0]
                gset = 1
            elif c == "R" and not legacy():    # ADC resolution (wfdb-x)
                i += 1
                n, v = sscanf(argv[i], "%d") if i < argc else (0, [])
                if n != 1 or not 1 <= int32(v[0]) <= 32:
                    eprintf("%s: ADC resolution (1-32 bits) must follow -R\n",
                            pname)
                    raise Exit(1)
                rres = int32(v[0])
            elif c == "U" and not legacy():    # physical units (wfdb-x)
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
    # wfdb-x: the signal parameters must be given explicitly; C assumed
    # those of the AHA database (250 Hz, 400 adu/mV, 12 bits, and no units,
    # i.e., millivolts), as legacy mode does (the values set above for legacy
    # mode pass these checks, and no units are required then).
    if ffreq <= 0.0:
        eprintf("%s: the sampling frequency must be specified (-F)\n", pname)
        raise Exit(1)
    if not gset:
        eprintf("%s: the gain must be specified (-G)\n", pname)
        raise Exit(1)
    if rres < 1:
        eprintf("%s: the ADC resolution must be specified (-R)\n", pname)
        raise Exit(1)
    if ggain != 0.0 and uunits is None and not legacy():
        eprintf("%s: the units must be specified (-U)\n", pname)
        raise Exit(1)
    w.setsampfreq(ffreq)
    if fstr is not None:
        start_time = w.strtim(fstr)
    if tstr is not None:
        end_time = w.strtim(tstr)
    if 0 < end_time <= start_time:
        help(pname)
        raise Exit(1)
    if cflag == 0 and len(ifname) > 4 and ifname[-4:] in (".CMP", ".cmp"):
        cflag = 1
    if not redirect_stdin(ifname, pname):
        eprintf("%s: can't read input file `%s'\n", pname, ifname)
        raise Exit(2)
    if record is None:
        record = basename_record(ifname)
    if end_time == 0 and len(record) == 4:
        if record[1] in "23":
            end_time = w.strtim("35:0")
        elif record[1] in "01":
            end_time = w.strtim("3:0:0")
    if end_time == 0:
        eprintf("%s: warning: end time not specified, output may be "
                "truncated\n", pname)
        eprintf("               rerun with -t TIME to override\n")
        end_time = start_time + w.strtim("100:0:0")
    dfname = "%s.dat" % record
    dfarray = [w.Siginfo(fname=dfname, desc="", gain=ggain, units=uunits,
                         fmt=212, adcres=rres, spf=0) for _ in range(2)]
    if w.osigfopen(dfarray, 2) < 0:
        raise Exit(3)
    v = [0, 0]
    if not cflag:
        if w.isigopen("16", dfarray, 2) < 2:
            raise Exit(2)
        if start_time > 0:
            t = start_time
            if w.isigsettime(t) < 0:
                raise Exit(2)
        while w.getvec(v) == 2 and v[0] != EODF and w.putvec(v) > 0:
            t += 1
            if not t < end_time:
                break
        w.newheader(record)
        while w.getvec(v) >= 0:
            pass
    else:
        R = _CReader(sys.stdin.buffer)
        while t < start_time and R.getcvec(v) == 2:
            t += 1
        while R.getcvec(v) == 2 and w.putvec(v) > 0:
            t += 1
            if not t < end_time:
                break
        w.newheader(record)
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run ad2m as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["ad2m"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["ad2m"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
