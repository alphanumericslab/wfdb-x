"""parsescp: parse an SCP-ECG file (read from the standard input).

The input is held in one byte buffer and the C program's pointers into it are
represented by offsets.  Bytes beyond the end of the input (which the C program
reads in a few places, e.g. at the end of section 7 with -v) are read as 0.

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of convert/parsescp.c from the WFDB Software Package
10.7.0, by George B. Moody and Edna S. Moody. The translation follows the logic
and behavior of the original program, but it is new code, not the original C
code.

Changes from the original: the record is written with the sampling frequency
given in the SCP file, and is not written if the file gives none (the original
always wrote 500 Hz); signals and reference beats that could not be allocated,
and samples beyond the end of a signal shorter than lead 0, are read as absent
or as zeros (undefined behavior in the original); --legacy, as the first
argument, restores the original behavior. Each change is marked "wfdb-x:" in
the code; docs/DIVERGENCES.md gives the reasons.

Original C program: convert/parsescp.c, WFDB Software Package 10.7.0.
  Copyright (C) 2000-2014 George B. Moody and Edna S. Moody; revised 2016-2020
  by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys
from array import array

import wfdbx as w
from wfdbx._cstd import (LONG_MAX, atoi, cdiv, d2i, d2l, int8, int16, int32,
                         sprintf)
from ._common import Output, Exit, eprintf, legacy, run, prog_name

VERSION_STRING = "#ECG/1.0"
WFDB_INVALID_SAMPLE = w.WFDB_INVALID_SAMPLE
U64 = 0xFFFFFFFFFFFFFFFF    # mask for unsigned 64-bit (size_t) arithmetic

# The .ecg output has the layout of the SpaceLabs/Burdick carts: 10 seconds
# at 500 samples per second, 5 microvolts per adu.  (wfdb-x: the WFDB record
# has the sampling frequency given in the SCP file; C always wrote 500 Hz.)
NOUT = 12               # leads written: I, II, III, aVR, aVF, aVL, V1-V6
SEGLEN = 1250           # samples per 2.5-second segment in the .ecg file
ECGPROLOGLEN = 512      # length of the .ecg file prolog
MAXDEV = 2000           # with -z, samples beyond +/-MAXDEV adu are invalid
NSECTIONS = 12          # SCP-ECG sections 0 to 11
AXIS_UNDEF = 999        # value of an undefined axis (section 7)
MAXAGE = 90             # older ages are censored (-a, and in .hea files)
RECNAMELEN = 11         # maximum length of a record name (-o)

# The C program allocates every array with malloc/calloc; requests larger
# than this many elements are treated as allocation failures.
MAXALLOC = 1 << 28
# Signal arrays have at least this many elements (the .ecg file always
# contains 5000 samples of lead II); samples beyond a lead's length are 0.
MINSIGLEN = 5000

HELP = (
    "  where RECORD is the name (<= 11 alphanumeric characters) of this "
    "case,\n"
    "  SCPFILE is the name of a file containing ECG data in SCP-ECG format, "
    "and\n"
    "  OPTIONS may include:\n"
    "   -a    anonymize and copy stdin to stdout (suppresses other output).\n"
    "   -f    force parsing of a file with CRC errors.\n"
    "   -h    print brief help\n"
    "   -l    low-pass filter (smooth) the output waveforms.\n"
    "   -v    option to print a (very) detailed analysis of SCPFILE.\n"
    "   -w    produce a WFDB-format record\n"
    "   -z    zero-mean the input\n\n"
    "  Additional options for debugging only:\n"
    "   -b    show baseline (residuals);  suppress templates\n"
    "   -s N  shift templates by N samples before adding\n"
    "   -S N  skip parsing of section N\n"
    "   -t    show templates; suppress baseline\n"
    "   -x    show hex dumps (implies -v)\n"
)

MONTH = ["January", "February", "March", "April", "May", "June", "July",
         "August", "September", "October", "November", "December"]

LEADNAME = [            # standard lead names
    "<Unspecified lead>", "I", "II", "V1", "V2",                 # 0 - 4
    "V3", "V4", "V5", "V6", "V7",                                # 5 - 9
    "V2R", "V3R", "V4R", "V5R", "V6R",                           # 10 - 14
    "V7R", "X", "Y", "Z", "CC5",                                 # 15 - 19
    "CM5", "Left Arm", "Right Arm", "Left Leg", "I (Frank)",     # 20 - 24
    "E", "C", "A", "M", "F",                                     # 25 - 29
    "H", "I-cal", "II-cal", "V1-cal", "V2-cal",                  # 30 - 34
    "V3-cal", "V4-cal", "V5-cal", "V6-cal", "V7-cal",            # 35 - 39
    "V2R-cal", "V3R-cal", "V4R-cal", "V5R-cal", "V6R-cal",       # 40 - 44
    "V7R-cal", "X-cal", "Y-cal", "Z-cal", "CC5-cal",             # 45 - 49
    "CM5-cal", "Left Arm-cal", "Right Arm-cal", "Left Leg-cal",
    "I-cal (Frank)",                                             # 50 - 54
    "E-cal", "C-cal", "A-cal", "M-cal", "F-cal",                 # 55 - 59
    "H-cal", "III", "aVR", "aVL", "aVF",                         # 60 - 64
    "-aVR", "V8", "V9", "V8R", "V9R",                            # 65 - 69
    "D (Nehb - Dorsal)", "A (Nehb - Anterior)", "J (Nehb - Inferior",
    "Defibrillator lead: anterior-lateral",
    "External pacing lead: anterior-posterior",                  # 70 - 74
    "A1 (Auxiliary unipolar lead 1)", "A2 (Auxiliary unipolar lead 2)",
    "A3 (Auxiliary unipolar lead 3)", "A4 (Auxiliary unipolar lead 4)",
    "V8-cal",                                                    # 75 - 79
    "V9-cal", "V8R-cal", "V9R-cal", "D-cal (Nehb - Dorsal)",
    "A-cal (Nehb - Anterior)",                                   # 80 - 84
    "J-cal (Nehb - Inferior)",                                   # 85
]

# The default (SCP standard) Huffman table: pattern -> (suffixbits, base).
HTDEFAULT = {
    0: (0, 0), 4: (0, 1), 5: (0, -1), 0xc: (0, 2), 0xd: (0, -2),
    0x1c: (0, 3), 0x1d: (0, -3), 0x3c: (0, 4), 0x3d: (0, -4),
    0x7c: (0, 5), 0x7d: (0, -5), 0xfc: (0, 6), 0xfd: (0, -6),
    0x1fc: (0, 7), 0x1fd: (0, -7), 0x3fc: (0, 8), 0x3fd: (0, -8),
    0x3fe: (8, 0), 0x3ff: (16, 0),
}

# Fields of struct ECGmeas, in order (section 10 measurements).
MEASFIELDS = ["leadid", "vlen", "Pdur", "PRint", "QRSdur", "QTint", "Qdur",
              "Rdur", "Sdur", "Rpdur", "Spdur", "Qamp", "Ramp", "Samp",
              "Rpamp", "Spamp", "Jamp", "Ppamp", "Pnamp", "Tpamp", "Tnamp",
              "STslope", "Pmorph", "Tmorph", "isoI", "isoK", "tind", "qual",
              "st20", "st60", "st80", "strr16", "strr8"]

# (label, field) of each row of the measurement table printed by precgmeas.
MEASROWS = [
    ("\nP duration    ms", "Pdur"), ("\nPR interval   ms", "PRint"),
    ("\nQRS duration  ms", "QRSdur"), ("\nQT interval   ms", "QTint"),
    ("\nQ duration    ms", "Qdur"), ("\nR duration    ms", "Rdur"),
    ("\nS duration    ms", "Sdur"), ("\nR' duration   ms", "Rpdur"),
    ("\nS' duration   ms", "Spdur"), ("\nQ amplitude   uV", "Qamp"),
    ("\nR amplitude   uV", "Ramp"), ("\nS amplitude   uV", "Samp"),
    ("\nJ amplitude   uV", "Jamp"), ("\nP+ amplitude  uV", "Ppamp"),
    ("\nP- amplitude  uV", "Pnamp"), ("\nT+ amplitude  uV", "Tpamp"),
    ("\nT- amplitude  uV", "Tnamp"), ("\nST slope    uV/s", "STslope"),
    ("\nP morphology  --", "Pmorph"), ("\nT morphology  --", "Tmorph"),
    ("\nIsoelec (I)   ms", "isoI"), ("\nIsoelec (K)   ms", "isoK"),
    ("\nIntrins defl  ms", "tind"), ("\nQuality       --", "qual"),
    ("\nST (J+20ms)   uV", "st20"), ("\nST (J+60ms)   uV", "st60"),
    ("\nST (J+80ms)   uV", "st80"), ("\nST (J+RRm/16) uV", "strr16"),
    ("\nST (J+RRm/8)  uV", "strr8"),
]


def int64(x):
    x &= U64
    return x - (1 << 64) if x >> 63 else x


def isprint(c):
    return 32 <= c < 127


def d2s(x):
    """C conversion of double to short (via a 32-bit int, as gcc does)."""
    return int16(d2i(x))


def newsig(n):
    """calloc(n, sizeof(short)) for a signal; None if allocation fails."""
    if n > MAXALLOC:
        return None
    return array("h", bytes(2 * max(n, MINSIGLEN)))


class Subzone:
    """Reference beat subtraction zone (struct subzone)."""
    __slots__ = ("type", "t0", "t1", "t2")


class ECGmeas:
    """Set of measurements in section 10 (struct ECGmeas)."""
    __slots__ = MEASFIELDS


class Parser:
    """The state (the C program's global variables) and functions of
    parsescp."""

    def __init__(self, out):
        self.out = out
        self.data = bytearray()
        self.bflag = self.fflag = self.tflag = self.vflag = self.xflag = 0
        self.aflag = self.lflag = self.wflag = self.zflag = 0
        self.shift = 0
        self.skip = [0] * NSECTIONS
        self.pname = "parsescp"
        self.nleads = -1
        self.nqrs = -1
        self.nsamp = None
        self.rblen = 0
        self.rblenms = 0
        self.fcM = 0
        self.gref = self.gres = 0.0
        self.sfreq = -1.0
        self.recdate = ""
        self.rectime = ""
        self.recname = ""
        self.patient_name = ""
        self.referring_dr = ""
        self.comments = ""
        self.patient_id = ""
        self.age = -1
        self.sex = -1
        self.RRint = self.Pon = self.Pend = -1
        self.QRSon = self.QRSend = self.Tend = -1
        self.Paxis = self.QRSaxis = self.Taxis = AXIS_UNDEF
        self.blfilt = self.lpfilt = self.filter_bit = -1
        self.tdevid = self.tinst = self.tdept = -1
        self.dept = "<missing>"     # string, or offset of a C string
        self.inst = "<missing>"
        self.stmnts = -1
        self.report = [None] * 1200
        self.subz = None
        self.ecg = None
        self.refbeat = None
        self.leadI = self.leadII = self.leadIII = -1
        self.aVR = self.aVF = self.aVL = -1
        self.V1 = self.V2 = self.V3 = self.V4 = self.V5 = self.V6 = -1
        self.ecgmeas = None
        self.nsecleads = 0
        # static variables of getbits() and Huffdecode()
        self.w = 0
        self.dx = self.x = self.xx = self.xxx = self.xout = 0

    def printf(self, fmt, *args):
        self.out.write(sprintf(fmt, *args))

    # ---- signals ----

    def sig(self, k):
        """Signal k; a lead index outside the ecg array (undefined behavior
        in C) refers to an array of zero samples, like a missing lead."""
        ecg = self.ecg
        if ecg is not None and 0 <= k < len(ecg) and ecg[k] is not None:
            return ecg[k]
        return array("h", bytes(2 * max(getattr(self, "nout", 0),
                                        MINSIGLEN)))

    def ns(self, k):
        """nsamp[k], or 0 if k is outside the nsamp array."""
        nsamp = self.nsamp
        if nsamp is not None and 0 <= k < len(nsamp):
            return nsamp[k]
        return 0

    # ---- access to the input buffer ----

    # Multi-byte values in SCP-ECG files are little-endian.  Bytes outside
    # the input are read as 0 (and writes to them are ignored).

    def b(self, off):
        """The (unsigned) byte at off."""
        d = self.data
        return d[off] if 0 <= off < len(d) else 0

    def get16(self, off):
        """The unsigned 16-bit value at off."""
        return self.b(off) | (self.b(off + 1) << 8)

    def put16(self, val, off):
        """Store a 16-bit value at off."""
        d = self.data
        if 0 <= off < len(d):
            d[off] = val & 0xff
        if 0 <= off + 1 < len(d):
            d[off + 1] = (val >> 8) & 0xff

    def get32(self, off):
        """The 32-bit value at off, as C's get32() returns it (unsigned
        long, from a sign-extended int)."""
        r = self.b(off) | (self.b(off + 1) << 8) | (self.b(off + 2) << 16) | \
            (self.b(off + 3) << 24)
        if r & 0x80000000:      # *p << 24 is a sign-extended int
            r |= 0xFFFFFFFF00000000
        return r

    def cstr(self, off):
        """The NUL-terminated string at off (ends at the end of the data)."""
        if isinstance(off, str):
            return off
        d = self.data
        if off < 0:
            return ""
        j = d.find(b"\0", off)
        if j < 0:
            j = len(d)
        return d[off:j].decode("latin-1")

    def getcrc(self, off, length):
        """CRC-CCITT of length bytes at off (byte-wise algorithm of C)."""
        d = self.data
        n = len(d)
        crchigh = crclow = 0xff
        while length > 0:
            length -= 1
            c = d[off] if 0 <= off < n else 0
            off += 1
            crchigh = a = (c ^ crchigh) & 0xff
            a >>= 4
            a ^= crchigh
            crchigh = crclow    # swap crchigh, crclow
            crclow = a
            bb = (a & 0xf) << 4     # rotate a left by four bits
            a >>= 4
            bb = a = a | bb
            if a & 0x80:            # rotate a left by one more bit
                a = ((a << 1) | 1) & 0xff
            else:
                a = (a << 1) & 0xff
            a &= 0x1f
            crchigh ^= a
            a = bb & 0xf0
            crchigh ^= a            # crchigh complete
            if bb & 0x80:           # rotate b left by one bit
                bb = ((bb << 1) | 1) & 0xff
            else:
                bb = (bb << 1) & 0xff
            bb &= 0xe0
            crclow ^= bb            # crclow complete
        return (crchigh << 8) | crclow

    def crcok(self, off, length, crcref, description):
        crc = self.getcrc(off, length)
        if crc == crcref:
            if self.vflag:
                self.printf("%s: correct (%d)\n", description, crc)
            return 1
        if self.vflag:
            self.printf("%s: error (calculated: %d, expected: %d)\n",
                        description, crc, crcref)
        if self.fflag:
            return 0
        raise Exit(1)   # quit on CRC error unless in -f (force) mode

    # ---- output ----

    def lowpass(self):
        ecg = self.ecg
        for i in range(self.nleads):
            if ecg[i] is None:
                continue
            n = self.nsamp[i]
            out = newsig(n)
            if out is None:
                eprintf("Insufficient memory for filtering\n")
                break
            inp = ecg[i]
            nin = len(inp)
            nout = len(out)

            def x(k):
                # samples beyond the end of the input array read as 0
                return inp[k] if k < nin else 0

            def put(k, v):
                # writes beyond the end of the output array are skipped
                if k < nout:
                    out[k] = v

            put(0, d2s(x(0) * 0.67 + x(1) * 0.22 + x(2) * 0.11))
            put(1, d2s(x(0) * 0.33 + x(1) * 0.34 + x(2) * 0.22 +
                       x(3) * 0.11))
            # C: for (j = 2; j < nsamp[i] - 2; j++), with an unsigned
            # (wrapping) bound; iterations past the end of the output array
            # would only make skipped writes, so the loop stops there (the
            # final writes below are then skipped too).
            jend = min((n - 2) & U64, nout)
            j = 2
            while j < jend and j + 2 < nin:
                out[j] = d2s(inp[j] * 0.34 + (inp[j-1] + inp[j+1]) * 0.22 +
                             (inp[j-2] + inp[j+2]) * 0.11)
                j += 1
            while j < jend and j - 2 < nin:
                out[j] = d2s(x(j) * 0.34 + (x(j-1) + x(j+1)) * 0.22 +
                             (x(j-2) + x(j+2)) * 0.11)
                j += 1
            # (beyond, all the input samples read as 0, so do the outputs,
            # which are already 0)
            j = max(j, jend)
            put(j, d2s(x(j-2) * 0.11 + x(j-1) * 0.22 + x(j) * 0.34 +
                       x(j+1) * 0.33))
            j += 1
            put(j, d2s(x(j-2) * 0.11 + x(j-1) * 0.22 + x(j) * 0.67))
            ecg[i] = out

    def write_output(self):
        if self.recname == "":
            self.recname = "ecg"    # default record name
        recname = self.recname
        dname = recname + ".des"
        ename = recname + ".ecg"
        kname = recname + ".key"
        tname = recname + ".txt"
        files = []
        try:
            for name, mode in ((dname, "wb"), (ename, "wb"), (kname, "wb")) + \
                    (((tname, "wb"),) if self.vflag else ()):
                files.append(open(name, mode))
        except OSError:
            for f in files:
                f.close()
            eprintf("%s: can't create '%s'\n", self.pname,
                    [dname, ename, kname, tname][len(files)])
            return 0
        dfile, efile, kfile = files[:3]
        tfile = files[3] if self.vflag else None

        def fp(f, fmt, *args):
            f.write(sprintf(fmt, *args).encode("latin-1"))

        # Write the description file first.
        fp(dfile, VERSION_STRING + " description\n")
        fp(dfile, "Record: %s (%s %s)\n", recname, self.recdate, self.rectime)
        fp(dfile, "Age: %d\n", self.age)
        fp(dfile, "Sex: ")
        fp(dfile, {1: "M\n", 2: "F\n", 0: "not known\n",
                   9: "unspecified\n"}.get(self.sex, "<error>\n"))
        fp(dfile, "Referring Dr: %s\n", self.referring_dr)
        fp(dfile, "Comments: %s\n", self.comments)
        if self.tdevid == 0:
            fp(dfile, "Cart ID: <missing>\n")
        else:
            fp(dfile, "Cart ID: %d\n", self.tdevid)
        dept = self.cstr(self.dept)
        fp(dfile, "Department: %s\n", dept)
        if self.tdept == 0:
            fp(dfile, "Department #: <missing>\n")
        else:
            fp(dfile, "Department #: %s\n", dept)
        fp(dfile, "Institution: %s\n", self.cstr(self.inst))
        if self.tinst == 0:
            fp(dfile, "Institution #: <missing>\n")
        else:
            fp(dfile, "Institution #: %d\n", self.tinst)
        for i in range(self.stmnts):
            r = self.report[i]
            fp(dfile, "Report %d: %s\n", i,
               "(null)" if r is None else self.cstr(r))
        fp(dfile, "Bandwidth: %g-%d Hz\n", self.blfilt * 0.0001, self.lpfilt)
        fp(dfile, "Filtering:")
        fb = self.filter_bit
        if fb & 1:
            fp(dfile, " 60 Hz notch")
        if fb & 2:
            fp(dfile, " 50 Hz notch")
        if fb & 4:
            fp(dfile, " Artifact filter")
        if fb & 8:
            fp(dfile, " Baseline filter")
        if fb & 0xf0:
            fp(dfile, " <undefined>")
        if fb == 0:
            fp(dfile, " <not specified>")
        fp(dfile, "\n\n")
        fp(dfile, "RR interval: %d\n", self.RRint)
        fp(dfile, "P onset: %d\n", self.Pon)
        fp(dfile, "P end: %d\n", self.Pend)
        fp(dfile, "QRS onset: %d\n", self.QRSon)
        fp(dfile, "QRS end: %d\n", self.QRSend)
        fp(dfile, "T end: %d\n", self.Tend)
        fp(dfile, "P axis: %d\n", self.Paxis)
        fp(dfile, "QRS axis: %d\n", self.QRSaxis)
        fp(dfile, "T axis: %d\n", self.Taxis)
        dfile.write(self.precgmeas().encode("latin-1"))
        dfile.close()

        # Generate the key file.
        fp(kfile, VERSION_STRING + " key\n")
        fp(kfile, "Record: %s (%s %s)\n", recname, self.recdate, self.rectime)
        fp(kfile, "Name: %s\n", self.patient_name)
        fp(kfile, "MRN: %s\n", self.patient_id)
        kfile.close()

        ecg = self.ecg
        nsamp = self.nsamp
        # Zero-mean the signals (-z).
        if self.zflag:
            buf = self.zbuf
            for s in range(self.nleads):
                sig = ecg[s]
                imax = MINSIGLEN if nsamp[s] > MINSIGLEN else nsamp[s]
                for i in range(imax):
                    buf[i] = sig[i]
                buf[:imax] = sorted(buf[:imax])
                m = buf[imax // 2]
                k = nsamp[s] - 1
                if 1 <= k < len(sig) and sig[k] == 0:
                    sig[k] = sig[k - 1]
                for i in range(self.nout):
                    v = sig[i] = int16(sig[i] - m)
                    if v < -MAXDEV or v > MAXDEV:
                        sig[i] = WFDB_INVALID_SAMPLE

        # Write the WFDB-format record if requested (-w option).
        if self.wflag:
            self.write_wfdb_record()

        order = [self.leadI, self.leadII, self.leadIII, self.aVR, self.aVF,
                 self.aVL, self.V1, self.V2, self.V3, self.V4, self.V5,
                 self.V6]
        # Write the ECG in text form if requested (-v option).
        if self.vflag:
            parts = []
            if self.vflag > 1:
                parts.append("samp#      I     II    III    aVR    aVF    aVL"
                             "     V1     V2     V3     V4     V5     V6")
            sigs = [self.sig(k) for k in order]
            for i in range(self.nout):
                parts.append("%5d" % i)
                parts.append("".join(["%7d" % s[i] for s in sigs]))
                parts.append("\n")
            tfile.write("".join(parts).encode("latin-1"))
            tfile.close()

        # Finally, output the ECG in vector (binary) form.
        if self.lflag == 0:
            prolog = sprintf(VERSION_STRING + " signals\nRecord: %s (%s %s)\n",
                             recname, self.recdate, self.rectime)
        else:
            prolog = sprintf(VERSION_STRING + " signals\nRecord: %s (%s %s)\n"
                             "Low-pass filtered\n",
                             recname, self.recdate, self.rectime)
            self.lowpass()
        prolog = prolog.encode("latin-1")[:ECGPROLOGLEN]
        efile.write(prolog + bytes(ECGPROLOGLEN - len(prolog)))
        # Three traces of four 2.5-second segments, then 10 s of lead II.
        lI, lII, lIII, aVR, aVF, aVL, V1, V2, V3, V4, V5, V6 = order
        for row in ((lI, aVR, V1, V4), (lII, aVL, V2, V5),
                    (lIII, aVF, V3, V6)):
            for k, sig in enumerate(row):
                efile.write(
                    self.sig(sig)[SEGLEN * k:SEGLEN * (k + 1)].tobytes())
        efile.write(self.sig(lII)[:MINSIGLEN].tobytes())
        efile.close()
        return 1

    def write_wfdb_record(self):
        recname = self.recname
        filename = recname + ".dat"
        leadname = ["I", "II", "III", "aVR", "aVF", "aVL", "V1", "V2", "V3",
                    "V4", "V5", "V6"]
        # wfdb-x: the sampling frequency is the one given in the SCP file (C
        # always wrote 500 Hz, as legacy mode does); without one, no record
        # is written.
        if not legacy():
            if self.sfreq <= 0.0:
                eprintf("%s: sampling frequency not specified; record %s not "
                        "written\n", self.pname, recname)
                return 0
            w.setsampfreq(self.sfreq)
        if w.newheader(recname) < 0:
            return 0
        if legacy():
            w.setsampfreq(500.0)
        # wfdb-x: 200 adu/mV is exact, not assumed: the samples have been
        # rescaled to units of 5000 nV (see gref and gres), i.e., 5 microvolts
        # per adu.
        s = [w.Siginfo(fname=filename, desc=leadname[i], units="mV", fmt=16,
                       gain=200.0, adcres=16, spf=0) for i in range(NOUT)]
        if w.osigfopen(s, NOUT) < NOUT:
            return 0
        w.setbasetime("%s %s\n" % (self.recdate, self.rectime))
        sigs = [self.sig(k) for k in (self.leadI, self.leadII, self.leadIII,
                                 self.aVR, self.aVF, self.aVL, self.V1,
                                 self.V2, self.V3, self.V4, self.V5, self.V6)]
        v = [0] * NOUT
        for i in range(self.nout):
            for k in range(NOUT):
                v[k] = sigs[k][i]
            if w.putvec(v) < 0:
                break
        w.newheader(recname)
        age = self.age
        sex = self.sex
        w.putinfo(sprintf("<age>: %d <sex>: %c", min(age, MAXAGE),
                          "M" if sex == 1 else "F" if sex == 2 else "?"))
        w.wfdbquit()
        return 1

    # ---- sections ----

    def hexdump(self, p, ln):
        parts = ["Hex dump of data area:\n\n"]
        for i in range(ln):
            if i % 16 == 0:
                parts.append("\n%4d:  " % i)
            parts.append(" %2x" % self.b(p + i))
        parts.append("\n\n")
        self.out.write("".join(parts))

    def section0(self, p, ln):
        vflag = self.vflag
        if not self._strneq(p + 10, b"SCPECG"):
            if vflag:
                self.printf(" Warning: SCPECG identifier is missing in "
                            "header\n")
        p += 16
        ln -= 16
        if ln < 10:
            if vflag:
                self.printf(" Error: section 0 contains no data\n")
            return 0
        while ln > 0:
            sec_id = self.get16(p)
            sec_len = self.get32(p + 2)
            sec_index = self.get32(p + 6)
            if vflag:
                self.printf("  Section %2d:%6ld bytes beginning at byte "
                            "%6ld\n", sec_id, int64(sec_len),
                            int64(sec_index))
            ln -= 10
            p += 10
        if ln < 0:
            if vflag:
                self.printf(" Error: section 0 overlaps the next section\n")
            return 0
        return 1

    def _strneq(self, off, s):
        """strncmp(s, data + off, len(s)) == 0"""
        for k, c in enumerate(s):
            d = self.b(off + k)
            if d != c:
                return False
            if c == 0:
                break
        return True

    def censor(self, p, ln, c):
        d = self.data
        n = len(d)
        ln = (ln - 1) & 0xffff
        while ln:
            if p < n:
                d[p] = c
            p += 1
            ln = (ln - 1) & 0xffff
        if p < n:
            d[p] = 0

    def section1(self, p, ln):
        vflag = self.vflag
        aflag = self.aflag
        pr = self.printf
        b = self.b
        get16 = self.get16
        tpatid = trefdr = tcomments = tdate = ttime = pyob = None
        firstname = lastname = None
        p_save = p
        len_save = ln
        TEXT, DATE, TIME, B1, B2, B2B1, BN, MIXED = range(8)
        X, ZERO = ord("x"), ord("0")

        p += 16
        ln -= 16
        if ln < 3:
            if vflag:
                pr(" Error: section 1 contains no data\n")
            return 0

        while ln > 2:
            tag = b(p)
            if tag == 255:
                break           # tag 255 is the terminator
            vlen = get16(p + 1)
            if vlen > ln:
                if vflag:
                    pr(" Error: tagged field overlaps next section\n")
                return 0
            if tag == 0:
                if vflag:
                    pr("\n  Last name\n")
                vtype = TEXT
                lastname = p + 3
                if aflag:
                    self.censor(lastname, vlen, X)
            elif tag == 1:
                if vflag:
                    pr("\n  First name\n")
                vtype = TEXT
                firstname = p + 3
                if aflag:
                    self.censor(firstname, vlen, X)
            elif tag == 2:
                if vflag:
                    pr("\n  Patient ID number\n")
                vtype = TEXT
                tpatid = p + 3
                if aflag:
                    self.censor(tpatid, vlen, ZERO)
            elif tag == 3:
                if vflag:
                    pr("\n  Second last name\n")
                vtype = TEXT
                if aflag:
                    self.censor(p + 3, vlen, X)
            elif tag == 4:
                if vflag:
                    pr("\n  Age\n")
                vtype = B2B1
                self.age = get16(p + 3)
                if aflag and self.age > MAXAGE:
                    self.put16(MAXAGE, p + 3)   # censor age if over 90
            elif tag == 5:
                if vflag:
                    pr("\n  Date of birth\n")
                vtype = DATE
                if aflag:
                    pyob = p + 3
                    self.put16(257, p + 5)  # censor month and day
            elif tag == 6:
                if vflag:
                    pr("\n  Height\n")
                vtype = B2B1
            elif tag == 7:
                if vflag:
                    pr("\n  Weight\n")
                vtype = B2B1
            elif tag == 8:
                if vflag:
                    pr("\n  Sex\n")
                vtype = B1
                self.sex = b(p + 3)
            elif tag == 9:
                if vflag:
                    pr("\n  Race\n")
                vtype = B1
            elif tag == 10:
                if vflag:
                    pr("\n  Drug\n")
                vtype = MIXED
            elif tag == 11:
                if vflag:
                    pr("\n  Systolic blood pressure\n")
                vtype = B2
            elif tag == 12:
                if vflag:
                    pr("\n  Diastolic blood pressure\n")
                vtype = B2
            elif tag == 13:
                if vflag:
                    pr("\n  Diagnosis or referral indication\n")
                vtype = TEXT
            elif tag == 14:
                if vflag:
                    pr("\n  ID of the acquiring device\n")
                self.tdevid = get16(p + 7)
                self.tinst = get16(p + 3)   # institution #
                self.tdept = get16(p + 5)   # department #
                if vflag:
                    pr("   Institution number: %d\n", get16(p + 3))
                    pr("   Department number: %d\n", get16(p + 5))
                    pr("   Device ID: %d\n", get16(p + 7))
                    c = b(p + 9)
                    pr("   Device type: %d (%s)\n", c,
                       "cart" if c == 0 else
                       "system or host" if c == 1 else "<error>")
                    pr("   Manufacturer code: %d\n", b(p + 10))
                    pr("   Text model description: [%d]", b(p + 11))
                    pr("   SCP-ECG protocol revision number: %g\n",
                       float(b(p + 17)) / 10.0)
                    pr("   SCP-ECG protocol compatibility level: %d\n",
                       b(p + 18))
                    pr("   Language support code: %d\n", b(p + 19))
                    pr("   Device capabilities: %d\n", b(p + 20))
                    c = b(p + 21)
                    pr("   AC mains frequency environment: %d ", c)
                    pr({0: "(unspecified)\n", 1: "(50 Hz)\n",
                        2: "(60 Hz)\n"}.get(c, "<error>"))
                    q = p + 39
                    for label in ("Analyzing program revision number",
                                  "Serial number of acquisition device",
                                  "Acquisition device system software ID",
                                  "Acquisition device SCP implementation ID",
                                  "Manufacturer of acquisition device"):
                        s = self.cstr(q)
                        pr("   %s: [%s]\n", label, s)
                        q += len(s) + 1
                vtype = MIXED
            elif tag == 15:
                if vflag:
                    pr("\n  ID of the analyzing device\n")
                vtype = MIXED
            elif tag == 16:
                if vflag:
                    pr("\n  Acquiring institution\n")
                vtype = TEXT
                self.inst = p + 3
                if aflag:
                    self.censor(p + 3, vlen, X)
            elif tag in (17, 18, 19, 20, 21, 22, 23):
                if vflag:
                    pr({17: "\n  Analyzing institution\n",
                        18: "\n  Acquiring department\n",
                        19: "\n  Analyzing department\n",
                        20: "\n  Referring physician\n",
                        21: "\n  Latest confirming physician\n",
                        22: "\n  Technician\n",
                        23: "\n  Room\n"}[tag])
                vtype = TEXT
                if aflag:
                    self.censor(p + 3, vlen, X)
                if tag == 18:
                    self.dept = p + 3
                elif tag == 20:
                    trefdr = p + 3
            elif tag == 24:
                if vflag:
                    pr("\n  Stat code (urgency)\n")
                vtype = B1
            elif tag == 25:
                if vflag:
                    pr("\n  Date of acquisition\n")
                tdate = p + 3
                if aflag:
                    self.put16(257, p + 5)  # censor month and day
                vtype = DATE
            elif tag == 26:
                if vflag:
                    pr("\n  Time of acquisition\n")
                ttime = p + 3
                vtype = TIME
            elif tag == 27:
                if vflag:
                    pr("\n  Baseline filter\n")
                vtype = B2
                self.blfilt = get16(p + 3)
            elif tag == 28:
                if vflag:
                    pr("\n  Low-pass filter\n")
                vtype = B2
                self.lpfilt = get16(p + 3)
            elif tag == 29:
                if vflag:
                    pr("\n  Filter bit map\n")
                vtype = B1
                self.filter_bit = b(p + 3)
            elif tag == 30:
                if vflag:
                    pr("\n  Free text field (comments)\n")
                tcomments = p + 3
                vtype = TEXT
            elif tag == 31:
                if vflag:
                    pr("\n  Sequence number\n")
                vtype = TEXT
            elif tag == 32:
                if vflag:
                    pr("\n  Medical history codes\n")
                vtype = BN
            elif tag == 33:
                if vflag:
                    pr("\n  Electrode configuration code\n")
                vtype = B2
            elif tag == 34:
                if vflag:
                    pr("\n  Time zone\n")
                vtype = MIXED
            elif tag == 35:
                if vflag:
                    pr("\n  Free text medical history\n")
                vtype = TEXT
            else:
                if vflag:
                    pr("\n  <Undefined tag>\n")
                vtype = MIXED
            if vflag:
                pr("   Tag%3d (%2d bytes): ", tag, vlen)
            p += 3
            ln -= vlen + 3
            if vlen == 0:
                if vflag:
                    pr("<not defined>\n")
            elif vtype == TEXT:
                if vflag:
                    pr("[%*s]", vlen - 1, self.cstr(p))
                p += vlen
            elif vtype == DATE:
                if vlen != 4:
                    if vflag:
                        pr("  Error: incorrect date format (%d bytes)\n", vlen)
                elif vflag:
                    pr("%4d/%02d/%02d", get16(p), b(p + 2), b(p + 3))
                p += vlen
            elif vtype == TIME:
                if vlen != 3:
                    if vflag:
                        pr("  Error: incorrect time format (%d bytes)\n", vlen)
                elif vflag:
                    pr("%02d:%02d:%02d", b(p), b(p + 1), b(p + 2))
                p += vlen
            elif vtype == B1:
                if vlen != 1:
                    if vflag:
                        pr("  Error: incorrect format (%d bytes instead of "
                           "1)\n", vlen)
                elif vflag:
                    pr("%d", b(p))
                p += vlen
            elif vtype == B2:
                if vlen != 2:
                    if vflag:
                        pr("  Error: incorrect format (%d bytes instead of "
                           "2)\n", vlen)
                elif vflag:
                    pr("%d", get16(p))
                p += vlen
            elif vtype == B2B1:
                if vlen != 3:
                    if vflag:
                        pr("  Error: incorrect format (%d bytes instead of "
                           "3)\n", vlen)
                elif vflag:
                    pr("%d (code %d)", get16(p), b(p + 2))
                p += vlen
            elif vtype == BN:
                while vlen > 0:
                    vlen -= 1
                    if vflag:
                        pr("%d, ", b(p))
                    p += 1
            else:   # MIXED
                if vflag:
                    parts = []
                    while vlen > 0:
                        vlen -= 1
                        c = b(p)
                        parts.append(chr(c) if isprint(c) else "\\%03o" % c)
                        p += 1
                    parts.append("\n")
                    self.out.write("".join(parts))
                else:
                    p += vlen

        # (tdate and ttime are pointers to signed char)
        if tdate is not None:
            mon = int8(b(tdate + 2)) - 1
            self.recdate = sprintf("%d %s %d", int8(b(tdate + 3)),
                                   MONTH[mon] if 0 <= mon < 12 else "???",
                                   get16(tdate))
        if ttime is not None:
            self.rectime = sprintf("%02d:%02d:%02d", int8(b(ttime)),
                                   int8(b(ttime + 1)), int8(b(ttime + 2)))
        lastname = "<last name missing>" if lastname is None else \
            self.cstr(lastname)
        firstname = "<first name missing>" if firstname is None else \
            self.cstr(firstname)
        if len(lastname) + len(firstname) < 100 - 3:
            self.patient_name = "%s, %s" % (lastname, firstname)
        else:
            eprintf("Patient name (%s, %s) is too long\n", lastname,
                    firstname)
            self.patient_name = "Name not available -- too long"
        if tpatid is None:
            tpatid = "<patient ID missing>"
        self.patient_id = self.cstr(tpatid)[:30]
        if trefdr is None:
            trefdr = "<referring physician missing>"
        self.referring_dr = self.cstr(trefdr)[:100]
        if tcomments is None:
            tcomments = "<comments missing>"
        self.comments = self.cstr(tcomments)[:200]

        if b(p) != 255:
            if vflag:
                pr(" Error: header terminator (tag 255) is missing\n")
        # (tpatid cannot be NULL here, so that error is never reported)
        if self.tdevid == -1 or self.tinst == -1 or self.tdept == -1:
            if vflag:
                pr(" Error: device ID number (tag 14) is missing\n")
        if tdate is None:
            if vflag:
                pr(" Error: date of acquisition (tag 25) is missing\n")
        if ttime is None:
            if vflag:
                pr(" Error: time of acquisition (tag 26) is missing\n")

        if aflag and pyob is not None:
            # (the censored year of birth is computed but never stored)
            # Recalculate the CRC for this section.
            crc = self.getcrc(p_save + 2, len_save - 2)
            self.put16(crc, p_save)

        if b(p) != 255 or self.tdevid == -1 or tdate is None or ttime is None:
            return 0
        return 1

    def section2(self, p, ln):
        vflag = self.vflag
        p += 16
        ln -= 16
        if ln < 2:
            if vflag:
                self.printf("  Error: section 2 contains no data\n")
            return 0
        ntables = self.get16(p)
        if ntables == 19999:    # code for the default (SCP standard) table
            if vflag:
                self.printf("  Using standard Huffman table only\n")
        else:
            if vflag:
                self.printf("  Number of Huffman tables defined: %d\n",
                            self.get16(p))
                self.printf("  Number of code structures in table 1: %d\n",
                            self.get16(p + 2))
        return 1

    def section3(self, p, ln):
        vflag = self.vflag
        pr = self.printf
        b = self.b
        i = 0
        nsmax = 0
        p += 16
        ln -= 16
        if ln < 2:
            if vflag:
                pr("  Error: section3 contains no data\n")
            return 0
        self.nleads = nleads = b(p)
        p += 1
        if vflag:
            pr("  Number of leads: %d\n", nleads)
        ln -= 1
        nsamp = self.nsamp = [0] * (nleads + 4)
        if vflag:
            pr("  Flag byte: %xH\n", b(p))
        ln -= 1
        if b(p) & 1:
            if vflag:
                pr("   Reference beat subtraction used for compression\n")
        elif vflag:
            pr("   Reference beat subtraction not used for compression\n")
        if b(p) & 4:
            if vflag:
                pr("   All leads recorded simultaneously\n")
        elif vflag:
            pr("   %d leads recorded simultaneously\n", (b(p) >> 3) & 0xf)
        p += 1

        while ln > 8:
            j = b(p + 8)
            if j < len(LEADNAME):
                name = LEADNAME[j]
                if vflag:
                    pr("  %s", name)
                attr = {"I": "leadI", "II": "leadII", "III": "leadIII",
                        "aVR": "aVR", "aVF": "aVF", "aVL": "aVL", "V1": "V1",
                        "V2": "V2", "V3": "V3", "V4": "V4", "V5": "V5",
                        "V6": "V6"}.get(name)
                if attr is not None:
                    setattr(self, attr, i)
            elif j < 100:
                if vflag:
                    pr("  <Reserved lead>")
            elif vflag:
                pr("  <Manufacturer-defined lead>")
            if vflag:
                pr(": ID %d, samples %lu to %lu\n", j, self.get32(p),
                   self.get32(p + 4))
            ns = (self.get32(p + 4) - self.get32(p) + 1) & U64
            if i < len(nsamp):
                nsamp[i] = ns
            else:
                nsamp.append(ns)
            i += 1
            p += 9
            ln -= 9

        # allocate space for 4 extra signals that will be calculated later
        ecg = self.ecg = [None] * (nleads + 5)
        for i in range(nleads + 4):
            if i >= nleads:
                nsamp[i] = nsmax & U64
            elif nsamp[i] > (nsmax & U64):
                nsmax = int32(nsamp[i])
            if nsamp[i] < 1:
                nsamp[i] = 1
            ecg[i] = newsig(nsamp[i])
            if ecg[i] is None:
                if vflag:
                    pr("  Error: too many (%d) leads\n", nleads)
                return 0
        if ln < 0:
            return 0
        return 1

    def section4(self, p, ln):
        vflag = self.vflag
        pr = self.printf
        stat = 1
        p += 16
        ln -= 16
        if ln < 6:
            if vflag:
                pr("  Error: section 4 contains no data\n")
            return 0
        self.rblenms = self.get16(p)
        self.fcM = self.get16(p + 2)
        nqrs = self.nqrs = self.get16(p + 4)
        if vflag:
            pr("  Length of reference beat type 0 data: %ld msec\n",
               self.rblenms)
            pr("  Sample # of fiducial relative to start of ref beat type "
               "0: %d\n", self.fcM)
            pr("  Number of QRS complexes in the entire record: %d\n", nqrs)
        if nqrs < 1:
            return 0    # no beats -- nothing else to do here
        p += 6
        ln -= 6
        subz = self.subz = [None] * nqrs
        if ln >= nqrs * 14:
            if vflag:
                pr("  Reference beat subtraction zones:\n")
            i = 0
            while i < nqrs and ln >= 14:
                z = subz[i] = Subzone()
                z.type = int16(self.get16(p))
                z.t0 = int64(self.get32(p + 2))
                z.t1 = int64(self.get32(p + 6))
                z.t2 = int64(self.get32(p + 10))
                if z.type == 0 and z.t2 == 0:
                    z.type = 9
                if vflag:
                    pr("   %2d  Type: %2d  start: %7ld  fiducial: %7ld  "
                       "end: %7ld\n", i + 1, z.type, z.t0, z.t1, z.t2)
                    if z.type != 0 and (z.t0 != 0 or z.t2 != 0):
                        pr("  Error: start and end should be zero for beats "
                           "of non-zero types\n")
                p += 14
                ln -= 14
                i += 1
        else:
            if vflag:
                pr("  Error: reference beat subtraction zones are missing\n")
            stat = 0
        if ln >= nqrs * 8:
            if vflag:
                pr("  QRS locations:\n")
            for i in range(nqrs):
                if vflag:
                    pr("   %2d  start: %7lu  end: %7lu\n", i + 1,
                       self.get32(p), self.get32(p + 4))
                p += 8
                ln -= 8
        else:
            if vflag:
                pr("  Error: QRS locations are missing\n")
            stat = 0
        return stat

    def section5(self, p, ln):
        p += 16
        ln -= 16
        if ln <= 0:
            if self.vflag:
                self.printf(" Error: section 5 contains no data\n")
            return 0
        # Calculate length of template in samples
        d = self.get16(p + 2)
        x = self.rblenms * 1000.0
        if d:
            x /= d
        else:
            x = float("nan") if x == 0 else float("inf")
        self.rblen = rblen = d2l(x)
        nleads = self.nleads
        self.refbeat = [None] * max(nleads + 1, 0)
        for i in range(nleads):
            if rblen < 0 or rblen > MAXALLOC:
                eprintf("  Error: too many (%d) leads\n", nleads)
                return 0
            self.refbeat[i] = array("h", bytes(2 * rblen))
        return self.Huffdecode(p, ln, 5)

    def getbits(self, p, ibits):
        """Decode one Huffman-encoded value from the bits of the input that
        begin ibits bits from the MSB of the byte at p.  Returns the number
        of bits read; the decoded value is stored in self.x."""
        b = self.b
        bitbuffer = 0
        wb = self.w
        nbits = 0
        while True:
            bitbuffer = (bitbuffer << 1) & 0xffff
            if (ibits & 7) == 0:
                wb = b(p + (ibits >> 3))
            if wb & 0x80:
                bitbuffer |= 1
            wb = (wb << 1) & 0xff
            ibits += 1
            nbits += 1
            e = HTDEFAULT.get(bitbuffer)
            if e is not None:
                j, base = e
                if j == 0:
                    self.x = base
                else:
                    if (ibits & 7) == 0:
                        wb = b(p + (ibits >> 3))
                    if wb & 0x80:   # sign-extend
                        v = 1
                        for _ in range(j, 16):
                            v = int16((v << 1) | 1)
                    else:
                        v = 0
                    wb = (wb << 1) & 0xff
                    ibits += 1
                    nbits += 1
                    j -= 1
                    while j > 0:
                        v = int16(v << 1)
                        if (ibits & 7) == 0:
                            wb = b(p + (ibits >> 3))
                        if wb & 0x80:
                            v |= 1
                        wb = (wb << 1) & 0xff
                        j -= 1
                        ibits += 1
                        nbits += 1
                    self.x = v
                self.w = wb
                return nbits
            if nbits >= 63:
                break
        self.w = wb
        if self.vflag:
            self.printf("Huffman encoding error\n")
        return 1000000

    def section6(self, p, ln):
        p += 16
        ln -= 16
        if ln <= 6:
            if self.vflag:
                self.printf(" Error: section 6 contains no data\n")
            return 0
        return self.Huffdecode(p, ln, 6)

    def Huffdecode(self, p, ln, section):
        vflag = self.vflag
        pr = self.printf
        b = self.b
        enctype = 2
        tleadlen = 0
        g = float(self.get16(p))
        if section == 5:
            self.gref = g / 5000.0
        else:
            self.gres = g / 5000.0
        if vflag:
            pr("  Amplitude value multiplier: %g nanovolts per unit\n", g)
        sampint = self.get16(p + 2)
        if vflag:
            pr("  Sample time interval: %d microseconds\n", sampint)
        if sampint > 0:
            if self.sfreq > 0 and self.sfreq != 1.0e6 / sampint:
                pr("Warning: section 5 and 6 sample intervals don't match")
            self.sfreq = 1.0e6 / sampint
        elif legacy():      # wfdb-x: as in the C program
            pr("Error: sampling frequency not specified;  assuming 500 Hz\n")
            self.sfreq = 500.0
        else:
            # wfdb-x: C assumed 500 Hz
            pr("Error: sampling frequency not specified\n")
        c = b(p + 3)
        if vflag:
            pr("  Encoding type: %d ", c)
        if c in (0, 1, 2):
            if vflag:
                pr(("(amplitudes)\n", "(first differences)\n",
                    "(second differences)\n")[c])
            enctype = c
        else:
            if vflag:
                pr("<undefined, assuming second differences>\n")
            enctype = 2
        if section == 6:
            c = b(p + 4)
            if vflag:
                pr("  Compression type: %d ", c)
                pr({0: "(non-bimodal)\n", 1: "(bimodal)\n"}.get(
                    c, "<undefined, assuming bimodal>\n"))
        p += 6
        ln -= 6

        nleads = self.nleads
        if nleads < 0:
            if vflag:
                pr("  Error: number of leads undefined -- section 3 missing"
                   " or out of order\n")
            return 0
        if nleads == 0:
            if vflag:
                pr("  Error: no leads recorded\n")
            return 0
        leadlen = []
        for i in range(nleads):
            leadlen.append(self.get16(p))
            tleadlen += leadlen[i]
            if vflag:
                pr("  Lead %d:%5lu bytes\n", i, leadlen[i])
            p += 2
            ln -= 2

        ulen = ln & U64
        if ulen < tleadlen:
            if vflag:
                d = (tleadlen - ulen) & U64
                pr("  Error: %lu data byte%s missing from section %d\n",
                   d, "" if d == 1 else "s", section)
            return 0
        elif ulen > ((tleadlen + 1) & ~1):
            if vflag:
                d = (ulen - tleadlen) & U64
                pr("  Warning: %lu extra byte%s in section %d\n",
                   d, "" if d == 1 else "s", section)

        for i in range(nleads):
            if vflag:
                pr("  Lead %d data\n", i)
                for j in range(10):
                    pr(" %02x", b(p + j))
                pr("\n")
            self.xxx = self.xx = 0
            if section == 6:
                explen = int32(self.nsamp[i])
                dest = self.ecg[i] if self.ecg else None
                gain = self.gres
            else:
                explen = int32(self.rblen)
                dest = self.refbeat[i]
                gain = self.gref
            ibits = 0
            tbits = leadlen[i] * 8
            j = 0
            while j < explen and ibits < tbits:
                ibits += self.getbits(p, ibits)
                x = self.x
                if j == 0:
                    self.xxx = self.xx = x
                elif j == 1:
                    self.dx = int16(x - self.xxx)
                    self.xxx = x
                    self.xx = int16(self.xx + x)
                else:
                    self.dx = int16(self.dx + x)
                    self.xxx = int16(self.xxx + self.dx)
                    self.xx = int16(self.xx + x)
                if enctype == 0:
                    self.xout = x
                elif enctype == 1:
                    self.xout = self.xx
                else:
                    self.xout = self.xxx
                if dest is not None and j < len(dest):
                    dest[j] = d2s(self.xout * gain)
                if vflag > 1:
                    pr("   %5d %5d %5d %5d\n", j, x, self.xx, self.xxx)
                j += 1
            if j < explen:
                if vflag:
                    d = (leadlen[i] - j) & U64
                    pr("   Error: %ld sample%s missing in lead %d\n",
                       int64(d), "" if d == 1 else "s", i)
            if ibits < tbits:
                if vflag:
                    d = tbits - ibits
                    pr("   Warning: %ld extra bit%s in lead %d\n",
                       d, "" if d == 1 else "s", i)
            p += leadlen[i]
            if vflag:
                pr("\n")
        return 1

    def section7(self, p, ln):
        vflag = self.vflag
        pr = self.printf
        b = self.b
        get16 = self.get16
        p += 16
        ln -= 16
        if ln <= 0:
            if vflag:
                pr(" Error: section 7 contains no data\n")
            return 0
        if self.xflag and vflag:
            self.hexdump(p, ln)
        if ln < 20:     # there isn't enough room left for measurements
            if vflag:
                pr(" Error: section 7 is too short (len = %ld)\n", ln)
            return 0

        self.RRint = get16(p + 2)
        # get P onset, etc from first measurement block
        q = p + 6
        self.Pon = get16(q)
        self.Pend = get16(q + 2)
        self.QRSon = get16(q + 4)
        self.QRSend = get16(q + 6)
        self.Tend = get16(q + 8)
        self.Paxis = int16(get16(q + 10))
        self.QRSaxis = int16(get16(q + 12))
        self.Taxis = int16(get16(q + 14))

        nmb = b(p)
        nps = b(p + 1)
        sec7qrs_offset = int16(6 + 16 * nmb + 10 * nps)
        if sec7qrs_offset > ln:
            sec7qrs_offset = int16(ln)
        if sec7qrs_offset > ln:
            if vflag:
                pr(" Error: section 7 is too short (nmb = %d, nps = %d)\n",
                   nmb, nps)
            return 0
        sec7qrs = get16(p + sec7qrs_offset) & 0xff

        if vflag:
            pr(" QRS complexes measured: %d\n", sec7qrs)
            pr(" Measurement blocks: %d\n", nmb)
            if nmb == sec7qrs + 1:
                pr("  (First measurement block contains measurements for"
                   " reference beat type 0;\n"
                   "   Others contain measurements for each individual "
                   "beat)\n")
            else:
                pr("  (Measurements for each reference beat type)\n")
            pr("  Number of measurement blocks: %d\n", nmb)
            pr("  Number of pacemaker spikes: %d\n", nps)
            pr("  Mean RR interval: %d ms\n", self.RRint)
            pr("  Mean PP interval: %d ms\n", get16(p + 4))
            q = p + 6
            for i in range(nmb):
                pr("   Block %d\n", i)
                pr("    P onset:   %d ms\n", get16(q))
                pr("    P end:     %d ms\n", get16(q + 2))
                pr("    QRS onset: %d ms\n", get16(q + 4))
                pr("    QRS  end:  %d ms\n", get16(q + 6))
                pr("    T end:     %d ms\n", get16(q + 8))
                for off, label in ((10, "P axis:   "), (12, "QRS axis: "),
                                   (14, "T axis:   ")):
                    n = int16(get16(q + off))
                    if n == AXIS_UNDEF:
                        pr("    %s undefined\n", label)
                    else:
                        pr("    %s %d degrees\n", label, n)
                q += 16

            if nps > 0:
                pr(" Pacemaker spike measurement data\n")
            r = q + nps * 4
            for i in range(nps):
                pr("Spike %d: %u ms, %d microvolts ", i, get16(q),
                   get16(q + 2))
                c = b(r)
                if c == 0:
                    pr("(unknown spike type, ")
                elif c == 1:
                    pr("(triggers neither P nor QRS, ")
                elif c == 2:
                    pr("(triggers a QRS, ")
                elif c == 3:
                    pr("(triggers a P, ")
                else:
                    pr("(spike type %d, ", c)
                c = b(r + 1)
                if c == 0:
                    pr("source unknown, ")
                elif c == 1:
                    pr("internal, ")
                elif c == 2:
                    pr("external, ")
                else:
                    pr("source type %d, ", c)
                n = int16(get16(r + 2))
                if n == 0:
                    pr(" not linked to a QRS, ")
                else:
                    pr(" linked to QRS #%d, ", n)
                n = int16(get16(r + 4))
                if n == 0:
                    pr("width unknown)\n")
                else:
                    pr("%d microseconds\n)", n)
                q += 4
                r += 6

            # The next part doesn't seem to be right ...
            pr(" <!> sec7qrs = <%d>\n", sec7qrs)
            if sec7qrs > 0:
                pr(" QRS type information (%d beats)\n", get16(r))
            q = r + 2
            for i in range(sec7qrs):
                pr("  QRS %d: reference beat type %d\n", i, b(q))
                q += 1

            pr("%ld bytes remaining in section 7\n", ln - (q - p))
            parts = []
            while q < p + ln:
                # get16(q) reads one byte past the end of the section at
                # the last iteration (read as 0 beyond the end of the data)
                parts.append(" %5d [%3d]" % (get16(q), b(q)))
                q += 1
            parts.append("\n")
            self.out.write("".join(parts))
        return 1

    def section8(self, p, ln):
        vflag = self.vflag
        pr = self.printf
        b = self.b
        p += 16
        ln -= 16
        if ln <= 0:
            if vflag:
                pr(" Error: section 8 contains no data\n")
            return 0
        if vflag:
            c = b(p)
            pr(" Status: %d ", c)
            pr({0: "(original report, not confirmed)\n",
                1: "(confirmed report)\n",
                2: "(overread report, but not confirmed)\n"}.get(
                    c, "<undefined>\n"))
            pr(" Date: %4d/%02d/%02d\n", self.get16(p + 1), b(p + 3),
               b(p + 4))
            pr(" Time: %02d:%02d:%02d\n", b(p + 5), b(p + 6), b(p + 7))
        n = b(p + 8)
        self.stmnts = n
        if vflag:
            pr(" Number of statements: %d\n", n)
        p += 9
        ln -= 9
        i = 0
        while i < n and ln > 2:
            self.report[i] = p + 3
            slen = self.get16(p + 1)
            if vflag:
                pr("  Statement %2d: (%d bytes)\n", b(p), slen)
                pr("   [%*s]\n", slen, self.cstr(p + 3))
            p += slen + 3
            ln -= slen + 3
            i += 1
        if i < n:
            if vflag:
                pr("  Error: data missing in section 8\n")
            return 0
        return 1

    def section9(self, p, ln):
        vflag = self.vflag
        p += 16
        ln -= 16
        if ln <= 0:
            if vflag:
                self.printf(" Error: section 9 contains no data\n")
            return 0
        if vflag:
            parts = ["  Data:\n   "]
            while ln > 0:
                ln -= 1
                c = self.b(p)
                parts.append(chr(c) if isprint(c) else "\\%03o" % c)
                p += 1
            parts.append("\n")
            self.out.write("".join(parts))
        return 1

    def precgmeas(self):
        """Return the measurement table (as precgmeas() prints it)."""
        parts = ["Parameter  Units"]
        meas = self.ecgmeas or []
        for m in meas:
            if 0 < m.leadid < len(LEADNAME):
                parts.append("%8s" % LEADNAME[m.leadid])
            else:
                parts.append("  <%4d>" % m.leadid)
        for label, field in MEASROWS:
            parts.append(label)
            for m in meas:
                val = getattr(m, field)
                if val == 29999:
                    parts.append("  n/comp")     # not computed by analyzer
                elif val == 29998:
                    parts.append("     rej")     # lead rejected
                elif val == 19999:
                    parts.append("  absent")     # wave not present
                else:
                    parts.append("%8d" % val)
        parts.append("\n")
        return "".join(parts)

    def section10(self, p, ln):
        vflag = self.vflag
        p += 16
        ln -= 16
        if ln <= 0:
            if vflag:
                self.printf(" Error: section 10 contains no data\n")
            return 0
        self.nsecleads = nsecleads = self.get16(p)
        if nsecleads > MAXALLOC:
            eprintf("Error: too many (%d) leads\n", nsecleads)
            return 0
        self.ecgmeas = []
        p += 4
        for i in range(nsecleads):
            m = ECGmeas()
            for k, field in enumerate(MEASFIELDS):
                setattr(m, field, int16(self.get16(p + 2 * k)))
            self.ecgmeas.append(m)
            p += m.vlen + 4
        if vflag:
            self.printf(" Results for %d leads\n", nsecleads)
            self.out.write(self.precgmeas())
        return 1

    def section11(self, p, ln):
        p += 16
        ln -= 16
        if ln <= 0:
            if self.vflag:
                self.printf(" Error: section 11 contains no data\n")
            return 0
        return 1

    # ---- main ----

    def main(self, argv):
        pname = self.pname = prog_name(argv[0])
        argc = len(argv)
        i = 1
        while i < argc:
            a = argv[i]
            if a.startswith("-"):
                c = a[1:2]
                if c == "a":
                    self.aflag = 1
                    self.xflag = self.vflag = 0
                elif c == "b":
                    self.bflag = 1
                    self.tflag = 0
                elif c == "f":
                    self.fflag = 1
                elif c == "h":
                    help(pname)
                    raise Exit(1)
                elif c == "l":
                    self.lflag = 1
                elif c == "o":
                    i += 1
                    if i < argc and len(argv[i]) <= RECNAMELEN:
                        self.recname = argv[i]
                    else:
                        eprintf("%s: a record name of 11 or fewer "
                                "alphanumericcharacters must\n follow -o\n",
                                pname)
                        raise Exit(1)
                elif c == "s":
                    i += 1
                    if i < argc:
                        self.shift = atoi(argv[i])
                    else:
                        eprintf("%s: number of samples to shift templates "
                                "must follow -s\n", pname)
                        raise Exit(1)
                elif c == "S":
                    i += 1
                    if i < argc:
                        if argv[i].startswith("-"):
                            self.skip = [1] * NSECTIONS
                        else:
                            index = atoi(argv[i])
                            if 0 <= index < NSECTIONS:
                                self.skip[index] = 1 - self.skip[index]
                    else:
                        eprintf("%s: number of section to skip, or '-', "
                                "must follow -S\n", pname)
                        raise Exit(1)
                elif c == "t":
                    self.tflag = 1
                    self.bflag = 0
                elif c == "v":
                    self.vflag += 1
                    self.aflag = 0
                elif c == "w":
                    self.wflag += 1
                elif c == "x":
                    self.xflag = self.vflag = 1
                    self.aflag = 0
                elif c == "z":
                    self.zflag += 1
                else:
                    eprintf("%s: unrecognized option '%s'\n", pname, a)
                    help(pname)
                    raise Exit(1)
            else:
                eprintf("%s: unrecognized argument '%s'\n", pname, a)
                help(pname)
                raise Exit(1)
            i += 1

        vflag = self.vflag
        pr = self.printf
        stdin = getattr(sys.stdin, "buffer", sys.stdin)
        header = stdin.read(6)
        bytesread = len(header)
        if bytesread != 6:
            eprintf("%s: input too short (only %lu bytes)\n", pname,
                    bytesread)
            raise Exit(1)
        self.data = bytearray(header)
        crc = self.get16(0)
        length = self.get32(2)
        if vflag:
            pr("CRC = %d, expected length = %ld bytes\n", crc, int64(length))
        if length > LONG_MAX:      # malloc() would fail
            eprintf("%s: insufficient memory (%ld bytes needed)\n", pname,
                    int64(length))
            raise Exit(2)
        chunks = [bytes(header)]
        while bytesread < length:
            buf = stdin.read(min(length - bytesread, 1 << 20))  # 1 MiB
            if not buf:
                break
            chunks.append(buf)
            bytesread += len(buf)
        if bytesread < length:
            d = length - bytesread
            eprintf("%s: input too short (%lu byte%s missing)\n", pname, d,
                    "" if d == 1 else "s")
            raise Exit(3)
        self.data = data = bytearray(b"".join(chunks))
        if vflag:
            pr("Record length: %ld bytes\n", length)
        self.crcok(2, length - 2, crc, "Top-level CRC")

        # Now check the sections.
        p = 6   # skip the record header -- p points to section 0
        sections = [self.section0, self.section1, self.section2,
                    self.section3, self.section4, self.section5,
                    self.section6, self.section7, self.section8,
                    self.section9, self.section10, self.section11]
        contents = [
            " Pointers to data areas in the record\n",
            " Header information - Patient data/ECG acquisition data\n",
            " Huffman tables used in encoding of ECG data\n",
            " ECG lead definition\n",
            " QRS locations\n",
            " Encoded reference beat data\n",
            " Residual signal after reference beat subtraction (if reference"
            " beats\n  are stored);  otherwise, encoded rhythm data\n",
            " Global measurements\n",
            " Textual diagnosis from the interpretive device\n",
            " Manufacturer specific diagnostic and overreading data\n",
            " Lead measurement results\n",
            " Universal statement codes resulting from the interpretation\n",
        ]
        while p < length:   # true if there is at least 1 more section
            crc = self.get16(p)
            sec_id = self.get16(p + 2)
            sec_len = self.get32(p + 4)
            if vflag:
                pr("\nSection %d length: %ld bytes\n", sec_id, int64(sec_len))
            if sec_len < 8:
                if vflag:
                    pr(" Warning: section length too short (must be at least "
                       "8 bytes)\n  Remaining data (%lu bytes) following "
                       "short section will not be read\n",
                       (length - (p + 8)) & U64)
                sec_len = 8
            if sec_len > length - p:
                if vflag:
                    pr(" Warning: section length exceeds amount of remaining "
                       "data\n  This section will not be parsed\n")
                break
            self.crcok(p + 2, sec_len - 2, crc, " Section %d CRC" % sec_id)
            if vflag:
                pr(" Section version number: %d\n", self.b(p + 8))
                pr(" Protocol version number: %d\n", self.b(p + 9))
                pr(" Contents: ")
            if sec_id < NSECTIONS:
                if vflag:
                    pr(contents[sec_id])
                if self.skip[sec_id]:
                    pr("  [skipped]\n")
                else:
                    sections[sec_id](p, int64(sec_len))
            elif vflag:
                pr(" Manufacturer-defined (non-standard) section %d\n",
                   sec_id)
            p += sec_len

        nleads = self.nleads
        nsamp = self.nsamp
        ecg = self.ecg
        subz = self.subz
        nqrs = self.nqrs

        # Low-pass filter the residuals.
        for i in range(nleads):
            if ecg[i] is None:
                continue
            n = nsamp[i]
            out = newsig(n)
            if out is None:
                eprintf("Insufficient memory for filtering\n")
                break
            inp = ecg[i]
            if self.tflag == 0:     # true unless -t was given
                out[0] = inp[0]
                j = 1
                while j < n - 1:
                    v = inp[j-1] + inp[j] + inp[j+1]
                    if v > 0:
                        out[j] = (v + 2) // 3
                    elif v < 0:
                        out[j] = -((2 - v) // 3)
                    else:
                        out[j] = 0
                    j += 1
                out[j] = inp[j]
                for k in range(nqrs):
                    z = subz[k]
                    if z is not None and z.type == 0:
                        # restore unfiltered samples within protected zones
                        # and adjacent samples on either end of them
                        for j in range(max(z.t0 - 1, 0),
                                       min(z.t2 + 2, len(out))):
                            out[j] = inp[j]
            ecg[i] = out

        # Add the reference beats back into the residuals.
        if self.bflag == 0:     # true unless -b was given
            rblen = self.rblen
            for k in range(nqrs):
                z = subz[k]
                i = 0
                while z is not None and z.type == 0 and i < nleads:
                    if z.t2 - z.t0 + 1 > rblen:
                        m = None
                    else:
                        m = int32(self.fcM - z.t1 + z.t0 - 1)
                    if m is None or m < 0:
                        eprintf("error: subtraction zone is larger than "
                                "template\n")
                        raise Exit(1)
                    sig = ecg[i]
                    # wfdb-x: a reference beat that was not allocated (e.g.
                    # section 3 follows section 5 and gives more leads) is
                    # absent
                    ref = self.refbeat[i] if self.refbeat and \
                        i < len(self.refbeat) else None
                    if sig is None or ref is None:
                        i += 1
                        continue
                    j = z.t0 - 1 + self.shift
                    jend = z.t2 - 1 + self.shift
                    if j < 0:   # skip samples before the start of the signal
                        m -= j
                        j = 0
                    while j <= jend and j < len(sig) and m < len(ref):
                        sig[j] = int16(sig[j] + ref[m])
                        j += 1
                        m += 1
                    i += 1

        # wfdb-x: signals that could not be allocated (undefined behavior in
        # C) are read as zeros, and so are samples beyond the end of a signal
        # shorter than lead 0.
        if ecg is not None:
            n0 = nsamp[0] if nsamp else 0
            self.nout = n0 = n0 if n0 <= MAXALLOC else 0
            for k, sig in enumerate(ecg):
                if sig is None:
                    ecg[k] = sig = newsig(0)
                if len(sig) < n0:
                    sig.frombytes(bytes(2 * (n0 - len(sig))))

        # Now calculate the missing leads.
        if self.leadIII < 0:    # we need to calculate lead III
            if self.leadI >= 0 and self.leadII >= 0:
                if vflag:
                    pr(" Calculating lead III\n")
                self.leadIII = nleads
                nleads += 1
                l1, l2, l3 = self.sig(self.leadI), self.sig(self.leadII), \
                    self.sig(self.leadIII)
                nsamp[self.leadIII] = min(self.ns(self.leadI),
                                          self.ns(self.leadII))
                for j in range(min(nsamp[self.leadIII], len(l1), len(l2),
                                   len(l3))):
                    l3[j] = int16(l2[j] - l1[j])
            elif self.leadI < 0:
                if self.leadII < 0:
                    eprintf("Leads I, II, and III are missing\n")
                else:
                    eprintf("Leads I and III are missing\n")
            else:
                eprintf("Leads II and III are missing\n")
        elif self.leadII < 0:   # we need to calculate lead II
            if self.leadI >= 0:
                if vflag:
                    pr(" Calculating lead II\n")
                self.leadII = nleads
                nleads += 1
                nsamp[self.leadII] = min(self.ns(self.leadI),
                                         self.ns(self.leadIII))
                l1, l2, l3 = self.sig(self.leadI), self.sig(self.leadII), \
                    self.sig(self.leadIII)
                for j in range(n0):
                    l2[j] = int16(l1[j] + l3[j])
            else:
                eprintf("Leads I and II are missing\n")
        elif self.leadI < 0:    # we need to calculate lead I
            if vflag:
                pr(" Calculating lead I\n")
            self.leadI = nleads
            nleads += 1
            nsamp[self.leadI] = min(self.ns(self.leadII),
                                    self.ns(self.leadIII))
            l1, l2, l3 = self.sig(self.leadI), self.sig(self.leadII), \
                self.sig(self.leadIII)
            for j in range(n0):
                l1[j] = int16(l2[j] - l3[j])

        # We need both lead I and lead II to derive aVR.
        if self.aVR < 0:
            if self.leadI >= 0 and self.leadII >= 0:
                if vflag:
                    pr(" Calculating lead aVR\n")
                self.aVR = nleads
                nleads += 1
                nsamp[self.aVR] = min(self.ns(self.leadI),
                                     self.ns(self.leadII))
                l1, l2, out = self.sig(self.leadI), self.sig(self.leadII), \
                    self.sig(self.aVR)
                for j in range(n0):
                    out[j] = int16(-cdiv(l1[j] + l2[j], 2))
            else:
                eprintf("Lead aVR cannot be derived\n")

        # We need both lead II and lead III to derive aVL.
        if self.aVL < 0:
            if self.leadII >= 0 and self.leadIII >= 0:
                if vflag:
                    pr(" Calculating lead aVL\n")
                self.aVL = nleads
                nleads += 1
                nsamp[self.aVL] = min(self.ns(self.leadII),
                                     self.ns(self.leadIII))
                l2, l3, out = self.sig(self.leadII), self.sig(self.leadIII), \
                    self.sig(self.aVL)
                for j in range(n0):
                    out[j] = int16(cdiv(l2[j], 2) - l3[j])
            else:
                eprintf("Lead aVL cannot be derived\n")

        # We need both lead I and lead III to derive aVF.
        if self.aVF < 0:
            if self.leadI >= 0 and self.leadII >= 0:
                if vflag:
                    pr(" Calculating lead aVF\n")
                self.aVF = nleads
                nleads += 1
                nsamp[self.aVF] = min(self.ns(self.leadI),
                                     self.ns(self.leadIII))
                l1, l3, out = self.sig(self.leadI), self.sig(self.leadIII), \
                    self.sig(self.aVF)
                for j in range(n0):
                    out[j] = int16(cdiv(l1[j], 2) + l3[j])
            else:
                eprintf("Lead aVF cannot be derived\n")

        for name in ("V1", "V2", "V3", "V4", "V5", "V6"):
            if getattr(self, name) < 0:
                eprintf("Lead %s is missing\n", name)

        names = ("leadI", "leadII", "leadIII", "aVR", "aVF", "aVL",
                 "V1", "V2", "V3", "V4", "V5", "V6")
        if nleads > 0 and any(getattr(self, k) < 0 for k in names):
            # Use an array of zero samples for the missing lead(s).
            if ecg[nleads] is None:
                ecg[nleads] = newsig(0)
            for k in names:
                if getattr(self, k) < 0:
                    setattr(self, k, nleads)
        self.nleads = nleads

        if self.aflag:
            # Recalculate the top-level CRC.
            crc = self.getcrc(2, bytesread - 2)
            self.put16(crc, 0)
            self.out.write(data[:bytesread].decode("latin-1"))
        elif nleads > 0:
            self.zbuf = [0] * MINSIGLEN
            self.write_output()
        return 0


def help(pname):
    eprintf("usage: %s -o RECORD [OPTIONS ...] <SCPFILE\n", pname)
    eprintf("%s", HELP)


def main(argv=None):
    """Run parsescp as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["parsescp"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["parsescp"] + sys.argv[1:]
    out = Output()
    return run(lambda a: Parser(out).main(a), argv, out)


if __name__ == "__main__":
    sys.exit(main())
