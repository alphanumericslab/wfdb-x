// sortann.cpp: rearrange annotations in canonical order.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of app/sortann.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the new option -F
// FREQ gives it when the record has no header or its header gives none, and is
// then required for the -f and -t times (the original assumed 250 Hz); an
// out-of-order annotation at time 0 (num 0, chan 0) is no longer lost, nor are
// those inserted after it; --legacy, as the first argument, restores the
// original behavior. Each change is marked "wfdb-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/sortann.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1997-2010 George B. Moody; revised 2017-2018 by
//   Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// This program rewrites annotation files with the annotations in time
// order.  Any simultaneous annotations are written in 'num' and 'chan'
// order.  If the input contains two or more annotations with the same time,
// num, and chan fields, only the last one is copied (and none, if that one
// has anntyp = NOTQRS) -- but only when the duplicates are found while
// repairing out-of-order input, as in the C version.
//
// The sorted (output) annotation file is always written to the current
// directory.  If the input annotations are already in the correct order, no
// output is written unless the -o option is used.

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <wfdbx/ecgcodes.hpp>
#include <wfdbx/wfdb.hpp>

// (for detail::AnnSortList, as revise.cpp uses the library's internals)
#include "../src/wfdblib.hpp"

using namespace wfdbx;

static const char *pname;

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

static const char *help_strings[] = {
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -f TIME    start at specified TIME",
    " -F FREQ    sampling frequency, if the record header does not specify one",
    " -h         print this usage summary",
    " -o OUTANN  write output as annotator OUTANN (required with -f or -t)",
    " -t TIME    stop at specified TIME",
    "The sorted output replaces the input if -o is omitted, the input is in",
    "the current directory, and the input is not already sorted.",
    nullptr
};

// wfdb-x: the help text of the original program, printed in legacy mode
static const char *legacy_help_strings[] = {
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -f TIME    start at specified TIME",
    " -h         print this usage summary",
    " -o OUTANN  write output as annotator OUTANN (required with -f or -t)",
    " -t TIME    stop at specified TIME",
    "The sorted output replaces the input if -o is omitted, the input is in",
    "the current directory, and the input is not already sorted.",
    nullptr
};

static void help()
{
    // wfdb-x: the original help text in legacy mode
    const char **hs = wfdbx_get_legacy() ? legacy_help_strings : help_strings;

    std::fprintf(stderr, hs[0], pname);
    for (int i = 1; hs[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", hs[i]);
}

// Exit after reporting an unrecognized option (wfdb-x: also the wfdb-x
// options, in legacy mode).
[[noreturn]] static void unrecognized(const char *arg)
{
    std::fprintf(stderr, "%s: unrecognized option %s\n", pname, arg);
    std::exit(1);
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    WFDB_Anninfo ai[2];
    const char *ainame[2] = {nullptr, nullptr};
    WFDB_Annotation annot;
    const char *record = nullptr;
    WFDB_Time from = 0, to = 0;
    int i;
    double Ffreq = 0., sps, tps;

    pname = prog_name(argv[0]);

    // The annotation list (insert_ann of the C version; wfdb-x: shared with
    // the library, which sorts out-of-order output annotation files in the
    // same way).  wfdb-x: an out-of-order annotation at time 0 (num 0, chan
    // 0) is no longer lost; legacy mode: the original insertion, which loses
    // it.
    detail::AnnSortList annlist(wfdbx_get_legacy() != 0);

    // Interpret command-line options.
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i] + 1)) {
            case 'a':   // (input) annotator follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: annotator must follow -a\n",
                                 pname);
                    std::exit(1);
                }
                ainame[0] = argv[i];
                break;
            case 'f':   // starting time follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: starting time must follow -f\n",
                                 pname);
                    std::exit(1);
                }
                from = i;   // to be converted to sample intervals below
                break;
            case 'F':   // sampling frequency follows (wfdb-x)
                if (wfdbx_get_legacy())   // wfdb-x: not in the original
                    unrecognized(argv[i]);
                if (++i >= argc || std::sscanf(argv[i], "%lf", &Ffreq) != 1 ||
                    Ffreq <= 0.) {
                    std::fprintf(stderr,
                                 "%s: sampling frequency (> 0) must follow -F\n",
                                 pname);
                    std::exit(1);
                }
                break;
            case 'h':   // print usage summary and quit
                help();
                std::exit(0);
                break;
            case 'o':   // output annotator follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: annotator must follow -o\n",
                                 pname);
                    std::exit(1);
                }
                ainame[1] = argv[i];
                break;
            case 'r':   // input record name follows
                // If -r is followed by a non-empty string (with no
                // intervening space), use that string as the WFDB path.
                // (The WFDB library invokes sortann with '-r.'.)
                if (argv[i][2] != 0) setwfdb(&argv[i][2]);
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: input record name must follow -r\n",
                                 pname);
                    std::exit(1);
                }
                record = argv[i];
                break;
            case 't':   // ending time follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: end time must follow -t\n",
                                 pname);
                    std::exit(1);
                }
                to = i;
                break;
            default:
                unrecognized(argv[i]);
            }
        else {
            std::fprintf(stderr, "%s: unrecognized argument %s\n", pname,
                         argv[i]);
            std::exit(1);
        }
    }

    if (record == nullptr || ainame[0] == nullptr) {
        help();
        std::exit(1);
    }
    if ((from || to) && ainame[1] == nullptr) {
        std::fprintf(stderr, "%s: -o required when using -f or -t options\n",
                     pname);
        std::exit(1);
    }
    if (ainame[1] && std::strcmp(ainame[0], ainame[1]) == 0) {
        std::fprintf(stderr,
            "%s: must specify different annotator names after -a and -o\n",
            pname);
        std::exit(1);
    }

    // By setting WFDBANNSORT, we ensure that wfdbquit won't invoke this
    // program recursively if something goes wrong.
