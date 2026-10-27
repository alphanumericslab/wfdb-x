// ann2rr.cpp: extract a list of intervals from an annotation file.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of app/ann2rr.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the new option -F
// FREQ gives it when the record has no header or its header gives none, and is
// then required for time arguments and for intervals and times in units of
// time (the original assumed 250 Hz); --legacy, as the first argument,
// restores the original behavior. Each change is marked "wfdb-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/ann2rr.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1995-2009 George B. Moody; revised 2018-2020 by
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

#include <wfdbx/ecgmap.hpp>
#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

static const char *pname;

// Number of decimal places of times and intervals: default and maximum
constexpr int DEFDIGITS = 3, MAXDIGITS = 15;

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

// wfdb-x: returns 1 if output format c (for -i, -v, or -V) is a unit of
// time, which needs the sampling frequency.
static int time_format_needs_freq(int c)
{
    return (c == 'h' || c == 'm' || c == 's' || c == 't' || c == 'T');
}

static const char *help_strings[] = {
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -A      print all intervals between annotations (default: print only RR",
    "          intervals; overrides -c, -p)",
    " -c      print intervals between consecutive valid annotations only",
    " -f TIME start at specified TIME",
    " -F FREQ sampling frequency, if the record header does not specify one",
    " -h      print this usage summary",
    " -i FMT  print intervals using format FMT (see below for values of FMT)",
    " -p TYPE [TYPE ...]  print intervals ending with annotations of specified",
    "                      TYPEs only (use mnemonics such as N or V for TYPE)",
    " -P TYPE [TYPE ...]  print intervals beginning with specified types only",
    " -t TIME stop at specified TIME",
    " -v FMT  print times of ends of intervals using format FMT (see below)",
    " -V FMT  print times of beginnings of intervals using format FMT (see below)",
    " -w      print annotations that end intervals",
    " -W      print annotations that begin intervals",
    "By default, the output contains the RR intervals only, unless one or more",
    "of -v, -V, -w, or -W are used.  Intervals and times are printed in units of",
    "sample intervals, unless a format is specified using -i, -v, or -V.",
    "Formats can be 'h' (hours), 'm' (minutes), 's' (seconds), 't' (hh:mm:ss);",
    "when used with -v or -V, format 'T' yields dates and times if available,",
    "or the format can be omitted to obtain times in sample intervals.  Formats",
    "'h', 'm', and 's' may be followed by a number between 0 and 15, specifying",
    "the number of decimal places (default: 3).  For example, to obtain intervals",
    "in seconds with 8 decimal places, use '-i s8'.",
    nullptr
};

// wfdb-x: the help text of the original program, printed in legacy mode
static const char *legacy_help_strings[] = {
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -A      print all intervals between annotations (default: print only RR",
    "          intervals; overrides -c, -p)",
    " -c      print intervals between consecutive valid annotations only",
    " -f TIME start at specified TIME",
    " -h      print this usage summary",
    " -i FMT  print intervals using format FMT (see below for values of FMT)",
    " -p TYPE [TYPE ...]  print intervals ending with annotations of specified",
    "                      TYPEs only (use mnemonics such as N or V for TYPE)",
    " -P TYPE [TYPE ...]  print intervals beginning with specified types only",
    " -t TIME stop at specified TIME",
    " -v FMT  print times of ends of intervals using format FMT (see below)",
    " -V FMT  print times of beginnings of intervals using format FMT (see below)",
    " -w      print annotations that end intervals",
    " -W      print annotations that begin intervals",
    "By default, the output contains the RR intervals only, unless one or more",
    "of -v, -V, -w, or -W are used.  Intervals and times are printed in units of",
    "sample intervals, unless a format is specified using -i, -v, or -V.",
    "Formats can be 'h' (hours), 'm' (minutes), 's' (seconds), 't' (hh:mm:ss);",
    "when used with -v or -V, format 'T' yields dates and times if available,",
    "or the format can be omitted to obtain times in sample intervals.  Formats",
    "'h', 'm', and 's' may be followed by a number between 0 and 15, specifying",
    "the number of decimal places (default: 3).  For example, to obtain intervals",
    "in seconds with 8 decimal places, use '-i s8'.",
    nullptr
};

static void help()
{
    // wfdb-x: the original help text in legacy mode
    const char **hs = wfdbx_get_legacy() ? legacy_help_strings : help_strings;

    std::fprintf(stderr, hs[0], pname);
    for (int i = 1; hs[i] != nullptr; i++) {
        std::fprintf(stderr, "%s\n", hs[i]);
        if (i % 23 == 0) {     // pause after each screenful (23 lines)
            char b[5];
            std::fprintf(stderr, "--More--");
            (void)!std::fgets(b, 5, stdin);
            std::fprintf(stderr, "\033[A\033[2K"); // erase "--More--";
                                                    // assumes ANSI terminal
        }
    }
}

// The flag tables are indexed by annotation type (types outside the tables
// are not flagged).
static int flagged(const char *table, int a)
{
    return (0 <= a && a <= ACMAX) ? table[a] : 0;
}

// Exit after reporting an unrecognized option (wfdb-x: also the WFDB-x
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

    const char *record = nullptr, *ainame = nullptr;
    char rrfstr[16], t0fstr[16], t1fstr[16];
    double Ffreq = 0., sps, spm, sph;
    int Aflag = 0, a0, a0flag = 0, a1, a1flag = 0, cflag = 0, i, j, pflag = 0,
        previous_annot_valid = 0, rrdigits = DEFDIGITS, rrformat = 0,
        t0digits = DEFDIGITS, t0flag = 0, t0format = 0, t1digits = DEFDIGITS,
        t1flag = 0, t1format = 0;
    static char a0f[ACMAX + 1], a1f[ACMAX + 1];
    WFDB_Anninfo ai;
    WFDB_Annotation annot;
    WFDB_Time from = 0, to = 0, rr, t0, t1;

    (void)pflag;
    pname = prog_name(argv[0]);

    // Interpret command-line options.
    for (i = a0f[0] = a1f[0] = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i] + 1)) {
            case 'a':   // annotator follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: annotator must follow -a\n",
                                 pname);
                    std::exit(1);
                }
                ainame = argv[i];
                break;
            case 'A':   // print intervals between annotations of all types
                Aflag = 1;
                break;
            case 'c':   // print intervals between consecutive valid
                        // annotations only
                cflag = 1;
                break;
            case 'f':   // starting time follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: starting time must follow -f\n",
                                 pname);
                    std::exit(1);
                }
                from = i;   // to be converted to sample intervals below
                break;
            case 'F':   // sampling frequency follows (WFDB-x)
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
            case 'i':   // specify interval output format
                if (++i >= argc || *(argv[i]) == '-') {
                    std::fprintf(stderr,
                                 "%s: interval output format must follow -i\n",
                                 pname);
                    std::exit(1);
                }
                rrformat = *(argv[i]);
                std::sscanf(argv[i] + 1, "%d", &rrdigits);
                break;
            case 'p':   // annotation mnemonic(s) follow
                if (++i >= argc || !isann(j = strann(argv[i]))) {
                    std::fprintf(stderr,
                                 "%s: annotation mnemonic(s) must follow -P\n",
                                 pname);
                    std::exit(1);
                }
                a1f[j] = 1;
                // Pick up any other mnemonics (arguments beginning with `-'
                // are assumed to be options, not mnemonics).
                while (++i < argc && argv[i][0] != '-')
                    if (isann(j = strann(argv[i]))) a1f[j] = 1;
                if (i == argc || argv[i][0] == '-') i--;
                a1f[0] = 0;
                break;
            case 'P':   // annotation mnemonic(s) follow
                if (++i >= argc || !isann(j = strann(argv[i]))) {
                    std::fprintf(stderr,
                                 "%s: annotation mnemonic(s) must follow -p\n",
                                 pname);
                    std::exit(1);
                }
                a0f[j] = 1;
                while (++i < argc && argv[i][0] != '-')
                    if (isann(j = strann(argv[i]))) a0f[j] = 1;
                if (i == argc || argv[i][0] == '-') i--;
                a0f[0] = 0;
                break;
            case 'r':   // input record name follows
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
            case 'v':   // output times of ends of intervals
                t1flag = 1;
                if (++i >= argc || argv[i][0] == '-')
                    i--;
                else {
                    t1format = *(argv[i]);
                    std::sscanf(argv[i] + 1, "%d", &t1digits);
                }
                break;
            case 'V':   // output times of beginnings of intervals
                t0flag = 1;
                if (++i >= argc || argv[i][0] == '-')
                    i--;
                else {
                    t0format = *(argv[i]);
                    std::sscanf(argv[i] + 1, "%d", &t0digits);
                }
                break;
            case 'w':   // output annotation types following intervals
                a1flag = 1;
                break;
            case 'W':   // output annotation types preceeding intervals
                a0flag = 1;
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
    if (record == nullptr || ainame == nullptr) {
        help();
        std::exit(1);
    }

    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    // the record had no header); -F specifies one.  It is needed for times
    // and intervals in units of time.  Legacy mode: as in the C program.
    if (wfdbx_get_legacy()) {
        if ((sps = sampfreq(record)) < 0.)
            (void)setsampfreq(sps = WFDB_DEFFREQ);
    } else if ((sps = sampfreq(record)) <= 0. && Ffreq > 0.)
        (void)setsampfreq(sps = Ffreq);
    if (!wfdbx_get_legacy() && sps <= 0. &&
        ((from && wfdbx_time_needs_freq(argv[static_cast<int>(from)])) ||
         (to && wfdbx_time_needs_freq(argv[static_cast<int>(to)])) ||
         time_format_needs_freq(rrformat) ||
         (t0flag && time_format_needs_freq(t0format)) ||
         (t1flag && time_format_needs_freq(t1format)))) {
        std::fprintf(stderr,
                     "%s: sampling frequency of record %s is not specified "
                     "(use -F)\n", pname, record);
        std::exit(1);
    }
    spm = 60.0 * sps;
    sph = 60.0 * spm;

    ai.name = ainame;
    ai.stat = WFDB_READ;
    if (annopen(record, &ai, 1) < 0)    // open annotation file
        std::exit(2);

    if (rrdigits < 0 || rrdigits > MAXDIGITS) rrdigits = DEFDIGITS;
    std::snprintf(rrfstr, sizeof(rrfstr), "%%.%dlf", rrdigits);
    if (t0digits < 0 || t0digits > MAXDIGITS) t0digits = DEFDIGITS;
    std::snprintf(t0fstr, sizeof(t0fstr), "%%.%dlf", t0digits);
    if (t1digits < 0 || t1digits > MAXDIGITS) t1digits = DEFDIGITS;
    std::snprintf(t1fstr, sizeof(t1fstr), "%%.%dlf", t1digits);

    if (from) {
        from = strtim(argv[static_cast<int>(from)]);
        if (from < 0) from = -from;
    }
    if (to) {
        to = strtim(argv[static_cast<int>(to)]);
        if (to < 0) to = -to;
    }
    if (to > 0 && to < from) {
        WFDB_Time tt = from;

        from = to;
        to = tt;
    }
    if (from > 0 && iannsettime(from) < 0) std::exit(2);

    a0 = NOTQRS;
    t0 = from;

    while (getann(0, &annot) == 0 && (to == 0 || annot.time <= to)) {
        a1 = annot.anntyp;
        t1 = annot.time;

        // Does t1 mark a valid interval end point?
        if (Aflag || (a1f[0] && isqrs(a1)) || flagged(a1f, a1)) {
            // Does t0 mark a valid interval starting point?
            if (cflag == 0 || previous_annot_valid == 1) {
                // If requested, print time at beginning of interval.
                if (t0flag) {
                    switch (t0format) {
                    case 'h': std::printf(t0fstr, t0 / sph); break;
                    case 'm': std::printf(t0fstr, t0 / spm); break;
                    case 's': std::printf(t0fstr, t0 / sps); break;
                    case 't':
                        if (t0 == 0)
                            std::printf("    0:00.000");
                        else
                            std::printf("%s", mstimstr(t0).c_str());
                        break;
                    case 'T': std::printf("%s", mstimstr(-t0).c_str()); break;
                    default: std::printf("%lld", t0); break;
                    }
                    std::printf("\t");
                }

                // If requested, print annotation at beginning of interval.
                if (a0flag) {
                    if (a0 == NOTQRS)
                        std::printf("[0]\t");
                    else
                        std::printf("%s\t", annstr(a0).value_or("").c_str());
                }

                // Print the interval, and update t0 and a0.
                rr = t1 - t0;
                char rrstr[20];
                double frr = 0.0;
                switch (rrformat) {
                case 'h':
                    std::snprintf(rrstr, sizeof(rrstr), rrfstr, rr / sph);
                    std::printf("%s", rrstr);
                    (void)std::sscanf(rrstr, "%lf", &frr);
                    t1 = static_cast<WFDB_Time>(t0 + frr * sph + 0.5);
                    break;
                case 'm':
                    std::snprintf(rrstr, sizeof(rrstr), rrfstr, rr / spm);
                    std::printf("%s", rrstr);
                    (void)std::sscanf(rrstr, "%lf", &frr);
                    t1 = static_cast<WFDB_Time>(t0 + frr * spm + 0.5);
                    break;
                case 's':
                    std::snprintf(rrstr, sizeof(rrstr), rrfstr, rr / sps);
                    std::printf("%s", rrstr);
                    (void)std::sscanf(rrstr, "%lf", &frr);
                    t1 = static_cast<WFDB_Time>(t0 + frr * sps + 0.5);
                    break;
                case 't': std::printf("%s", mstimstr(t1).c_str()); break;
                default: std::printf("%lld", rr); break;
                }

                // If requested, print annotation at end of interval.
                if (a1flag) std::printf("\t%s", annstr(a1).value_or("").c_str());

                // If requested, print time at end of interval.
                if (t1flag) {
                    std::printf("\t");
                    switch (t1format) {
                    case 'h': std::printf(t1fstr, t1 / sph); break;
                    case 'm': std::printf(t1fstr, t1 / spm); break;
                    case 's': std::printf(t1fstr, t1 / sps); break;
                    case 't': std::printf("%s", mstimstr(t1).c_str()); break;
                    case 'T': std::printf("%s", mstimstr(-t1).c_str()); break;
                    default: std::printf("%lld", t1); break;
                    }
                }

                std::printf("\n");
            }
        }
        // Does t1 mark a valid interval starting point?
        if (Aflag || (a0f[0] && isqrs(a1)) || flagged(a0f, a1)) {
            a0 = a1;
            t0 = t1;
            previous_annot_valid = 1;
        } else if (cflag)
            previous_annot_valid = 0;
    }
    std::exit(0);
}
