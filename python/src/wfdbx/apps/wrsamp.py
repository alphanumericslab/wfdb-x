"""wrsamp: read a text file of samples and write WFDB signal (and header) files.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of app/wrsamp.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original program, but it is new code, not the original C code.

Changes from the original: no built-in sampling frequency, gain, ADC resolution
or units: when a record is written (-o), -F, -G and the new option -R BITS are
required, and the new option -U UNITS for calibrated signals unless the input
gives the units (the original assumed 250 Hz, 200 adu/mV, a resolution based on
the format, and millivolts); -G 0 declares the signals uncalibrated; -G, -R and
-U take one value per signal; --legacy, as the first argument, restores the
original behavior. Each change is marked "WFDB-x:" in the code;
docs/DIVERGENCES.md gives the reasons.

Original C program: app/wrsamp.c, WFDB Software Package 10.7.0.
  Copyright (C) 1993-2014 George B. Moody; revised 2020 by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

import wfdbx as w
from wfdbx._cstd import (GlibcRand, atof, atoi, d2i, int32, sscanf, strtol,
                         uint32)
from ._common import Exit, eprintf, eprint, legacy, legacy_help, run

HELP = [
    "usage: %s [OPTIONS ...] [COLUMN ...]\n",
    "where COLUMN selects a field to be copied (leftmost field is column 0),",
    "and OPTIONS may include:",
    " -c          check that each input line contains the same number of "
    "fields",
    " -d          add dither to the input",
    " -f N        start copying with line N (default: 0)",
    " -F FREQ     specify frequency to be written to header file (required",
    "              with -o)",
    " -G GAIN     specify gain(s) to be written to header file (required with",
    "              -o; 0 means uncalibrated)",
    " -h          print this usage summary",
    " -i FILE     read input from FILE (default: standard input)",
    " -o RECORD   save output in RECORD.dat, and generate a header file for",
    "              RECORD (default: write to standard output in format 16, do",
    "              not generate a header file)",
    " -O FORMAT   save output in the specified FORMAT (default: 16)",
    " -r RSEP     interpret RSEP as the input line separator (default: "
    "linefeed)",
    " -R BITS     specify ADC resolution(s) in bits (required with -o)",
    " -s FSEP     interpret any character in FSEP as an input field separator",
    "             (default: space, tab, carriage-return, or comma)  ",
    " -t N        stop copying at line N (default: end of input file)",
    " -U UNITS    specify units (required with -o for calibrated signals, "
    "unless",
    "              the input gives them)",
    " -x SCALE    multiply inputs by SCALE factor(s) (default: 1)",
    " -z          don't copy column 0 unless explicitly specified",
    "",
    "The input is a text file with a sample of each signal on each line. "
    "Samples",
    "can be separated by tabs, spaces, commas, or any combination of these.",
    "Consecutive separators are equivalent to single separators.",
    "",
    "To specify different GAIN or SCALE values for each output signal, "
    "provide",
    "a quoted list of values, e.g., -G \"100 50\" defines the gain for signal "
    "0",
    "as 100, and the gain for signal 1 (and any additional signals) as 50.",
    "",
    "If the first input line contains any alphabetic characters, it is "
    "assumed",
    "to contain column headings, which are copied as signal descriptions into",
    "RECORD.hea.  If the second input line also contains alphabetic "
    "characters,",
    "it is assumed to specify the physical units for each column, which are",
    "copied as units strings into RECORD.hea.  The first line containing "
    "samples",
    "is line 0.",
    "",
    "If no COLUMN is specified, all fields are copied in order; column 0 can "
    "be",
    "omitted in this case by using the '-z' option.",
]

# WFDB-x: the help text of the original program, printed in legacy mode
LEGACY_HELP = legacy_help(HELP, {
    " -F FREQ     specify frequency to be written to header file (required":
    " -F FREQ     specify frequency to be written to header file (default: "
    "250)",
    "              with -o)": None,
    " -G GAIN     specify gain(s) to be written to header file (required with":
    " -G GAIN     specify gain(s) to be written to header file (default: 200)",
    "              -o; 0 means uncalibrated)": None,
    " -R BITS     specify ADC resolution(s) in bits (required with -o)": None,
    " -U UNITS    specify units (required with -o for calibrated signals, "
    "unless": None,
    "              the input gives them)": None})


def help(pname):
    hs = LEGACY_HELP if legacy() else HELP     # WFDB-x
    eprintf(hs[0], pname)
    for i in range(1, len(hs)):
        eprintf("%s\n", hs[i])
        if i % 23 == 0:         # pause after each screenful, as C does
            eprint("--More--")
            try:
                sys.stdin.buffer.readline(4)    # fgets(b, 5, stdin)
            except (OSError, ValueError):
                pass
            eprint("\033[A\033[2K")


class _LineReader:
    """read_line(): lines delimited by rsep; an unterminated tail is lost."""

    def __init__(self, data, rsep):
        self.data = data
        self.pos = 0
        self.rsep = rsep.encode("latin-1")

    def read_line(self):
        j = self.data.find(self.rsep, self.pos)
        if j < 0:
            self.pos = len(self.data)
            return None
        s = self.data[self.pos:j].decode("latin-1")
        self.pos = j + 1
        return s


def line_has_alpha(line):
    if line is None:
        return 0
    n = len(line)
    p = 0
    while p < n:
        c = line[p]
        if c in "eE":
            p += 1
            nc = line[p] if p < n else "\0"
            if nc <= "9" or nc == "-" or nc == "+":
                p += 1
                continue
            c = nc
        if ("A" <= c <= "Z") or ("a" <= c <= "z"):
            return 1
        p += 1
    return 0


def line_has_tab(line):
    return 1 if line is not None and "\t" in line else 0


def parseline(line, delim, esc="\\"):
    """Split a line into tokens as parseline() in wrsamp.c does."""
    tokens = []
    n = len(line)
    p = 0
    while p < n:
        while p < n and line[p] in delim:
            p += 1
        if p >= n:
            break
        q = ""
        c = line[p]
        if c == '"' or c == "'":
            q = c
            p += 1
        elif c == "<":
            p += 1
            q = ">"
        buf = []
        while p < n and (q or line[p] not in delim):
            c = line[p]
            if esc and c == esc:
                if p + 1 >= n:
                    break
                buf.append(line[p + 1])
                p += 2
                continue
            if c == q:
                p += 1
                q = ""
                break
            buf.append(c)
            p += 1
        tokens.append("".join(buf))
    return tokens


def _legacy_adcres(fmt):
    """WFDB-x: legacy mode (original behavior): the ADC resolution (bits)
    for samples written in format fmt."""
    if fmt in (508, 80):
        return 8
    if fmt in (310, 311):
        return 10
    if fmt == 212:
        return 12
    if fmt in (516, 16, 160, 61):
        return 16
    if fmt in (524, 24):
        return 24
    if fmt == 32:
        return 32
    # resolution for unknown future formats
    if fmt > 100 and fmt % 100 > 0 and fmt % 100 <= 32:
        return fmt % 100
    return w.WFDB_DEFRES


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    gain = ""
    scale = ""
    res = ""        # WFDB-x: -R
    uopt = None     # WFDB-x: -U
    record = None
    rsep = "\n"
    sflag = 0
    xflag = zflag = dflag = 0
    # WFDB-x: no default frequency (C, legacy mode: 250 Hz)
    freq = w.WFDB_DEFFREQ if legacy() else 0.0
    fmt = 16
    t0 = t1 = 0
    delim = " \t\r\n,"
    rng = None
    infile = None
    i = 1
    while i < argc and argv[i].startswith("-"):
        c = argv[i][1:2]
        if c == "c":
            pass
        elif c == "d":
            dflag = 1
            rng = GlibcRand(0)
        elif c == "f":
            i += 1
            if i < argc:
                t0 = strtol(argv[i])[0]
            if i >= argc or t0 <= 0:
                eprintf("%s: starting line # must follow -f\n", pname)
                raise Exit(1)
        elif c == "F":
            i += 1
            if i < argc:
                freq = atof(argv[i])
            if i >= argc or freq <= 0.0:
                eprintf("%s: sampling frequency must follow -F\n", pname)
                raise Exit(1)
        elif c == "G":
            i += 1
            if i >= argc:
                eprintf("%s: gain(s) must follow -G\n", pname)
                raise Exit(1)
            gain = argv[i]
        elif c == "h":
            help(pname)
            raise Exit(1)
        elif c == "R" and not legacy():    # WFDB-x: ADC resolution(s)
            i += 1
            if i >= argc:
                eprintf("%s: ADC resolution(s) must follow -R\n", pname)
                raise Exit(1)
            res = argv[i]
        elif c == "U" and not legacy():    # WFDB-x: units
            i += 1
            if i >= argc:
                eprintf("%s: units must follow -U\n", pname)
                raise Exit(1)
            uopt = argv[i]
        elif c == "i":
            i += 1
            if i >= argc:
                eprintf("%s: input file name must follow -i\n", pname)
                raise Exit(1)
            if argv[i] == "-":
                infile = None
            else:
                try:
                    with open(argv[i], "rb") as f:
                        infile = f.read()
                except OSError:
                    eprintf("%s: can't read `%s'\n", pname, argv[i])
                    raise Exit(2)
        elif c == "l":
            i += 1
            if i >= argc:
                i -= 1
            eprintf("%s: -l is obsolete, ignored\n", pname)
        elif c == "o":
            i += 1
            if i >= argc:
                eprintf("%s: record name must follow -o\n", pname)
                raise Exit(1)
            record = argv[i]
        elif c == "O":
            i += 1
            if i >= argc:
                eprintf("%s: output format must follow -O\n", pname)
                raise Exit(1)
            fmt = atoi(argv[i])
        elif c == "r":
            i += 1
            if i >= argc:
                eprintf("%s: line separator must follow -r\n", pname)
                raise Exit(1)
            rsep = argv[i][:1] or "\0"
        elif c == "s":
            i += 1
            if i >= argc:
                eprintf("%s: field separator(s) must follow -s\n", pname)
                raise Exit(1)
            sflag = 1
            delim = argv[i]
        elif c == "t":
            i += 1
            if i < argc:
                t1 = strtol(argv[i])[0]
            if i >= argc or t1 <= 0:
                eprintf("%s: ending line # must follow -t\n", pname)
                raise Exit(1)
        elif c == "x":
            i += 1
            if i >= argc:
                eprintf("%s: scaling factor(s) must follow -x\n", pname)
                raise Exit(1)
            scale = argv[i]
        elif c == "z":
            zflag = 1
        else:
            eprintf("%s: unrecognized option %s\n", pname, argv[i])
            raise Exit(1)
        i += 1
    # WFDB-x: the sampling frequency, the gains, the ADC resolutions, and the
    # units (of calibrated signals) must be specified when a header is
    # written (C assumed 250 Hz, 200 adu/mV, a resolution based on the
    # format, and millivolts), as legacy mode does.
    if record is not None and not legacy():
        if freq <= 0.0:
            eprintf("%s: the sampling frequency must be specified (-F)\n",
                    pname)
            raise Exit(1)
        if gain == "":
            eprintf("%s: the gain(s) must be specified (-G)\n", pname)
            raise Exit(1)
        if res == "":
            eprintf("%s: the ADC resolution(s) must be specified (-R)\n",
                    pname)
            raise Exit(1)
    nosig = argc - i
    if infile is None:
        infile = sys.stdin.buffer.read()
    rd = _LineReader(infile, rsep)
    line = rd.read_line()
    if line is None:
        if rsep != "\n":
            if record is None:
                eprintf("%s: use -o to specify the output record name", pname)
            else:
                eprintf("%s: no record separators in input\n"
                        "Try specifying a different separator after the -r "
                        "option.\n", pname)
        else:
            eprintf("%s: no newlines in input\n", pname)
        raise Exit(3)
    dstrings = ustrings = None
    ncols = 0
    if line.startswith("<?xml "):
        xflag = zflag = 1
        while True:
            line = rd.read_line()
            if line is None:
                eprintf("%s: XML input, but no <wfdbsampleset> found\n",
                        pname)
                raise Exit(1)
            if line == "<wfdbsampleset>":
                break
        while True:
            line = rd.read_line()
            if line is None:
                eprintf("%s: empty <wfdbsampleset>\n", pname)
                raise Exit(1)
            # Skip the opening tag (and drop the closing tag).
            if line.startswith("<samplingfrequency>"):
                n, v = sscanf(line[len("<samplingfrequency>"):], "%lf")
                if n == 1:
                    freq = v[0]
            elif line.startswith("<description>"):
                ta = parseline(line[len("<description>"):
                                    -len("</description>")], delim)
                dstrings = list(ta)
                ncols = len(ta)
            elif line.startswith("<units>"):
                ta = parseline(line[len("<units>"):-len("</units>")], delim)
                ustrings = list(ta)
            if line == "<samplevectors>":
                break
        line = rd.read_line()
        if line is None:
            eprintf("%s: empty <wfdbsampleset>\n", pname)
            raise Exit(1)
    else:
        if sflag == 0 and line_has_tab(line):
            delim = "\t"
        ta = parseline(line, delim)
        ncols = len(ta)
        if line_has_alpha(line):
            dstrings = [t.lstrip(" ") for t in ta]
            line = rd.read_line()
            if line is None:
                eprintf("%s: no data\n", pname)
                raise Exit(1)
            elif line_has_alpha(line):
                ta = parseline(line, delim)
                ustrings = []
                for t in ta:
                    t = t.lstrip(" ")
                    if t.startswith("("):
                        last = t[-1:]
                        t = t[1:]
                        if last == ")":
                            t = t[:-1]
                    ustrings.append(t)
                line = rd.read_line()
                if line is None:
                    eprintf("%s: no data\n", pname)
                    raise Exit(1)
    if nosig:
        fv = []
        for k in range(argc - nosig, argc):
            n, v = sscanf(argv[k], "%d")
            if n != 1 or int32(v[0]) < 0 or int32(v[0]) >= ncols:
                eprintf("%s: unrecognized argument %s\n", pname, argv[k])
                raise Exit(1)
            fv.append(int32(v[0]))
    else:
        nosig = ncols - zflag
        fv = list(range(zflag, zflag + nosig))
    ofname = "-" if record is None else record + ".dat"
    si = []
    scalef = []
    for k in range(nosig):
        s = w.Siginfo()
        s.fname = ofname
        if dstrings is not None:
            s.desc = dstrings[fv[k]] if fv[k] < len(dstrings) else ""
        else:
            s.desc = "col %d" % fv[k]
        if uopt is not None:    # WFDB-x: -U (the last one applies to the rest)
            uopt = uopt.lstrip(" ")
            if uopt:
                j = uopt.find(" ")
                if j < 0:
                    j = len(uopt)
                s.units = uopt[:j]
                uopt = uopt[j:]
            else:
                s.units = si[k - 1].units if k > 0 else ""
        elif ustrings is not None:
            s.units = ustrings[fv[k]] if fv[k] < len(ustrings) else ""
        else:
            s.units = ""
        s.group = 0
        s.fmt = fmt
        s.spf = 1
        s.bsize = 0
        # WFDB-x: the ADC resolutions are given by -R (the last one applies
        # to the remaining signals); C (and legacy mode) inferred them from
        # the format or assumed WFDB_DEFRES.
        if legacy():
            s.adcres = _legacy_adcres(fmt)
        else:
            res = res.lstrip(" ")
            n, v = sscanf(res, "%d")
            if n < 1:
                s.adcres = 0 if k == 0 else si[k - 1].adcres
            else:
                s.adcres = int32(v[0])
                j = 0
                while j < len(res) and res[j] != " ":
                    j += 1
                res = res[j:]
            if record is not None and s.adcres < 1:
                eprintf("%s: the ADC resolution(s) must be specified (-R)\n",
                        pname)
                raise Exit(1)
        s.adczero = 0
        s.baseline = 0
        gain = gain.lstrip(" ")
        n, v = sscanf(gain, "%lf")
        if n < 1:
            # WFDB-x: C (legacy mode): WFDB_DEFGAIN
            if k > 0:
                s.gain = si[k - 1].gain
            else:
                s.gain = w.WFDB_DEFGAIN if legacy() else 0.0
        else:
            s.gain = v[0]
            j = 0
            while j < len(gain) and gain[j] != " ":
                j += 1
            gain = gain[j:]
        # WFDB-x: the units of a calibrated signal must be specified, by -U
        # or by the input (C left them out: millivolts).
        if (record is not None and not legacy() and s.gain != 0.0 and
                not s.units):
            eprintf("%s: the units must be specified (-U)\n", pname)
            raise Exit(1)
        scale = scale.lstrip(" ")
        n, v = sscanf(scale, "%lf")
        if n < 1:
            scalef.append(1.0 if k == 0 else scalef[k - 1])
        else:
            scalef.append(v[0])
            j = 0
            while j < len(scale) and scale[j] != " ":
                j += 1
            scale = scale[j:]
        si.append(s)
    while line_has_alpha(line):
        line = rd.read_line()
    # (nosig is unsigned in C, so an error (-1) from osigfopen passes)
    if uint32(w.osigfopen(si, nosig)) < nosig or w.setsampfreq(freq) < 0:
        raise Exit(2)
    t = 0
    while t < t0:
        line = rd.read_line()
        t += 1
    if zflag and line is not None:      # base time (23 characters, as C)
        if line.startswith("["):
            w.setbasetime(line[1:24])
        elif line[1:2] == "[":
            w.setbasetime(line[2:25])
    vout = [0] * nosig
    while line is not None:
        if t1 != 0:
            tt = t
            t += 1
            if not tt < t1:
                break
        ta = parseline(line, delim)
        for k in range(nosig):
            tok = ta[fv[k]] if fv[k] < len(ta) else ""
            n, v = sscanf(tok, "%lf")
            if n == 1:
                x = v[0] * scalef[k]
                if dflag:
                    x += (float(rng.rand()) + float(rng.rand())) / \
                        GlibcRand.RAND_MAX - 1.0
                vout[k] = d2i(x + 0.5) if x >= 0 else d2i(x - 0.5)
            else:
                vout[k] = w.WFDB_INVALID_SAMPLE
        if w.putvec(vout) < 0:
            break
        line = rd.read_line()
        if line is not None and xflag and line.startswith("</samplevectors>"):
            line = rd.read_line()
            if line is not None and line != "</wfdbsampleset>":
                eprintf("%s: (warning) unexpected EOF in XML input\n", pname)
            break
    w.setsampfreq(freq)
    if record is not None:
        w.newheader(record)
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run wrsamp as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["wrsamp"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["wrsamp"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