#if defined(_WIN32)
    _putenv_s("WFDBANNSORT", "0");
#else
    setenv("WFDBANNSORT", "0", 1);
#endif

    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    // the record had no header); -F specifies one.  It is needed only to
    // convert the -f and -t times.  Legacy mode: as in the C program.
    if (wfdbx_get_legacy()) {
        if ((sps = sampfreq(record)) < 0.)
            (void)setsampfreq(sps = WFDB_DEFFREQ);
    } else if ((sps = sampfreq(record)) <= 0. && Ffreq > 0.)
        (void)setsampfreq(sps = Ffreq);
    if (!wfdbx_get_legacy() && sps <= 0. &&
        ((from && wfdbx_time_needs_freq(argv[static_cast<int>(from)])) ||
         (to && wfdbx_time_needs_freq(argv[static_cast<int>(to)])))) {
        std::fprintf(stderr,
                     "%s: sampling frequency of record %s is not specified "
                     "(use -F)\n", pname, record);
        std::exit(1);
    }

    ai[0].name = ainame[0];
    ai[0].stat = WFDB_READ;
    ai[1].stat = WFDB_WRITE;
    if (annopen(record, &ai[0], 1) < 0)     // open input annotation file
        std::exit(2);

    if (from) {
        from = strtim(argv[static_cast<int>(from)]);
        if (from < 0) from = -from;
    }
    if (to) {
        to = strtim(argv[static_cast<int>(to)]);
        if (to < 0) to = -to;
    }

    if ((tps = getiaorigfreq(0)) > 0) {
        setafreq(tps);
        setiafreq(0, tps);
        if (wfdbx_get_legacy() || sps > 0.) {
            from = static_cast<WFDB_Time>(static_cast<double>(from) * tps /
                                          sps + 0.5);
            to = static_cast<WFDB_Time>(static_cast<double>(to) * tps / sps +
                                        0.5);
        } else if (from || to) {    // wfdb-x: no default sampling frequency
            std::fprintf(stderr,
                         "%s: sampling frequency of record %s is not specified "
                         "(use -F)\n", pname, record);
            std::exit(1);
        }
    }

    // Build a linked list of annotations in memory.
    while (getann(0, &annot) == 0) {
        if (annot.time < from || (to > 0 && annot.time >= to)) continue;
        annlist.insert(annot);
    }
    iannclose(0);

    if (annlist.in_order() && ainame[1] == nullptr) {
        // If all of the annotations were in order, don't copy them unless
        // another annotator name was specified (using -o).
        std::fprintf(stderr,
                     "%s: input is already ordered -- no output written\n",
                     pname);
        std::exit(0);
    }

    if (from == 0 && to == 0 && ainame[1] == nullptr)
        // in this case, we are processing the entire input file, and it's
        // acceptable to overwrite it
        ainame[1] = ainame[0];

    ai[1].name = ainame[1];
    if (annopen(record, &ai[1], 1) < 0)     // open output annotation file
        std::exit(2);
    annlist.for_each([](const WFDB_Annotation &a) {
        if (a.anntyp != NOTQRS) putann(0, &a);
    });
    wfdbquit();

    std::exit(0);
}
