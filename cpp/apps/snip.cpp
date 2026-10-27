// snip.cpp: copy an excerpt of a database record.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of app/snip.c from the WFDB Software Package 10.7.0,
// by George B. Moody. The translation follows the logic and behavior of the
// original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the input record
// must give it, for the header of the excerpt (the original assumed 250 Hz);
// --legacy, as the first argument, restores the original behavior. Each change
// is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/snip.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1989-2013 George B. Moody; revised 2011-2021 by
//   Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

static const char *pname;
static int fmt = 0;     // use specified output format if fmt > 0
static int mflag = 0;   // try to preserve segments if non-zero
static int sflag = 0;   // suppress copying info if non-zero

static void copy_ann(const char *nrec, const char *irec, WFDB_Time from,
                     WFDB_Time to, char **annotators, int nann);
static void copy_sig(const char *nrec, const char *irec, WFDB_Time from,
                     WFDB_Time to, int recurse);
static void copy_info(const char *irec, const char *startp);
static const char *prog_name(const char *s);
static void help();

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    const char *nrec = nullptr, *irec = nullptr, *startp = nullptr,
               *endp = nullptr;
    char **annotators = nullptr;
    const char *length = nullptr;
    int i, nann = 0, nsig = 0;
    WFDB_Time from = 0L, to = 0L, endt = 0L;

    pname = prog_name(argv[0]);

    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i] + 1)) {
            case 'a':   // annotator(s) follow
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: annotator(s) must follow -a\n",
                                 pname);
                    std::exit(1);
                }
                // Accept the next argument unconditionally as an annotator
                // name; accept additional arguments until we find one
                // beginning with `-', or the end of the argument list.
                annotators = &argv[i];
                do {
                    ++nann;
                } while (++i < argc && *argv[i] != '-');
                if (i < argc) i--;
                break;
            case 'f':   // starting time
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: time must follow -f\n", pname);
                    std::exit(1);
                }
                startp = argv[i];
                break;
            case 'h':   // help requested
                help();
                std::exit(0);
                break;
            case 'i':   // input record name
            case 'r':   // accept as equivalent to -i
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: input record name must follow -i\n",
                                 pname);
                    std::exit(1);
                }
                irec = argv[i];
                break;
            case 'l':   // length of snip
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: duration must follow -l\n",
                                 pname);
                    std::exit(1);
                }
                length = argv[i];
                break;
            case 'm':   // preserve segments of multisegment input, if possible
                mflag = 1;
                break;
            case 'n':   // new record name
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: new record name must follow -n\n",
                                 pname);
                    std::exit(1);
                }
                nrec = argv[i];
                break;
            case 'O':   // output format
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: output format must follow -O\n",
                                 pname);
                    std::exit(1);
                }
                fmt = static_cast<int>(std::strtol(argv[i], nullptr, 10));
                break;

            case 's':   // suppress copying of info
                sflag = 1;
                break;
            case 't':   // end time
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: time must follow -t\n", pname);
                    std::exit(1);
                }
                endp = argv[i];
                break;
            default:
                std::fprintf(stderr, "%s: unrecognized option %s\n", pname,
                             argv[i]);
                std::exit(1);
            }
        else {
            std::fprintf(stderr, "%s: unrecognized argument %s\n", pname,
                         argv[i]);
            std::exit(1);
        }
    }
    if (irec == nullptr || nrec == nullptr) {
        help();
        std::exit(1);
    }
    if (startp == nullptr) startp = "0";
    if (endp == nullptr) endp = "e";

    // Verify that the output record can be written.
    if (newheader(nrec) < 0) {
        std::fprintf(stderr, "%s: can't create output header\n", pname);
        std::exit(2);
    }

    // Determine the number of signals.
    if ((nsig = isigopen(irec, nullptr, 0)) < 0) {
        std::fprintf(stderr, "%s: error reading input header\n", pname);
        std::exit(2);
    }
    // wfdb-x: the output header needs the sampling frequency (the C program
    // assumed 250 Hz if the input header did not specify one, as legacy mode
    // does).
    if (!wfdbx_get_legacy() && sampfreq(nullptr) <= 0.) {
        std::fprintf(stderr,
                     "%s: sampling frequency of record %s is not specified\n",
                     pname, irec);
        wfdbquit();
        std::exit(2);
    }

    // Evaluate the time limits.
    if ((from = strtim(startp)) < 0L)
        from = -from;
    if (length)
        to = from + strtim(length);
    else if ((to = strtim(endp)) < 0L)
        to = -to;
    endt = strtim("e");
    if ((endt > 0L && endt < from) || (to > 0L && to < from)) {
        std::fprintf(stderr, "%s: improper interval selected\n", pname);
        wfdbquit();
        std::exit(1);
    }

    // Copy the annotations, if any.
    // If -a was given more than once, nann counts the annotators of all of
    // them, and the names are those that follow the last -a (as in C).
    // Names beyond the last argument (C reads past the end of argv) are
    // ignored: see "Undefined behaviors" in docs/KNOWN_C_BEHAVIORS.md.
    if (annotators && nann > argv + argc - annotators)
        nann = static_cast<int>(argv + argc - annotators);
    if (nann > 0)
        copy_ann(nrec, irec, from, to, annotators, nann);

    // Copy the signals, if any.
    if (nsig > 0)
        copy_sig(nrec, irec, from, to, mflag);

    // Copy info strings from the input header file into the new one, unless
    // suppressed with -s.
    if (!sflag)
        copy_info(irec, startp);

    wfdbquit();
    std::exit(0);
}

