"""edf2mit: convert EDF to MIT format.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of convert/edf2mit.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: none, apart from the language and the --legacy
option (as the first argument, it restores the original behavior).

Original C program: convert/edf2mit.c, WFDB Software Package 10.7.0.
  Copyright (C) 1996-2004 George B. Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

import wfdbx as w
from wfdbx._cstd import sscanf, int32, int16, cdiv, atoi, d2i, fdiv
from ._common import Output, Exit, eprintf, run

HELP = [
    "usage: %s [OPTIONS ...]\n",
    "where OPTIONS may include:",
    " -b          input is in big-endian byte order (default: little-endian)",
    " -h          print this usage summary",
    " -i EDFILE   read the specified European Data Format file",
    " -r RECORD   create the specified RECORD (default: input file name "
    "without",
    "              suffix)",
    " -s SIGNAL [SIGNAL ...]  copy only the specified signal(s) (use signal",
    "              numbers, beginning with zero;  default: copy all signals)",
    " -v          print debugging output",
    "This program reads an EDF file and creates MIT-format signal and header",
    "files containing the same data.",
]


_SPACE = ord(" ")


def gcd(x, y):
    """Approximate GCD of two frequencies (to 0.1% of the smaller one)."""
    tol = 0.001 * y if x > y else 0.001 * x
    while True:
        if x > y and x - y > tol:
            x -= y
        elif y > x and y - x > tol:
            y -= x
        else:
            return x


class FieldBuffer:
    """Emulates the fixed 81-byte buffer used to read EDF header fields.

    As in the C program, bytes beyond the field just read keep their previous
    contents, which can become part of a field's value.
    """

    def __init__(self, f, size=81):         # C: char buf[81]
        self.f = f
        self.buf = bytearray(size)

    def read(self, n, trim_from=None):
        """Read an n-byte field and strip its trailing spaces (from index
        trim_from, default n); return the index of its last character."""
        b = self.f.read(n)
        self.buf[:len(b)] = b
        if trim_from is None:
            trim_from = n
        if n < len(self.buf):
            self.buf[n] = _SPACE
        j = trim_from
        while j >= 0 and self.buf[j] == _SPACE:
            self.buf[j] = 0
            j -= 1
        return j

    def str(self):
        b = bytes(self.buf)
        k = b.find(b"\0")
        return (b if k < 0 else b[:k]).decode("latin-1")


def _main(argv, out):
    pname = argv[0]
    argc = len(argv)
    record = ""
    big_endian = vflag = 0
    siglist = []
    ifile = None
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "b":
                big_endian = 1
            elif c == "h":
                eprintf(HELP[0], pname)
                for s in HELP[1:]:
                    eprintf("%s\n", s)
                raise Exit(0)
            elif c == "i":
                i += 1
                if i < argc:
                    if argv[i] == "-":
                        ifile = sys.stdin.buffer
                    else:
                        try:
                            ifile = open(argv[i], "rb")
                        except OSError:
                            eprintf("%s: can't read %s\n", pname, argv[i])
                            raise Exit(1)
                        if record == "":
                            r = []
                            for ch in argv[i][:w.WFDB_MAXRNL]:
                                if ch.isascii() and ch.isalnum():
                                    r.append(ch)
                                elif ch == ".":
                                    break
                                else:
                                    r.append("_")
                            record = "".join(r)
            elif c == "r":
                i += 1
                if i < argc:
                    record = argv[i][:w.WFDB_MAXRNL]
                else:
                    eprintf("%s: record name must follow -r\n", pname)
                    raise Exit(1)
            elif c == "s":
                j = 0
                while True:
                    i += 1
                    if not (i < argc and not argv[i].startswith("-")):
                        break
                    j += 1
                if j == 0:
                    eprintf("%s: signal list must follow -s\n", pname)
                    raise Exit(1)
                i -= j
                while i < argc and not argv[i].startswith("-"):
                    siglist.append(atoi(argv[i]))
                    i += 1
                i -= 1
            elif c == "v":
                vflag = 1
        i += 1
    if ifile is None:
        eprintf(HELP[0], pname)
        for s in HELP[1:]:
            eprintf("%s\n", s)
        raise Exit(1)
    if record == "" or w.newheader(record) < 0:
        eprintf("\n")
        eprintf(HELP[0], pname)
        for s in HELP[1:]:
            eprintf("%s\n", s)
        eprintf("\nRun %s again, specifying a valid name for the output "
                "record,\n", argv[0])
        eprintf("using the -r option as described above.\n\n")
        eprintf("  Valid record names may include letters, digits, and "
                "underscores only.\n")
        raise Exit(1)
    fb = FieldBuffer(ifile)
    b = ifile.read(8)
    fb.buf[:len(b)] = b
    if bytes(fb.buf[:8]) != b"0       ":
        eprintf("%s: input does not appear to be EDF -- no conversion "
                "attempted.\n", pname)
        raise Exit(2)
    fb.buf[8] = _SPACE
    j = 8
    while j >= 0 and fb.buf[j] == _SPACE:
        fb.buf[j] = 0
        j -= 1

    def show(label):
        if vflag:
            out.write("%s: '%s'\n" % (label, fb.str()))

    show("EDF version number")
    fb.read(80)
    show("Patient ID")
    fb.read(80)
    show("Recording ID")
    fb.read(8)
    show("Recording date")
    _, v = sscanf(fb.str(), "%d%*c%d%*c%d")
    day, month, year = [(int32(x) if x is not None else 0)
                        for x in (v + [None] * 3)[:3]]
    if year < 1970:         # two-digit years denote 1970-2069
        year += 1900
    if year < 1970:
        year += 100
    fb.read(8)
    show("Recording time")
    _, v = sscanf(fb.str(), "%d%*c%d%*c%d")
    hour, minute, second = [(int32(x) if x is not None else 0)
                            for x in (v + [None] * 3)[:3]]
    fb.read(8)
    show("Number of bytes in header record")
    j = fb.read(44)
    if j > 0:
        show("Free space")
    fb.read(8)
    show("Number of data records")
    fb.read(8)
    show("Duration of each data record in seconds")
    n, v = sscanf(fb.str(), "%lf")
    spr = v[0] if n == 1 else 0.0
    if spr <= 0.0:
        spr = 1.0
    fb.read(4)
    show("Number of signals")
    n, v = sscanf(fb.str(), "%d")
    nsig = int32(v[0]) if n == 1 else 0
    if nsig < 1:
        raise Exit(1)
    si = [w.Siginfo(gain=0.0, spf=0) for _ in range(nsig)]
    spb = [0] * nsig
    sigdmax = [0] * nsig
    sigdmin = [0] * nsig
    sigpmax = [0.0] * nsig
    sigpmin = [0.0] * nsig
    sampfreq = [0.0] * nsig
    if not siglist:
        siglist = list(range(nsig))
    else:
        for s in siglist:
            if s < 0 or s >= nsig:
                eprintf("%s: invalid signal number, %d, in signal list\n",
                        pname, s)
                raise Exit(1)
    nosig = len(siglist)
    for k in range(nsig):
        fb.read(16, 15)
        if vflag:
            out.write("Signal %d label: '%s'\n" % (k, fb.str()))
        si[k].desc = fb.str()
    for k in range(nsig):
        j = fb.read(80)
        if vflag and j > 0:
            out.write("Signal %d transducer type: '%s'\n" % (k, fb.str()))
    for k in range(nsig):
        fb.read(8)
        if vflag:
            out.write("Signal %d physical dimension: '%s'\n" % (k, fb.str()))
        si[k].units = fb.str()
    for lst, label, conv in ((sigpmin, "physical minimum", "%lf"),
                             (sigpmax, "physical maximum", "%lf"),
                             (sigdmin, "digital minimum", "%ld"),
                             (sigdmax, "digital maximum", "%ld")):
        for k in range(nsig):
            fb.read(8)
            if vflag:
                out.write("Signal %d %s: '%s'\n" % (k, label, fb.str()))
            n, v = sscanf(fb.str(), conv)
            if n == 1:
                lst[k] = v[0]
    for k in range(nsig):
        if sigpmax[k] == sigpmin[k]:
            out.flush()
            eprintf("gain for signal %d is undefined\n", k)
            continue
        si[k].adczero = int32(cdiv(sigdmax[k] + 1 + sigdmin[k], 2))
        adcrange = sigdmax[k] - sigdmin[k]
        si[k].gain = adcrange / (sigpmax[k] - sigpmin[k])
        j = 0
        while adcrange > 1:
            adcrange = cdiv(adcrange, 2)
            j += 1
        si[k].adcres = j
        si[k].baseline = d2i(sigdmax[k] - sigpmax[k] * si[k].gain + 1)
    for k in range(nsig):
        j = fb.read(80)
        if vflag and j > 0:
            out.write("Signal %d filtering information: '%s'\n" %
                      (k, fb.str()))
    for k in range(nsig):
        fb.read(8)
        if vflag:
            out.write("Signal %d number of samples per record: '%s'\n" %
                      (k, fb.str()))
        n, v = sscanf(fb.str(), "%lf")
        if n == 1:
            sampfreq[k] = v[0]
        n, v = sscanf(fb.str(), "%d")
        if n == 1:
            spb[k] = int32(v[0])
        sampfreq[k] /= spr
    for k in range(nsig):
        j = fb.read(32)
        if vflag and j > 0:
            out.write("Signal %d free space: '%s'\n" % (k, fb.str()))
    sps = sampfreq[siglist[0]]
    for k in range(1, nosig):
        if sampfreq[siglist[k]] != sps:
            sps = gcd(sps, sampfreq[siglist[k]])
    w.setsampfreq(sps)
    w.setbasetime("%02d:%02d:%02d %02d/%02d/%04d" % (
        hour, minute, second, day, month, year))
    fname = "%s.dat" % record
    so = []
    for k in range(nosig):
        s = si[siglist[k]]
        s.fname = fname
        s.fmt = 16
        s.spf = d2i(fdiv(sampfreq[siglist[k]], sps) + 0.5)
        so.append(s.copy())
    fpb = cdiv(spb[siglist[0]], si[siglist[0]].spf)
    if vflag:
        out.write("\nOUTPUT:\nBase sampling frequency: %g Hz\n" % sps)
    for k in range(nosig):
        j = si[siglist[k]].spf
        if vflag:
            out.write(" Signal %d samples per second: %g (%d sample%s per "
                      "frame)\n" % (k, sampfreq[siglist[k]], j,
                                    "s" if j > 1 else ""))
    vin = [bytearray(2 * max(spb[k], 0)) for k in range(nsig)]
    tspf = sum(s.spf for s in so)
    vout = [0] * tspf
    w.osigfopen(so, nosig)
    while True:
        j = 0
        for k in range(nsig):
            b = ifile.read(2 * spb[k])
            vin[k][:len(b)] = b
            j = len(b) // 2
        if j == 0:
            break
        pos = [0] * nosig
        for f in range(fpb):
            vo = 0
            for jj in range(nosig):
                buf = vin[siglist[jj]]
                p = pos[jj]
                for kk in range(so[jj].spf):
                    if p + 1 < len(buf):
                        b0, b1 = buf[p], buf[p + 1]
                    else:
                        b0 = b1 = 0
                    if big_endian:
                        vout[vo] = int16((b0 << 8) | b1)
                    else:
                        vout[vo] = int16((b1 << 8) | b0)
                    vo += 1
                    p += 2
                pos[jj] = p
            w.putvec(vout)
    if ifile is not sys.stdin.buffer:
        ifile.close()
    w.newheader(record)
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run edf2mit as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["edf2mit"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["edf2mit"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
