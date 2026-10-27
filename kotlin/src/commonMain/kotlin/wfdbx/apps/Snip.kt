// snip: copy an excerpt of a database record (port of app/snip.c, through
// rust/src/bin/snip.rs).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/snip.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the input record
// must give it, for the header of the excerpt (the original assumed 250 Hz);
// --legacy, as the first argument, restores the original behavior. Each change
// is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/snip.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1989-2013 George B. Moody; revised 2011-2021 by
//   Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private val SNIP_HELP = arrayOf(
    "usage: %s -i IREC -n NREC [OPTIONS ...]\n",
    "where IREC is the name of the record to be converted, NREC is the name to",
    "be given to the record to be generated, and OPTIONS may include any of:",
    " -a ANNOTATOR [ANNOTATOR ...]  copy annotations for the specified ANNOTATOR",
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
)

/** The program's global state. */
private class Snip(val pname: ByteArray) {
    var fmt = 0 // use specified output format if fmt > 0
    var mflag = 0 // try to preserve segments if non-zero
    var sflag = 0 // suppress copying info if non-zero

    /** Master header files being written (C closes them at exit). */
    val openFiles = ArrayList<WfdbFile>()

    fun help() {
        eprintf(SNIP_HELP[0], pname)
        for (k in 1 until SNIP_HELP.size) eprintf("%s\n", SNIP_HELP[k])
    }

    /** C exit: the files the program opened are flushed and closed. */
    fun exit(status: Int): Nothing {
        for (k in openFiles.indices.reversed()) openFiles[k].close()
        openFiles.clear()
        wfdbx.cstd.exit(status)
    }
}

private fun Wfdb.copyAnn(sn: Snip, nrec: ByteArray, irec: ByteArray, from: Long, to: Long, annotators: List<ByteArray>) {
    val nann = annotators.size
    val annot = Annotation()

    // Set up data structures for nann annotators.
    val ai = Array(nann) { Anninfo(annotators[it].copyOf(), WFDB_READ) }
    val ao = Array(nann) { Anninfo(annotators[it].copyOf(), WFDB_WRITE) }

    // Open the input annotators.
    if (annopen(irec, ai, nann) < 0) {
        eprintf("%s: error opening input annotators\n", sn.pname)
        sn.exit(2)
    }

    // Open the output annotators.
    if (annopen(bcat("+".latin1(), nrec), ao, nann) < 0) {
        eprintf("%s: error opening output annotators\n", sn.pname)
        sn.exit(2)
    }

    // Copy the selected segment.
    for (i in 0 until nann) {
        while (getann(i, annot) == 0) {
            if (annot.time >= from && (to == 0L || annot.time < to)) {
                annot.time -= from
                if (putann(i, annot) < 0) break
            }
        }
    }
    wfdbquit()
}