static void copy_ann(const char *nrec, const char *irec, WFDB_Time from,
                     WFDB_Time to, char **annotators, int nann)
{
    int i;
    std::vector<WFDB_Anninfo> ai(nann), ao(nann);
    WFDB_Annotation annot;

    // Set up data structures for nann annotators.
    for (i = 0; i < nann; i++) {
        ai[i].name = annotators[i];
        ai[i].stat = WFDB_READ;
        ao[i].name = annotators[i];
        ao[i].stat = WFDB_WRITE;
    }

    // Open the input annotators.
    if (annopen(irec, ai.data(), nann) < 0) {
        std::fprintf(stderr, "%s: error opening input annotators\n", pname);
        std::exit(2);
    }

    // Open the output annotators.
    std::string orec = std::string("+") + nrec;
    if (annopen(orec.c_str(), ao.data(), nann) < 0) {
        std::fprintf(stderr, "%s: error opening output annotators\n", pname);
        std::exit(2);
    }

    // Copy the selected segment.
    for (i = 0; i < nann; i++) {
        while (getann(static_cast<unsigned>(i), &annot) == 0) {
            if (annot.time >= from && (to == 0L || annot.time < to)) {
                annot.time -= from;
                if (putann(static_cast<unsigned>(i), &annot) < 0) break;
            }
        }
    }
    wfdbquit();
}

