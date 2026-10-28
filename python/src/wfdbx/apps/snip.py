"""snip: copy an excerpt of a database record.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of app/snip.c from the WFDB Software Package 10.7.0,
by George B. Moody. The translation follows the logic and behavior of the
original program, but it is new code, not the original C code.

Changes from the original: no built-in sampling frequency: the input record
must give it, for the header of the excerpt (the original assumed 250 Hz);
--legacy, as the first argument, restores the original behavior. Each change is
marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.

Original C program: app/snip.c, WFDB Software Package 10.7.0.
  Copyright (C) 1989-2013 George B. Moody; revised 2011-2021 by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

import wfdbx as w
from wfdbx._cstd import strtol, int32
from ._common import (Exit, OutputFile, eprintf, freq_not_specified, legacy,
                      run)

HELP = [
    "usage: %s -i IREC -n NREC [OPTIONS ...]\n",
    "where IREC is the name of the record to be converted, NREC is the name to",
    "be given to the record to be generated, and OPTIONS may include any of:",
    " -a ANNOTATOR [ANNOTATOR ...]  copy annotations for the specified "
    "ANNOTATOR",
    "              from IREC;  two or more ANNOTATORs may follow -a",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -l DURATION snip only DURATION (hh:mm:ss or sNNNN; overrides -t)",
    " -m          preserve segments of multsegment input, if possible",
    " -O FORMAT   save output in the specified FORMAT (default: use best fit",
    "              to ADC resolution)",
    " -s          suppress output of info strings in header",
    " -t TIME     stop at specified time",
    "To change the sampling frequency, zero level, or gain, to select a",
    "subset of signals, or to re-order signals, use `xform'.",
]


class _Snip:
    def __init__(self, pname):
        self.pname = pname
        self.fmt = 0
        self.mflag = 0
        self.sflag = 0

    def help(self):
        eprintf(HELP[0], self.pname)
        for s in HELP[1:]:
            eprintf("%s\n", s)

    def copy_ann(self, nrec, irec, frm, to, annotators):
        ai = [w.Anninfo(a, w.WFDB_READ) for a in annotators]
        ao = [w.Anninfo(a, w.WFDB_WRITE) for a in annotators]
        if w.annopen(irec, ai, len(ai)) < 0:
            eprintf("%s: error opening input annotators\n", self.pname)
            raise Exit(2)
        if w.annopen("+" + nrec, ao, len(ao)) < 0:
            eprintf("%s: error opening output annotators\n", self.pname)
            raise Exit(2)
        annot = w.Annotation()
        for i in range(len(annotators)):
            while w.getann(i, annot) == 0:
                if annot.time >= frm and (to == 0 or annot.time < to):
                    annot.time -= frm
                    if w.putann(i, annot) < 0:
                        break
        w.wfdbquit()

    def copy_sig(self, nrec, irec, frm, to, recurse):
        pname = self.pname
        w.wfdbquit()
        nsig = w.isigopen(irec, None, 0)
        if nsig < 0:
            eprintf("%s: error opening header for %s\n", pname, irec)
            raise Exit(2)
        si = []
        if w.isigopen(irec, si, nsig) != nsig:
            eprintf("%s: error opening signals for %s\n", pname, irec)
            raise Exit(2)
        tstring = None
        p = w.mstimstr(-frm)
        if p.startswith("["):
            tstring = p[1:]
            k = tstring.find("]")
            if k >= 0:
                tstring = tstring[:k]
            k = tstring.find(" ")
            if k >= 0 and "/" not in tstring[k:]:
                tstring = tstring[:k]
        seginfo = w.getseginfo()
        maxseg = len(seginfo)
        if recurse and maxseg > 0:
            seginfo = [w.Seginfo(s.recname, s.nsamp, s.samp0)
                       for s in seginfo]
            sfreq = w.sampfreq(None)
            try:
                ohfile = OutputFile(nrec + ".hea", pname)
            except OSError:
                eprintf("%s: can't create master header\n", pname)
                raise Exit(2)
            if seginfo[0].nsamp == 0:
                olrecname = nrec + "_layout"
                for s in si:
                    s.fname = "~"
                    s.fmt = 0
                    s.nsamp = 0
                    s.cksum = 0
                if tstring is not None:
                    w.setbasetime(tstring)
                if w.setheader(olrecname, si, nsig) < 0:
                    eprintf("%s: can't create layout header\n", pname)
                    raise Exit(2)
                if self.sflag == 0:
                    w.wfdbquiet()
                    info = w.getinfo(irec)
                    while info is not None:
                        w.putinfo(info)
                        info = w.getinfo(None)
                    w.wfdbverbose()
                    self.sflag = 1
            first_seg = 0
            last_seg = maxseg - 1
            for i in range(maxseg):
                t = seginfo[i].samp0
                tf = seginfo[i].samp0 + seginfo[i].nsamp
                if t <= frm < tf:
                    first_seg = i
                if t <= to <= tf:
                    last_seg = i
                    break
            nseg = last_seg - first_seg + 1
            if seginfo[0].nsamp == 0:
                nseg += 1
            tf = seginfo[last_seg].samp0 + seginfo[last_seg].nsamp
            if to > tf:
                to = tf
            hdr = ["%s/%d %d %s %d" % (nrec, nseg, nsig, "%.12g" % sfreq,
                                       to - frm)]
            if tstring is not None:
                hdr.append(" %s" % tstring)
            hdr.append("\r\n")
            ohfile.write("".join(hdr).encode("latin-1"))
            if seginfo[0].nsamp == 0:
                ohfile.write(("%s_layout 0\r\n" % nrec).encode("latin-1"))
                nseg -= 1
            i = 0
            for j in range(first_seg, last_seg + 1):
                t = seginfo[j].samp0
                tf = seginfo[j].samp0 + seginfo[j].nsamp
                if to < tf:
                    tf = to
                if frm > t:
                    start = frm - t
                    ln = tf - frm
                else:
                    start = 0
                    ln = tf - t
                if seginfo[j].recname == "~":
                    orseg = "~"
                else:
                    i += 1
                    orseg = "%s_%04d" % (nrec, i)
                    self.copy_sig(orseg, seginfo[j].recname, start,
                                  start + ln, 0)
                ohfile.write(("%s %d\r\n" % (orseg, ln)).encode("latin-1"))
            ohfile.close()
            return
        if self.fmt <= 0:
            maxres = si[0].adcres
            fmt = si[0].fmt
            for i in range(1, nsig):
                if si[i].adcres > maxres:
                    maxres = si[i].adcres
                if si[i].fmt != fmt:
                    fmt = 0
            if fmt == 0:        # the smallest format for maxres bits
                if maxres > 24:
                    fmt = 32
                elif maxres > 16:
                    fmt = 24
                elif maxres > 12:
                    fmt = 16
                elif maxres > 10:
                    fmt = 212
                elif maxres > 8:
                    fmt = 310
                else:
                    fmt = 80
            self.fmt = fmt
        ofname = nrec + ".dat"
        for s in si:
            s.fname = ofname
            s.group = 0
            s.fmt = self.fmt
            s.spf = 1
        if w.osigfopen(si, nsig) != nsig:
            raise Exit(2)
        if w.isigsettime(frm) < 0:
            raise Exit(2)
        w.wfdbquiet()
        nsamp = -1 if to == 0 else to - frm
        v = [0] * max(nsig, 1)
        while True:
            if nsamp != -1:
                if not nsamp > 0:
                    break
                nsamp -= 1
            stat = w.getvec(v)
            if stat > 0 or nsamp == 0:
                w.putvec(v)
            else:
                break
        w.wfdbverbose()
        w.setsampfreq(w.sampfreq(None))
        if tstring is not None:
            w.setbasetime(tstring)
        w.newheader(nrec)

    def copy_info(self, irec, startp):
        w.wfdbquiet()
        info = w.getinfo(irec)
        while info is not None:
            w.putinfo(info)
            info = w.getinfo(None)
        w.putinfo("Produced by %s from record %s, beginning at %s" %
                  (self.pname, irec, startp))
        w.wfdbverbose()


def _main(argv):
    pname = argv[0]
    argc = len(argv)
    S = _Snip(pname)
    nrec = irec = startp = endp = length = None
    annotators = []
    ann_first = nann = 0
    i = 1
    while i < argc:
        a = argv[i]
        if a.startswith("-"):
            c = a[1:2]
            if c == "a":
                i += 1
                if i >= argc:
                    eprintf("%s: annotator(s) must follow -a\n", pname)
                    raise Exit(1)
                # Accept the next argument unconditionally as an annotator
                # name; accept additional arguments until we find one
                # beginning with `-', or the end of the argument list.  As
                # in C, the count of annotators is not reset if -a is given
                # more than once, and the names are those that follow the
                # last -a (see "Undefined behaviors" in
                # docs/KNOWN_C_BEHAVIORS.md).
                ann_first = i
                while True:
                    nann += 1
                    i += 1
                    if not (i < argc and not argv[i].startswith("-")):
                        break
                if i < argc:
                    i -= 1
            elif c == "f":
                i += 1
                if i >= argc:
                    eprintf("%s: time must follow -f\n", pname)
                    raise Exit(1)
                startp = argv[i]
            elif c == "h":
                S.help()
                raise Exit(0)
            elif c in ("i", "r"):
                i += 1
                if i >= argc:
                    eprintf("%s: input record name must follow -i\n", pname)
                    raise Exit(1)
                irec = argv[i]
            elif c == "l":
                i += 1
                if i >= argc:
                    eprintf("%s: duration must follow -l\n", pname)
                    raise Exit(1)
                length = argv[i]
            elif c == "m":
                S.mflag = 1
            elif c == "n":
                i += 1
                if i >= argc:
                    eprintf("%s: new record name must follow -n\n", pname)
                    raise Exit(1)
                nrec = argv[i]
            elif c == "O":
                i += 1
                if i >= argc:
                    eprintf("%s: output format must follow -O\n", pname)
                    raise Exit(1)
                S.fmt = int32(strtol(argv[i])[0])
            elif c == "s":
                S.sflag = 1
            elif c == "t":
                i += 1
                if i >= argc:
                    eprintf("%s: time must follow -t\n", pname)
                    raise Exit(1)
                endp = argv[i]
            else:
                eprintf("%s: unrecognized option %s\n", pname, a)
                raise Exit(1)
        else:
            eprintf("%s: unrecognized argument %s\n", pname, a)
            raise Exit(1)
        i += 1
    if irec is None or nrec is None:
        S.help()
        raise Exit(1)
    if startp is None:
        startp = "0"
    if endp is None:
        endp = "e"
    if w.newheader(nrec) < 0:
        eprintf("%s: can't create output header\n", pname)
        raise Exit(2)
    nsig = w.isigopen(irec, None, 0)
    if nsig < 0:
        eprintf("%s: error reading input header\n", pname)
        raise Exit(2)
    # WFDB-x: the output header needs the sampling frequency (C assumed
    # 250 Hz if the input header did not specify one; legacy mode: no check).
    if not legacy() and w.sampfreq(None) <= 0.0:
        eprintf("%s: sampling frequency of record %s is not specified\n",
                pname, irec)
        w.wfdbquit()
        raise Exit(2)
    frm = w.strtim(startp)
    if frm < 0:
        frm = -frm
    if length is not None:
        to = frm + w.strtim(length)
    else:
        to = w.strtim(endp)
        if to < 0:
            to = -to
    endt = w.strtim("e")
    if (endt > 0 and endt < frm) or (to > 0 and to < frm):
        eprintf("%s: improper interval selected\n", pname)
        w.wfdbquit()
        raise Exit(1)
    # (names beyond the last argument, which C reads past the end of argv,
    # are ignored)
    annotators = argv[ann_first:ann_first + nann]
    if annotators:
        S.copy_ann(nrec, irec, frm, to, annotators)
    if nsig > 0:
        S.copy_sig(nrec, irec, frm, to, S.mflag)
    if not S.sflag:
        S.copy_info(irec, startp)
    w.wfdbquit()
    return 0


def main(argv=None):
    """Run snip as a command and return its exit status.

    ``argv`` is the complete argument list, program name first, as in C
    (default: ``["snip"] + sys.argv[1:]``).  Output and error messages
    are those of the C program.
    """
    if argv is None:
        argv = ["snip"] + sys.argv[1:]
    return run(_main, argv)


if __name__ == "__main__":
    sys.exit(main())