private fun Wfdb.copySig(sn: Snip, nrec: ByteArray, irec: ByteArray, from: Long, to0: Long, recurse: Int) {
    var to = to0
    var tstring: ByteArray? = null

    wfdbquit()
    val nsig = isigopen(irec, null, 0)
    if (nsig < 0) {
        eprintf("%s: error opening header for %s\n", sn.pname, irec)
        sn.exit(2)
    }

    // Allocate data structures for nsig signals.
    val v = IntArray(maxOf(nsig, 1))
    val si = Array(nsig) { Siginfo() }

    // Open the input signals.
    if (isigopen(irec, si, nsig) != nsig) {
        eprintf("%s: error opening signals for %s\n", sn.pname, irec)
        sn.exit(2)
    }

    val ps = mstimstr(-from)
    if (ps.at(0) == '['.code) {
        var ts = cstr(ps.copyOfRange(1, ps.size))
        val rb = ts.indexOf(']'.code.toByte())
        if (rb >= 0) ts = ts.copyOf(rb)
        val sp = ts.indexOf(' '.code.toByte())
        if (sp >= 0) {
            var slash = false
            for (k in sp until ts.size) if (ts[k] == '/'.code.toByte()) slash = true
            if (!slash) ts = ts.copyOf(sp)
        }
        tstring = ts
    }

    val seginfo = ArrayList<Seginfo>()
    val maxseg = if (recurse != 0) getseginfo(seginfo) else 0
    if (recurse != 0 && maxseg > 0) {
        // irec has multiple segments
        val sfreq = sampfreq(null)

        val ohfname = bcat(nrec, ".hea".latin1())
        val ohfile = WfdbFile.fopen(ohfname, "wb")
        if (ohfile == null) {
            eprintf("%s: can't create master header\n", sn.pname)
            sn.exit(2)
        }
        sn.openFiles.add(ohfile)

        if (seginfo[0].nsamp == 0L) {
            // irec has variable layout
            val olrecname = bcat(nrec, "_layout".latin1())

            for (s in si) {
                s.fname = "~".latin1()
                s.fmt = 0
                s.nsamp = 0
                s.cksum = 0
            }

            if (tstring != null) setbasetime(tstring)

            if (0 > setheader(olrecname, si, nsig)) {
                eprintf("%s: can't create layout header\n", sn.pname)
                sn.exit(2)
            }

            if (sn.sflag == 0) {
                wfdbquiet() // Suppress errors from the WFDB library.
                var info = getinfo(irec)
                while (info != null) {
                    putinfo(info)
                    info = getinfo(null as ByteArray?)
                }
                wfdbverbose()
                sn.sflag = 1
            }
        }

        // Figure out which input segments contain data to be copied
        var firstSeg = 0
        var lastSeg = maxseg - 1
        for (i in 0 until maxseg) {
            val s = seginfo[i]
            val t = s.samp0
            val tf = s.samp0 + s.nsamp
            if (t <= from && from < tf) firstSeg = i
            if (t <= to && to <= tf) {
                lastSeg = i
                break
            }
        }
        var nseg = lastSeg - firstSeg + 1
        if (seginfo[0].nsamp == 0L) nseg++

        val tfl = seginfo[lastSeg].samp0 + seginfo[lastSeg].nsamp
        if (to > tfl) to = tfl

        // Start writing the master output header.
        ohfile.printf("%s/%d %d %.12g %lld", nrec, nseg, nsig, sfreq, to - from)
        if (tstring != null) ohfile.printf(" %s", tstring)
        ohfile.printf("\r\n")

        if (seginfo[0].nsamp == 0L) ohfile.printf("%s_layout 0\r\n", nrec)

        var i = 0
        for (k in firstSeg..lastSeg) {
            val seg = seginfo[k]
            val t = seg.samp0
            var tf = seg.samp0 + seg.nsamp
            if (to < tf) tf = to // this is the last segment with data to copy
            val start: Long
            val len: Long
            if (from > t) {
                start = from - t
                len = tf - from
            } else {
                start = 0
                len = tf - t
            }
            val orsegs = if (beq(cstr(seg.recname), "~")) {
                "~".latin1()
            } else {
                i++
                val o = bcat(nrec, cformat("_%04d", i))
                copySig(sn, o, seg.recname, start, start + len, 0)
                o
            }
            ohfile.printf("%s %lld\r\n", orsegs, len)
        }
        sn.openFiles.remove(ohfile)
        ohfile.close()
        return
    }

    if (sn.fmt <= 0) {
        // no -O option, choose format based on ADC resolution
        var maxres = si[0].adcres
        var fmt = si[0].fmt
        for (k in 1 until si.size) {
            if (si[k].adcres > maxres) maxres = si[k].adcres
            if (si[k].fmt != fmt) fmt = 0
        }
        if (fmt == 0) {
            // the most compact format whose samples have at least maxres bits
            fmt = if (maxres > 24) 32
            else if (maxres > 16) 24
            else if (maxres > 12) 16
            else if (maxres > 10) 212
            else if (maxres > 8) 310
            else 80
        }
        sn.fmt = fmt
    }

    // Open the output signals.
    val ofname = bcat(nrec, ".dat".latin1())
    for (s in si) {
        s.fname = ofname.copyOf()
        s.group = 0
        s.fmt = sn.fmt
        s.spf = 1
    }
    if (osigfopen(si, nsig) != nsig) sn.exit(2)

    // Copy the selected segment.
    if (isigsettime(from) < 0) sn.exit(2)
    wfdbquiet()
    var nsamp: Long = if (to == 0L) -1 else to - from
    while (nsamp == -1L || nsamp-- > 0) {
        val stat = getvec(v)
        if (stat > 0 || nsamp == 0L) putvec(v) else break
    }

    // Clean up.
    wfdbverbose()
    setsampfreq(sampfreq(null))
    if (tstring != null) setbasetime(tstring)
    newheader(nrec)
}

private fun Wfdb.copyInfo(sn: Snip, irec: ByteArray, startp: ByteArray) {
    wfdbquiet() // Suppress error messages from the WFDB library.
    var info = getinfo(irec)
    while (info != null) {
        putinfo(info)
        info = getinfo(null as ByteArray?)
    }
    // Append additional info summarizing what snip has done.
    val xinfo = cformat("Produced by %s from record %s, beginning at %s", sn.pname, irec, startp)
    putinfo(xinfo)
    wfdbverbose()
}