static void copy_sig(const char *nrec, const char *irec, WFDB_Time from,
                     WFDB_Time to, int recurse)
{
    std::optional<std::string> tstring;
    int i, j, nsig, maxseg, maxres;
    WFDB_Time nsamp;
    std::vector<WFDB_Sample> v;
    std::vector<WFDB_Siginfo> si;
    WFDB_Time t, tf;
    const WFDB_Seginfo *seginfop = nullptr;

    wfdbquit();
    if ((nsig = isigopen(irec, nullptr, 0)) < 0) {
        std::fprintf(stderr, "%s: error opening header for %s\n", pname,
                     irec);
        std::exit(2);
    }

    // Allocate data structures for nsig signals.
    v.resize(nsig > 0 ? nsig : 1);
    si.resize(nsig);

    // Open the input signals.
    if (isigopen(irec, si.data(), nsig) != nsig) {
        std::fprintf(stderr, "%s: error opening signals for %s\n", pname,
                     irec);
        std::exit(2);
    }

    std::string ps = mstimstr(-from);
    if (ps[0] == '[') {
        std::string ts = ps.substr(1);
        size_t k;
        if ((k = ts.find(']')) != std::string::npos)
            ts.resize(k);
        if ((k = ts.find(' ')) != std::string::npos &&
            ts.find('/', k) == std::string::npos)
            ts.resize(k);
        tstring = ts;
    }

    if (recurse && (maxseg = getseginfo(&seginfop)) > 0) {
        // irec has multiple segments
        int first_seg, last_seg, nseg;
        WFDB_Frequency sfreq = sampfreq(nullptr);
        std::FILE *ohfile;
        std::vector<WFDB_Seginfo> seginfo(seginfop, seginfop + maxseg);

        std::string ohfname = std::string(nrec) + ".hea";
        ohfile = std::fopen(ohfname.c_str(), "wb");
        if (ohfile == nullptr) {
            std::fprintf(stderr, "%s: can't create master header\n", pname);
            std::exit(2);
        }

        if (seginfo[0].nsamp == 0) {  // irec has variable layout
            std::string olrecname = std::string(nrec) + "_layout";

            for (i = 0; i < nsig; i++) {
                si[i].fname = "~";
                si[i].fmt = 0;
                si[i].nsamp = 0;
                si[i].cksum = 0;
            }

            if (tstring) {
                std::string tstring_copy = *tstring;
                setbasetime(tstring_copy.c_str());
            }

            if (0 > setheader(olrecname.c_str(), si.data(), nsig)) {
                std::fprintf(stderr, "%s: can't create layout header\n",
                             pname);
                std::exit(2);
            }

            if (sflag == 0) {
                std::optional<std::string> info;

                wfdbquiet();  // Suppress errors from the WFDB library.
                if ((info = getinfo(irec)))
                    do {
                        putinfo(info->c_str());
                    } while ((info = getinfo(nullptr)));
                wfdbverbose();
                sflag = 1;
            }
        }

        // Figure out which input segments contain data to be copied
        for (i = first_seg = 0, last_seg = maxseg - 1; i < maxseg; i++) {
            t = seginfo[i].samp0;
            tf = seginfo[i].samp0 + seginfo[i].nsamp;
            if (t <= from && from < tf) first_seg = i;
            if (t <= to && to <= tf) { last_seg = i; break; }
        }
        nseg = last_seg - first_seg + 1;
        if (seginfo[0].nsamp == 0) nseg++;

        tf = seginfo[last_seg].samp0 + seginfo[last_seg].nsamp;
        if (to > tf)
            to = tf;

        // Start writing the master output header.
        std::fprintf(ohfile, "%s/%d %d %.12g %lld",
                     nrec, nseg, nsig, sfreq, to - from);
        if (tstring) std::fprintf(ohfile, " %s", tstring->c_str());
        std::fprintf(ohfile, "\r\n");

        if (seginfo[0].nsamp == 0) {
            std::fprintf(ohfile, "%s_layout 0\r\n", nrec);
            nseg--;
        }

        for (i = 0, j = first_seg; j <= last_seg; j++) {
            WFDB_Time len, start;
            char orseg[256];

            t = seginfo[j].samp0;
            tf = seginfo[j].samp0 + seginfo[j].nsamp;
            if (to < tf)    // this is the last segment with data to copy
                tf = to;
            if (from > t) {
                start = from - t; len = tf - from;
            } else {
                start = 0L; len = tf - t;
            }
            std::string orsegs;
            if (!std::strcmp(seginfo[j].recname, "~"))
                orsegs = "~";
            else {
                std::snprintf(orseg, sizeof(orseg), "_%04d", ++i);
                orsegs = std::string(nrec) + orseg;
                copy_sig(orsegs.c_str(), seginfo[j].recname, start,
                         start + len, 0);
            }
            std::fprintf(ohfile, "%s %lld\r\n", orsegs.c_str(), len);
        }
        std::fclose(ohfile);
        return;
    }

    if (fmt <= 0) { // no -O option, choose format based on ADC resolution
        maxres = si[0].adcres;
        fmt = si[0].fmt;
        for (i = 1; i < nsig; i++) {
            if (si[i].adcres > maxres)
                maxres = si[i].adcres;
            if (si[i].fmt != fmt)
                fmt = 0;
        }
        if (fmt == 0) {
            if (maxres > 24)
                fmt = 32;
            else if (maxres > 16)
                fmt = 24;
            else if (maxres > 12)
                fmt = 16;
            else if (maxres > 10)
                fmt = 212;
            else if (maxres > 8)
                fmt = 310;
            else
                fmt = 80;
        }
    }

    // Open the output signals.
    std::string ofname = std::string(nrec) + ".dat";
    for (i = 0; i < nsig; i++) {
        si[i].fname = ofname;
        si[i].group = 0;
        si[i].fmt = fmt;
        si[i].spf = 1;
    }
    if (osigfopen(si.data(), static_cast<unsigned>(nsig)) != nsig)
        std::exit(2);

    // Copy the selected segment.
    if (isigsettime(from) < 0) std::exit(2);
    wfdbquiet();
    nsamp = (to == 0L) ? -1L : to - from;
    while (nsamp == -1L || nsamp-- > 0L) {
        int stat = getvec(v.data());

        if (stat > 0 || nsamp == 0L) putvec(v.data());
        else break;
    }

    // Clean up.
    wfdbverbose();
    setsampfreq(sampfreq(nullptr));
    if (tstring) setbasetime(tstring->c_str());
    (void)newheader(nrec);
}

static void copy_info(const char *irec, const char *startp)
{
    std::optional<std::string> info;

    wfdbquiet();    // Suppress error messages from the WFDB library.
    if ((info = getinfo(irec)))
        do {
            (void)putinfo(info->c_str());
        } while ((info = getinfo(nullptr)));
    // Append additional info summarizing what snip has done.
    std::string xinfo = std::string("Produced by ") + pname +
                        " from record " + irec + ", beginning at " + startp;
    (void)putinfo(xinfo.c_str());
    wfdbverbose();
}

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

static const char *help_strings[] = {
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
    nullptr
};

static void help()
{
    std::fprintf(stderr, help_strings[0], pname);
    for (int i = 1; help_strings[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", help_strings[i]);
}
