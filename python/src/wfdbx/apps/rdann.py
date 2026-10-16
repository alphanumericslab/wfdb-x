"""rdann: print an annotation file in ASCII form.

Copyright (C) 1981-2010 George B. Moody (original C program, app/rdann.c, by
T. Baker and G. Moody; revised 2017-2018 by Benjamin Moody).
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
from wfdbx._cstd import atoi, int8, strtol
from ._common import (Output, Exit, eprintf, freq_not_specified,
                      freq_option, legacy, legacy_help, legacy_sampfreq,
                      run)

HELP = [
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -c CHAN             print annotations with specified CHAN only",
    " -e                  * show annotation times as elapsed times",
    " -f TIME             start at specified TIME",
    " -F FREQ             sampling frequency, if the record header does not",
    "                      specify one",
    " -h                  print this usage summary",
    " -n NUM              print annotations with specified NUM only",
    " -p TYPE [TYPE ...]  print annotations of specified TYPEs only",
    " -s SUBTYPE          print annotations with specified SUBTYPE only",
    " -t TIME             stop at specified TIME",
    " -v                  print column headings",
    " -x                  * use alternate time format (seconds, minutes, "
    "hours)",
    "* Only one of -e and -x can be used.",
]

# wfdb-x: the help text of the original program, printed in legacy mode
LEGACY_HELP = legacy_help(HELP, {
    " -F FREQ             sampling frequency, if the record header does not":
    None,
    "                      specify one": None})


def help(pname):
    hs = LEGACY_HELP if legacy() else HELP     # wfdb-x
    eprintf(hs[0], pname)
    for s in hs[1:]:
        eprintf("%s\n", s)


def _main(argv, out):
    pname = argv[0]
    argc = len(argv)
    record = None
    cflag = nflag = sflag = 0
    chanmatch = nummatch = submatch = 0
    eflag = vflag = xflag = 0
    afrom = anum = ato = bfrom = bnum = bto = 0
    frm = to = 0
    ffreq = 0.0
    flag = [0] * (w.ACMAX + 1)
    ainame = None
    if argc >= 3 and not argv[1].startswith("-"):     # old syntax
        ainame = argv[1]
        record = argv[2]
        i = 3
        if argc > 3:
            frm = 3
            i = 4
        if argc > 4:
            to = 4
            i = 5
        if argc <= 5:
            flag[0] = 1
        else:
            while i < argc and not argv[i].startswith("-"):
                j = w.strann(argv[i])
                if w.isann(j):
                    flag[j] = 1
                i += 1
    else:
        i = flag[0] = 1
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
            elif c == "c":
                i += 1
                if i >= argc:
                    eprintf("%s: chan value (between -128 and 127) must "
                            "follow -c\n", pname)
                    raise Exit(1)
                chanmatch = int8(atoi(argv[i]))
                cflag = 1
            elif c == "e":
                eflag = 1
                xflag = 0
            elif c == "f":
                i += 1
                if i >= argc:
                    eprintf("%s: starting time must follow -f\n", pname)
                    raise Exit(1)
                frm = i
            elif c == "F" and not legacy():    # sampling frequency (wfdb-x)
                i += 1
                ffreq = freq_option(argv, i, pname)
            elif c == "h":
                help(pname)
                raise Exit(0)
            elif c == "n":
                i += 1
                if i >= argc:
                    eprintf("%s: num value (between -128 and 127) must "
                            "follow -n\n", pname)
                    raise Exit(1)
                nummatch = int8(atoi(argv[i]))
                nflag = 1
            elif c == "p":
                i += 1
                j = w.strann(argv[i]) if i < argc else 0
                if i >= argc or not w.isann(j):
                    eprintf("%s: annotation mnemonic(s) must follow -p\n",
                            pname)
                    raise Exit(1)
                flag[j] = 1
                i += 1
                while i < argc and not argv[i].startswith("-"):
                    j = w.strann(argv[i])
                    if w.isann(j):
                        flag[j] = 1
                    i += 1
                if i == argc or argv[i].startswith("-"):
                    i -= 1
                flag[0] = 0
            elif c == "r":
                i += 1
                if i >= argc:
                    eprintf("%s: input record name must follow -r\n", pname)
                    raise Exit(1)
                record = argv[i]
            elif c == "s":
                i += 1
                if i >= argc:
                    eprintf("%s: subtyp value (between -128 and 127) must "
                            "follow -s\n", pname)
                    raise Exit(1)
                submatch = int8(atoi(argv[i]))
                sflag = 1
            elif c == "t":
                i += 1
                if i >= argc:
                    eprintf("%s: end time must follow -t\n", pname)
                    raise Exit(1)
                to = i
            elif c == "v":
                vflag = 1
            elif c == "x":
                xflag = 1
                eflag = 0
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
    # wfdb-x: no default sampling frequency (C assumed 250 Hz if the record
    # had no header); -F specifies one.
    # Legacy mode: as in the C program.
    if legacy():
        sps = legacy_sampfreq(record)
    else:
        sps = w.sampfreq(record)
    if sps <= 0.0 and ffreq > 0.0:
        sps = ffreq
        w.setsampfreq(sps)
    if sps <= 0.0 and not legacy():
        freq_not_specified(pname, record, use_f=True)
        raise Exit(1)
    if w.annopen(record, [w.Anninfo(ainame, w.WFDB_READ)], 1) < 0:
        raise Exit(2)
    tps = w.getiaorigfreq(0)
    if tps < sps:
        tps = sps
    # Decimal places for times in seconds, minutes and hours (-x): enough
    # to resolve one tick (at least milliseconds).
    sprec = 3
    n = 1000.0
    while n < tps:
        sprec += 1
        n *= 10
    tpm = 60.0 * tps
    mprec = 5
    n = 100000.0
    while n < tpm:
        mprec += 1
        n *= 10
    tph = 60.0 * tpm
    hprec = 7
    n = 10000000.0
    while n < tph:
        hprec += 1
        n *= 10
    annot = w.Annotation()
    if frm:
        fa = argv[frm]
        if fa.startswith("a"):
            afrom = strtol(fa, 10, 1)[0]
            if afrom < 0:
                afrom = frm = 0
            while anum < afrom and w.getann(0, annot) == 0:
                anum += 1
                if w.isqrs(annot.anntyp):
                    bnum += 1
            if anum < afrom:
                raise Exit(2)
        elif fa.startswith("b") or fa.startswith("#"):
            bfrom = strtol(fa, 10, 1)[0]
            if bfrom < 0:
                bfrom = frm = 0
            while bnum < bfrom and w.getann(0, annot) == 0:
                anum += 1
                if w.isqrs(annot.anntyp):
                    bnum += 1
            if bnum < bfrom:
                raise Exit(2)
        elif w.iannsettime(w.strtim(fa)) < 0:
            raise Exit(2)
    if to:
        ta = argv[to]
        if ta.startswith("a"):
            ato = strtol(ta, 10, 1)[0]
            if ato < 0:
                ato = 0
            bto = to = 0
        elif ta.startswith("b"):
            bto = strtol(ta, 10, 1)[0]
            if bto < 0:
                bto = 0
            ato = to = 0
        elif ta.startswith("#"):
            bto = strtol(ta, 10, 1)[0]
            if bto < 1:
                bto = 1
            bto += bnum
            ato = to = 0
        else:
            ato = bto = 0
            to = w.strtim(ta)
            if to < 0:
                to = -to
    if vflag:
        if eflag:
            out.write("Elapsed time  Sample #  ")
        elif xflag:
            out.write("  Seconds   Minutes     Hours  ")
        elif "/" in w.mstimstr(-1):
            out.write("      Time       Date     Sample #  ")
        elif w.mstimstr(-1).startswith("["):
            out.write("      Time     Sample #  ")
        else:
            out.write("      Time   Sample #  ")
        out.write("Type  Sub Chan  Num\tAux\n")
    w.setifreq(tps)
    w.setiafreq(0, tps)
    while w.getann(0, annot) == 0:
        if tps == sps:
            sample_num = annot.time
        else:
            x = annot.time * sps / tps + 0.5
            sample_num = int(x)
            if sample_num > x:
                sample_num -= 1
        if to != 0 and sample_num > to:
            break
        at = annot.anntyp
        if (flag[0] or (w.isann(at) and flag[at])) and \
                (cflag == 0 or annot.chan == chanmatch) and \
                (nflag == 0 or annot.num == nummatch) and \
                (sflag == 0 or annot.subtyp == submatch):
            if eflag:
                out.write("%s  %7d" % (w.mstimstr(annot.time), sample_num))
            elif xflag:
                out.write("%*.*f %*.*f %*.*f" % (
                    sprec + 6, sprec, annot.time / tps,
                    mprec + 4, mprec, annot.time / tpm,
                    hprec + 2, hprec, annot.time / tph))
            else:
                out.write("%s  %7d" % (w.mstimstr(-annot.time), sample_num))
            out.write("%6s%5d%5d%5d" % (w.annstr(at), annot.subtyp,
                                        annot.chan, annot.num))
            if annot.aux is not None:
                out.write("\t%s" % annot.aux_string())
            out.write("\n")
        if ato:
            anum += 1
            if anum >= ato:
                break
        if bto and w.isqrs(annot.anntyp):
            bnum += 1
            if bnum >= bto:
                break
    return 0


def main(argv=None):
    """Run rdann as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["rdann"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["rdann"] + sys.argv[1:]
    out = Output()
    return run(lambda a: _main(a, out), argv, out)


if __name__ == "__main__":
    sys.exit(main())