/** The snip tool. */
fun Wfdb.snipMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val sn = Snip(progName(argv[0]))
    val pname = sn.pname
    var nrec: ByteArray? = null
    var irec: ByteArray? = null
    var startp: ByteArray? = null
    var endp: ByteArray? = null
    var length: ByteArray? = null
    var annFirst = 0
    var nann = 0

    var i = 1
    while (i < argc) {
        val a = argv[i]
        if (a.at(0) == '-'.code) {
            when (a.at(1).toChar()) {
                'a' -> { // annotator(s) follow
                    if (++i >= argc) {
                        eprintf("%s: annotator(s) must follow -a\n", pname)
                        exit(1)
                    }
                    // Accept the next argument unconditionally as an annotator
                    // name; accept additional arguments until we find one
                    // beginning with `-', or the end of the argument list. As
                    // in C, the count of annotators is not reset if -a is given
                    // more than once, and the names are those that follow the
                    // last -a (see "Undefined behaviors" in
                    // docs/KNOWN_C_BEHAVIORS.md).
                    annFirst = i
                    do {
                        nann++
                        i++
                    } while (i < argc && argv[i].at(0) != '-'.code)
                    if (i < argc) i--
                }
                'f' -> { // starting time
                    if (++i >= argc) {
                        eprintf("%s: time must follow -f\n", pname)
                        exit(1)
                    }
                    startp = argv[i]
                }
                'h' -> { // help requested
                    sn.help()
                    exit(0)
                }
                'i', 'r' -> { // input record name (-r is equivalent to -i)
                    if (++i >= argc) {
                        eprintf("%s: input record name must follow -i\n", pname)
                        exit(1)
                    }
                    irec = argv[i]
                }
                'l' -> { // length of snip
                    if (++i >= argc) {
                        eprintf("%s: duration must follow -l\n", pname)
                        exit(1)
                    }
                    length = argv[i]
                }
                'm' -> sn.mflag = 1 // preserve segments of multisegment input, if possible
                'n' -> { // new record name
                    if (++i >= argc) {
                        eprintf("%s: new record name must follow -n\n", pname)
                        exit(1)
                    }
                    nrec = argv[i]
                }
                'O' -> { // output format
                    if (++i >= argc) {
                        eprintf("%s: output format must follow -O\n", pname)
                        exit(1)
                    }
                    sn.fmt = strtol(argv[i], 10).value.toInt()
                }
                's' -> sn.sflag = 1 // suppress copying of info
                't' -> { // end time
                    if (++i >= argc) {
                        eprintf("%s: time must follow -t\n", pname)
                        exit(1)
                    }
                    endp = argv[i]
                }
                else -> {
                    eprintf("%s: unrecognized option %s\n", pname, a)
                    exit(1)
                }
            }
        } else {
            eprintf("%s: unrecognized argument %s\n", pname, a)
            exit(1)
        }
        i++
    }
    if (irec == null || nrec == null) {
        sn.help()
        exit(1)
    }
    val start = startp ?: "0".latin1()
    val end = endp ?: "e".latin1()

    // Verify that the output record can be written.
    if (newheader(nrec) < 0) {
        eprintf("%s: can't create output header\n", pname)
        exit(2)
    }

    // Determine the number of signals.
    val nsig = isigopen(irec, null, 0)
    if (nsig < 0) {
        eprintf("%s: error reading input header\n", pname)
        exit(2)
    }
    // wfdb-x: the output header needs the sampling frequency (the C program
    // assumed 250 Hz if the input header did not specify one, as legacy mode does).
    if (!legacy && sampfreq(null) <= 0.0) {
        eprintf("%s: sampling frequency of record %s is not specified\n", pname, irec)
        wfdbquit()
        exit(2)
    }

    // Evaluate the time limits.
    var from = strtim(start)
    if (from < 0) from = -from
    val to = if (length != null) {
        from + strtim(length)
    } else {
        val t = strtim(end)
        if (t < 0) -t else t
    }
    val endt = strtim("e")
    if ((endt > 0 && endt < from) || (to > 0 && to < from)) {
        eprintf("%s: improper interval selected\n", pname)
        wfdbquit()
        exit(1)
    }

    // Copy the annotations, if any.
    // (names beyond the last argument, which C reads past the end of argv,
    // are ignored)
    val annotators = argv.subList(minOf(annFirst, argc), minOf(annFirst + nann, argc))
    if (annotators.isNotEmpty()) copyAnn(sn, nrec, irec, from, to, annotators)

    // Copy the signals, if any.
    if (nsig > 0) copySig(sn, nrec, irec, from, to, sn.mflag)

    // Copy info strings from the input header file into the new one, unless
    // suppressed with -s.
    if (sn.sflag == 0) copyInfo(sn, irec, start)

    wfdbquit()
    exit(0)
}
