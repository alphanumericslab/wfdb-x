"""xform: sampling frequency, amplitude, and format conversion for WFDB records.

Copyright (C) 1983-2010 George B. Moody (original C program, app/xform.c;
revised 2017-2020 by Benjamin Moody).
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
from wfdbx._cstd import GlibcRand, d2i, d2l, int32, sscanf, cmod
from ._common import (Exit, eprintf, eprint, freq_not_specified, legacy,
                      run)

HELP = [
    "usage: %s -i IREC [OPTIONS ...]\n",
    "where IREC is the name of the record to be converted, and OPTIONS may",
    " include any of:",
    " -a ANNOTATOR [ANNOTATOR ...]  copy annotations for the specified "
    "ANNOTATOR",
    "              from IREC;  two or more ANNOTATORs may follow -a",
    " -c          clip output (default: wrap around if out-of-range)",
    " -d          add dither to the input if changing sampling frequency or "
    "gain",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          open the input record in `high resolution' mode",
    " -M          process multifrequency record without changing frequencies",
    " -n NREC     create a header file, using record name NREC and signal",
    "              descriptions from IREC",
    " -N NREC     as for -n, but copy signal descriptions from OREC",
    " -o OREC     produce output signal file(s) as specified by the header "
    "file",
    "              for record OREC",
    " -s SIGNAL [SIGNAL ...]  write only the specified signal(s)",
    " -S SCRIPT   take answers to prompts from SCRIPT (a text file)",
    " -t TIME     stop at specified time",
    " -u          adjust annotation times if needed to make them unique",
    "Unless you use `-o' to specify an *existing* header that describes the",
    "desired signal files, you will be asked for output specifications.  Use",
    "`-n' to name the record to be created.  Use `-s' to select a subset of "
    "the",
    "input signals, or to re-order them in the output file;  arguments that",
    "follow `-s' are *input* signal numbers (0,1,2,...) or names.",
]

FORMATS = w.WFDB_FMT_LIST
ANSWERLEN = 32          # size of the buffers for answers to prompts, as in C


class _Input:
    """A text stream read with fgets() semantics."""

    def __init__(self, fp):
        self.fp = fp

    def fgets(self, size):
        b = self.fp.readline(size - 1)
        if not b:
            return None
        return b.decode("latin-1")


def gcd(x, y):
    """Approximate greatest common divisor (as in xform.c)."""
    tol = 0.001 * y if x > y else 0.001 * x
    while True:
        if x > y and x - y > tol:
            x -= y
        elif y > x and y - x > tol:
            y -= x
        else:
            return x


class _XForm:
    def __init__(self, pname):
        self.pname = pname
        self.script = None
        self.rng = None

    def script_fgets(self, ttyin, length):
        s = ttyin.fgets(length)
        if s is None:
            if self.script is not None:
                eprintf("\n%s: unexpected end of file in %s\n", self.pname,
                        self.script)
                raise Exit(1)
            s = "\n"
        return s

    def dither(self):
        r = self.rng
        return (float(r.rand()) + float(r.rand())) / GlibcRand.RAND_MAX - 1.0


def _round(vd):
    return d2i(vd + 0.5) if vd >= 0 else d2i(vd - 0.5)


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    X = _XForm(pname)
    irec = orec = nrec = None
    startp = "0:0"
    ofreq = 0.0
    clip = dflag = fflag = gflag = Hflag = Mflag = 0
    nann = nosig = reopen = sflag = uflag = 0
    nminutes = 0
    use_irec_desc = 1
    siglist = []
    siglist_args = []
    frm = it = ot = to = 0
    nsamp = -1
    nsm = 0
    ainames = []
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "a":
                j = 0
                while True:
                    i += 1
                    if not (i < argc and (j == 0 or not
                                          argv[i].startswith("-"))):
                        break
                    j += 1
                if j == 0:
                    eprintf("%s: annotator(s) must follow -a\n", pname)
                    raise Exit(1)
                i -= j
                j = 0
                while i < argc and (j == 0 or not argv[i].startswith("-")):
                    ainames.append(argv[i])
                    nann += 1
                    i += 1
                    j += 1
                i -= 1
            elif c == "c":
                clip = 1
            elif c == "d":
                dflag = 1
                X.rng = GlibcRand(0)
            elif c == "f":
                i += 1
                if i >= argc:
                    eprintf("%s: time must follow -f\n", pname)
                    raise Exit(1)
                frm = i
            elif c == "h":
                eprintf(HELP[0], pname)
                for s in HELP[1:]:
                    eprintf("%s\n", s)
                raise Exit(0)
            elif c == "H":
                Hflag = 1
            elif c == "i":
                i += 1
                if i >= argc:
                    eprintf("%s: input record name must follow -i\n", pname)
                    raise Exit(1)
                irec = argv[i]
            elif c == "M":
                Mflag = 1
            elif c in ("n", "N"):
                if c == "N":
                    use_irec_desc = 0
                i += 1
                if i >= argc:
                    eprintf("%s: new record name must follow -%s\n", pname, c)
                    raise Exit(1)
                nrec = argv[i]
            elif c == "o":
                i += 1
                if i >= argc:
                    eprintf("%s: output record name must follow -o\n", pname)
                    raise Exit(1)
                orec = argv[i]
            elif c == "s":
                sflag = 1
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
                    siglist_args.append(i)
                    nosig += 1
                    i += 1
                i -= 1
            elif c == "S":
                i += 1
                if i >= argc:
                    eprintf("%s: script name must follow -S\n", pname)
                    raise Exit(1)
                X.script = argv[i]
            elif c == "t":
                i += 1
                if i >= argc:
                    eprintf("%s: time must follow -t\n", pname)
                    raise Exit(1)
                to = i
            elif c == "u":
                uflag = 1
            else:
                eprintf("%s: unrecognized option %s\n", pname, a)
                raise Exit(1)
        else:
            eprintf("%s: unrecognized argument %s\n", pname, a)
            raise Exit(1)
        i += 1
    if irec is None:
        eprintf(HELP[0], pname)
        for s in HELP[1:]:
            eprintf("%s\n", s)
        raise Exit(1)
    if nrec is not None and orec is not None and nrec == orec:
        eprintf("%s: arguments of -n (or -N) and -o cannot be identical\n",
                pname)
        raise Exit(1)
    nisig = w.isigopen(irec, None, 0)
    if nisig < 0:
        raise Exit(2)
    dfin = []
    dfout = []
    if nisig == 0:
        nosig = 0
    else:
        if w.isigopen(irec, dfin, nisig) != nisig:
            raise Exit(2)
        if sflag:
            siglist = list(siglist_args)
            i = 0
            while i < nosig and nosig > 0:
                s = argv[siglist[i]]
                siglist[i] = w.findsig(s)
                if siglist[i] < 0:
                    eprintf("%s: warning: record %s doesn't have a signal "
                            "'%s'\n", pname, irec, s)
                    del siglist[i]
                    nosig -= 1
                    i -= 1
                i += 1
            if nosig == 0:
                sflag = 0
        if sflag == 0:
            nosig = nisig
            siglist = list(range(nosig))
    if Mflag:
        w.setgvmode(w.WFDB_LOWRES)
    elif Hflag:
        w.setgvmode(w.WFDB_HIGHRES)
    ifreq = w.sampfreq(None)
    # wfdb-x: no default sampling frequency (C assumed 250 Hz if the input
    # header did not specify one, as legacy mode does).
    if ifreq <= 0.0 and not legacy():
        freq_not_specified(pname, irec)
        w.wfdbquit()
        raise Exit(2)
    spf = w.getspf()
    if Mflag:
        iframelen = sum(dfin[k].spf for k in range(nisig))
        oframelen = sum(dfin[siglist[k]].spf for k in range(nosig))
    else:
        iframelen = nisig
        oframelen = nosig
    fmt = 0
    if orec is not None:
        if nrec is not None and w.newheader(nrec) < 0:
            raise Exit(2)
        ofreq = w.sampfreq(orec)
        # wfdb-x: no default sampling frequency (legacy mode: no check)
        if ofreq == 0.0 and not legacy():
            freq_not_specified(pname, orec)
            w.wfdbquit()
            raise Exit(2)
        w.setsampfreq(ifreq / spf)
        if ifreq != ofreq and Mflag != 0:
            eprintf("%s: -M option may not be used if sampling frequency is "
                    "to be changed\n", pname)
            w.wfdbquit()
            raise Exit(1)
    else:
        ttyfp = None
        try:
            ttyfp = open(X.script if X.script is not None else "/dev/tty",
                         "rb")
        except OSError:
            ttyfp = None
        ttyin = _Input(ttyfp if ttyfp is not None else sys.stdin.buffer)
        if nrec is None:
            while True:
                eprintf("Choose a name for the output record (up to %d "
                        "characters): ", w.WFDB_MAXRNL)
                record = X.script_fgets(ttyin, w.WFDB_MAXRNL + 2)
                record = record[:-1]
                if record != "" and w.newheader(record) >= 0:
                    break
            nrec = record
        if sflag == 0:
            while True:
                nosig = nisig
                eprintf("Number of signals to be written (1-%d) [%d]: ",
                        nisig, nosig)
                answer = X.script_fgets(ttyin, ANSWERLEN)
                n, v = sscanf(answer, "%d")
                if n == 1:
                    nosig = int32(v[0])
                if nosig == 0:
                    eprintf("No signals will be written.  Are you sure? "
                            "[n]: ")
                    answer = X.script_fgets(ttyin, ANSWERLEN)
                    if answer[:1] not in ("y", "Y"):
                        nosig = -1
                if not (nosig < 0 or nosig > nisig):
                    break
        if Mflag:
            ofreq = ifreq
            eprintf("Sampling frequency (%g frames/sec) will be unchanged\n",
                    ofreq)
        else:
            while True:
                ofreq = ifreq
                eprintf("Output sampling frequency (Hz per signal, > 0) "
                        "[%g]: ", ofreq)
                answer = X.script_fgets(ttyin, ANSWERLEN)
                n, v = sscanf(answer, "%lf")
                if n == 1:
                    ofreq = v[0]
                if not ofreq < 0:
                    break
        if ofreq == 0 and legacy():
            ofreq = w.WFDB_DEFFREQ  # wfdb-x: as in the C program
        elif ofreq == 0:    # wfdb-x: C assumed 250 Hz
            eprintf("%s: the output sampling frequency must be > 0\n", pname)
            w.wfdbquit()
            raise Exit(1)
        if nosig > 0:
            eprint("Specify the name of the directory in which the output\n")
            eprint(" signals should be written, or press <return> to write\n")
            eprint(" them in the current directory: ")
            directory = X.script_fgets(ttyin, ANSWERLEN - 1)
            if directory.startswith("\n"):
                directory = ""
            else:
                directory = directory[:-1] + "/"
            eprint("Any of these output formats may be used:\n")
            eprint("    8   8-bit first differences\n")
            eprint("   16   16-bit two's complement amplitudes (LSB first)\n")
            eprint("   61   16-bit two's complement amplitudes (MSB first)\n")
            eprint("   80   8-bit offset binary amplitudes\n")
            eprint("  160   16-bit offset binary amplitudes\n")
            eprint("  212   2 12-bit amplitudes bit-packed in 3 bytes\n")
            eprint("  310   3 10-bit amplitudes bit-packed in 15 LS bits of "
                   "each of 2 words\n")
            eprint("  311   3 10-bit amplitudes bit-packed in 30 LS bits of 4 "
                   "bytes\n")
            eprint("   24   24-bit two's complement amplitudes (LSB first)\n")
            eprint("   32   32-bit two's complement amplitudes (LSB first)\n")
            eprint("  508  8-bit amplitudes with FLAC compression\n")
            eprint("  516  16-bit amplitudes with FLAC compression\n")
            eprint("  524  24-bit amplitudes with FLAC compression\n")
            while True:
                fmt = dfin[0].fmt
                eprintf("Choose an output format from the list above [%d]: ",
                        fmt)
                answer = X.script_fgets(ttyin, ANSWERLEN)
                n, v = sscanf(answer, "%d")
                if n == 1:
                    fmt = int32(v[0])
                if fmt in FORMATS[1:]:
                    break
            if nosig > 1:
                eprint("Save all signals in one file? [y]: ")
                answer = X.script_fgets(ttyin, ANSWERLEN)
            dfout = [dfin[siglist[k]].copy() for k in range(nosig)]
            if nosig <= 1 or answer[:1] not in ("n", "N"):
                fn = "%s%s.dat" % (directory, nrec)
                for k in range(nosig):
                    dfout[k].fname = fn
                    dfout[k].group = 0
            else:
                for k in range(nosig):
                    dfout[k].fname = "%s%s.d%d" % (directory, nrec, k)
                    dfout[k].group = k
        for k in range(nosig):
            d = dfout[k]
            d.fmt = fmt
            if Mflag == 0:
                d.spf = 1
            d.bsize = 0
            if not use_irec_desc:
                eprintf("Signal %d description (up to %d characters): ",
                        k, w.WFDB_MAXDSL)
                desc = X.script_fgets(ttyin, w.WFDB_MAXDSL + 2)
                d.desc = desc[:-1]
                eprintf("Signal %d units (up to %d characters): ",
                        k, w.WFDB_MAXUSL)
                units = X.script_fgets(ttyin, w.WFDB_MAXUSL + 2)
                ub = []
                for ch in units:
                    if ch in " \t":
                        ub.append("_")
                    elif ch == "\n":
                        break
                    else:
                        ub.append(ch)
                units = "".join(ub)
                d.units = units if units else None
            # wfdb-x: C (legacy mode) showed "mV" for unspecified units
            eprintf(" Signal %d gain (adu/%s) [%g]: ", k,
                    d.units if d.units is not None else
                    ("mV" if legacy() else "nd"), d.gain)
            answer = X.script_fgets(ttyin, ANSWERLEN)
            n, v = sscanf(answer, "%lf")
            if n == 1:
                d.gain = v[0]
            # wfdb-x: a resolution is offered only if it comes from the input
            # (or the previous output signal) and suits the output format; C
            # otherwise offered one based on the format (12 bits for 16-bit
            # formats).  Without one, the user must give it.  Legacy mode: as
            # in the C program.
            while True:
                if k > 0:
                    d.adcres = dfout[k - 1].adcres
                f = d.fmt
                if f in (80, 508):
                    maxres = 8
                elif f == 212:
                    maxres = 12
                elif f == 310:
                    maxres = 10
                elif f in (24, 524):
                    maxres = 24
                elif f == 32:
                    maxres = 32
                else:
                    maxres = 16
                if legacy():
                    if maxres == 8:
                        d.adcres = 8
                    elif not 8 <= d.adcres <= maxres:
                        d.adcres = w.WFDB_DEFRES if maxres == 16 else maxres
                    eprintf(" Signal %d ADC resolution in bits (8-32) [%d]: ",
                            k, d.adcres)
                elif 8 <= d.adcres <= maxres:
                    eprintf(" Signal %d ADC resolution in bits (8-32) [%d]: ",
                            k, d.adcres)
                else:
                    eprintf(" Signal %d ADC resolution in bits (8-32): ", k)
                    d.adcres = 0
                answer = X.script_fgets(ttyin, ANSWERLEN)
                n, v = sscanf(answer, "%d")
                if n == 1:
                    d.adcres = int32(v[0])
                if d.adcres == 0 and not legacy():
                    eprintf("%s: the ADC resolution of signal %d must be "
                            "specified\n", pname, k)
                    w.wfdbquit()
                    raise Exit(1)
                if not (d.adcres < 8 or d.adcres > 32):
                    break
            eprintf(" Signal %d ADC zero level (adu) [%d]: ", k, d.adczero)
            answer = X.script_fgets(ttyin, ANSWERLEN)
            n, v = sscanf(answer, "%d")
            if n == 1:
                d.adczero = int32(v[0])
        if ttyfp is not None:
            ttyfp.close()
    if frm:
        startp = argv[frm]
    frm = w.strtim(startp)
    if frm < 0:
        frm = -frm
    btstring = w.mstimstr(-frm)
    if to:
        to = w.strtim(argv[to])
        if to < 0:
            to = -to
        if to > 0:
            nsamp = to - frm
            if nsamp <= 0:
                eprintf("%s: 'to' time must be later than 'from' time\n",
                        pname)
                raise Exit(1)
    spm = w.strtim("1:0")
    if Mflag:
        w.setgvmode(w.WFDB_HIGHRES)
        spf = w.getspf()
        frm *= spf
        to *= spf
        w.setafreq(ofreq * spf)
    else:
        w.setafreq(0.0)
    if nann > 0:
        ai = [w.Anninfo(nm, w.WFDB_READ) for nm in ainames]
        if w.annopen(irec, ai, nann) < 0 or w.iannsettime(frm) < -1:
            raise Exit(2)
        p0 = nrec if nrec is not None else orec
        ao = [w.Anninfo(nm, w.WFDB_WRITE) for nm in ainames]
        if w.annopen("+%s" % p0, ao, nann) < 0:
            raise Exit(2)
        annot = w.Annotation()
        for k in range(nann):
            tt = 0
            cc = -129       # less than any channel number
            while w.getann(k, annot) == 0 and (to == 0 or annot.time <= to):
                if annot.time == 0 and annot.subtyp == 0 and \
                        annot.chan == 0 and annot.num == 0 and \
                        annot.anntyp in (w.NOTQRS, w.NOTE):
                    continue
                annot.time = d2l((annot.time - frm) * ofreq / ifreq)
                if uflag and (annot.time < tt or
                              (annot.time == tt and annot.chan <= cc)):
                    tt += 1
                    annot.time = tt
                else:
                    tt = annot.time
                cc = annot.chan
                w.putann(k, annot)
        for k in range(nann - 1, -1, -1):
            w.iannclose(k)
            w.oannclose(k)
    if nosig == 0:
        raise Exit(0)
    eprint("Checking input signals ...")
    if w.isigsettime(frm) < 0:
        raise Exit(2)
    eprint(" done\n")
    w.wfdbquiet()
    if orec is not None:
        dfout = []
        if w.osigopen(orec, dfout, nosig) != nosig:
            eprintf("%s: can't write output signals\n", pname)
            raise Exit(2)
    w.wfdbverbose()
    for k in range(nosig):
        if dfout[k].fmt == 0:
            eprintf("%s: signal %d format cannot be 0 (changing to format "
                    "16)\n", pname, k)
            dfout[k].fmt = 16
            reopen = 1
    # Without -M, the output frames hold one sample of each signal (as for
    # output signals specified interactively), so signals of the -o record
    # with more than one sample per frame are (re)opened with one.  (C
    # reads past the end of its output array; see "Undefined behaviors" in
    # docs/KNOWN_C_BEHAVIORS.md.)
    if Mflag == 0:
        for k in range(nosig):
            if dfout[k].spf > 1:
                dfout[k].spf = 1
                reopen = 1
    if nrec is not None and use_irec_desc:
        for k in range(nosig):
            dfout[k].desc = dfin[siglist[k]].desc
        reopen = 1
    gain = [0.0] * nosig
    deltav = [0] * nosig
    for k in range(nosig):
        j = siglist[k]
        di = dfin[j]
        do = dfout[k]
        if do.gain == 0.0:
            # wfdb-x: rescaling by ADC resolution needs both resolutions (C
            # guessed an unspecified input resolution from the format,
            # assuming WFDB_DEFRES for 16-bit formats, as legacy mode does).
            if legacy():
                if di.adcres == 0:
                    di.adcres = {80: 8, 508: 8, 212: 12, 310: 10, 24: 24,
                                 524: 24, 32: 32}.get(di.fmt, w.WFDB_DEFRES)
            elif di.adcres == 0 or do.adcres == 0:
                eprintf("%s: ADC resolution of signal %d of record %s is not "
                        "specified\n", pname, j if di.adcres == 0 else k,
                        irec if di.adcres == 0 else
                        (orec if orec is not None else nrec))
                w.wfdbquit()
                raise Exit(2)
            gain[k] = float(1 << do.adcres) / float(1 << di.adcres)
        elif di.gain == 0.0 and legacy():
            gain[k] = do.gain / w.WFDB_DEFGAIN     # wfdb-x: as in C
        elif di.gain == 0.0:
            # wfdb-x: an uncalibrated input signal cannot be rescaled to the
            # specified gain (C assumed an input gain of WFDB_DEFGAIN).
            eprintf("%s: signal %d of record %s is uncalibrated; it cannot be "
                    "rescaled to the specified gain\n", pname, j, irec)
            w.wfdbquit()
            raise Exit(2)
        else:
            gain[k] = do.gain / di.gain
        if gain[k] != 1.0:
            gflag = 1
        deltav[k] = d2i(do.adczero - gain[k] * di.adczero)
        if do.gain != di.gain * gain[k] or \
                do.baseline != di.baseline * gain[k]:
            do.gain = di.gain * gain[k]
            do.baseline = d2i(di.baseline * gain[k])
            reopen = 1
    if reopen:
        if w.osigfopen(dfout, nosig) != nosig:
            raise Exit(2)
    vmax = [int32(dfout[k].adczero + (1 << (dfout[k].adcres - 1)) - 1)
            for k in range(nosig)]
    vmin = [int32(dfout[k].adczero - (1 << (dfout[k].adcres - 1)))
            for k in range(nosig)]
    INV = w.WFDB_INVALID_SAMPLE
    vin = [0] * max(iframelen, 1)
    vout = [0] * max(oframelen, 1)
    vv = [0] * nosig
    v = [0] * nosig
    m = n = mn = 0
    if ifreq != ofreq:
        f = gcd(ifreq, ofreq)
        fflag = 1
        m = d2i(ifreq / f)
        n = d2i(ofreq / f)
        mn = m * n
        w.getvec(vin)
        for k in range(nosig):
            x = vin[siglist[k]]
            vv[k] = d2i(x * gain[k] + deltav[k]) if x != INV else INV
    msiglist = [0] * nosig
    if Mflag:
        for k in range(nosig):
            msiglist[k] = sum(dfin[jj].spf for jj in range(siglist[k]))

    def tick():     # progress: a dot per minute of input, 60 dots per line
        nonlocal nsm, nminutes
        nsm += 1
        if nsm >= spm:
            nsm = 0
            eprint(".")
            nminutes += 1
            if nminutes >= 60:
                nminutes = 0
                eprint("\n")

    def check(idx, k):
        x = vout[idx]
        if x > vmax[k]:
            eprintf("v[%d] = %d (out of range)\n", k, x)
            if clip:
                vout[idx] = vmax[k]
            else:
                vmax[k] = x
        elif x < vmin[k]:
            eprintf("v[%d] = %d (out of range)\n", k, x)
            if clip:
                vout[idx] = vmin[k]
            else:
                vmin[k] = x

    def more():
        nonlocal nsamp
        if nsamp == -1:
            return True
        r = nsamp > 0
        nsamp -= 1
        return r

    getvec = w.getframe if Mflag else w.getvec
    if fflag == 0:
        while getvec(vin) >= nisig and more():
            tick()
            if Mflag == 0:
                for k in range(nosig):
                    vt = vin[siglist[k]]
                    if vt == INV:
                        vout[k] = vt
                    else:
                        if gflag:
                            vd = vt * gain[k] + deltav[k]
                            if dflag:
                                vd += X.dither()
                            vout[k] = _round(vd)
                        else:
                            vout[k] = int32(vt + deltav[k])
                        check(k, k)
            else:
                jx = 0
                for k in range(nosig):
                    for kk in range(dfout[k].spf):
                        vt = vin[msiglist[k] + kk]
                        if vt == INV:
                            vout[jx] = vt
                        else:
                            if gflag:
                                vd = vt * gain[k] + deltav[k]
                                if dflag:
                                    vd += X.dither()
                                vout[jx] = _round(vd)
                            else:
                                vout[jx] = int32(vt + deltav[k])
                            check(jx, k)
                        jx += 1
            if w.putvec(vout) < 0:
                break
    else:
        while getvec(vin) >= nisig and more():
            tick()
            for k in range(nosig):
                vt = vin[siglist[k]]
                if vt == INV:
                    v[k] = vt
                elif gflag:
                    vd = vt * gain[k] + deltav[k]
                    if dflag:
                        vd += X.dither()
                    v[k] = _round(vd)
                else:
                    v[k] = int32(vt + deltav[k])
            while ot <= it:
                x = 1.0 if cmod(ot, n) == 0 else float(cmod(ot, n)) / n
                for k in range(nosig):
                    if v[k] == INV or vv[k] == INV:
                        vout[k] = INV
                    else:
                        # (v[k] - vv[k] is an int difference in C)
                        vd = vv[k] + x * int32(v[k] - vv[k])
                        if dflag:
                            vd += X.dither()
                        vout[k] = _round(vd)
                        check(k, k)
                if w.putvec(vout) < 0:
                    nsamp = 0
                    break
                ot += m
            for k in range(nosig):
                vv[k] = v[k]
            if it > mn:
                it -= mn
                ot -= mn
            it += n
    if nminutes > 0:
        eprint("\n")
    if nrec is not None:
        w.setsampfreq(ofreq)
        if btstring.startswith("["):
            w.setbasetime(btstring[1:-1])
        w.newheader(nrec)
        w.wfdbquiet()
        info = w.getinfo(irec)
        while info is not None:
            w.putinfo(info)
            info = w.getinfo(None)
        w.putinfo("Produced by %s from record %s, beginning at %s" %
                  (pname, irec, startp))
        for k in range(nosig):
            if siglist[k] != k:
                xinfo = "record %s, signal %d <- record %s, signal %d" % (
                    nrec, k, irec, siglist[k])
                if gain[k] != 1.0:
                    xinfo += " * %g" % gain[k]
                if deltav[k] != 0:
                    xinfo += " %s %d" % ("+" if deltav[k] > 0 else "-",
                                         abs(deltav[k]))
                w.putinfo(xinfo)
        w.wfdbverbose()
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run xform as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["xform"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["xform"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
