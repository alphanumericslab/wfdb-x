// rdedfann.cpp: print annotations from an EDF+ file.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of convert/rdedfann.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: convert/rdedfann.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2008-2014 George B. Moody; bug fix and -x option contributed
//   by Luca Citi, 2014.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// This program prints the annotations from an EDF+ file in the same format
// as 'rdann' does for WFDB-compatible annotation files.  As in the C
// program, an annotation without a duration repeats the duration of the
// previous one (see docs/KNOWN_C_BEHAVIORS.md).  Where the C program would
// overflow its 1024-byte onset, duration, or text buffers, this port
// discards the excess characters.

#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

static const char *pname;
static double sfreq = 0.0;
static int state;

static void proc(int x, int xflag);
static const char *prog_name(const char *s);
static void help();

int main(int argc, char **argv)
{
    // WFDB-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    const char *record = nullptr;
    int aindex = 0, alen = 0, framelen = 0, i, nsig, vflag = 0, xflag = 0;

    pname = prog_name(argv[0]);
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i]+1)) {
          case 'F':
            if (++i >= argc) {
                std::fprintf(stderr,
                             "%s: sampling frequency must follow -F\n",
                             pname);
                std::exit(1);
            }
            std::sscanf(argv[i], "%lf", &sfreq);
            if (sfreq <= 0.0) sfreq = 1.0;
            break;
          case 'h':     // help requested
            help();
            std::exit(0);
            break;
          case 'r':     // record name
            if (++i >= argc) {
                std::fprintf(stderr, "%s: record name must follow -r\n",
                             pname);
                std::exit(1);
            }
            record = argv[i];
            break;
          case 'v':     // verbose output -- include column headings
            vflag = 1;
            break;
          case 'x':     // save EDF annotation text in aux rather than anntyp
            xflag = 1;
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
    if (record == nullptr) {
        help();
        std::exit(1);
    }
    setgvmode(WFDB_HIGHRES);
    if ((nsig = isigopen(record, nullptr, 0)) <= 0) std::exit(2);
    std::vector<WFDB_Siginfo> si(nsig);
    if ((nsig = isigopen(record, si.data(), nsig)) <= 0)
        std::exit(2);
    for (i = framelen = 0; i < nsig; i++) {
        if (si[i].desc && *si[i].desc == "EDF Annotations") {
            aindex = framelen;
            alen = si[i].spf;
        }
        framelen += si[i].spf;
    }
    if (alen == 0) {
        std::fprintf(stderr, "%s: record %s has no EDF annotations\n",
                     pname, record);
        wfdbquit();
        std::exit(3);
    }
    std::vector<WFDB_Sample> frame(framelen);

    if (sfreq > 0.0) {
        setgvmode(WFDB_LOWRES);
        setsampfreq(sfreq);
    }
    else
        sfreq = sampfreq(nullptr);

    // Print column headers if '-v' option selected.
    if (vflag)
        std::printf("      Time   Sample #  Type  Sub Chan  Num\tAux\n");

    while (getframe(frame.data()) > 0) {
        WFDB_Sample *p;

        state = 0;
        for (i = 0, p = (frame.data() + aindex); i < alen; i++, p++) {
            if (*p || state) {
                proc(*p, xflag);
                proc(*p >> 8, xflag);
            }
            else
                break;
        }
    }

    wfdbquit();
    std::exit(0);
}

// A fixed-size character buffer with a write position, as in C (characters
// that would overflow the buffer are discarded).
namespace {
struct Buf {
    char b[1024] = {};
    size_t pos = 0;
    void put(int c) { if (pos < sizeof(b)) b[pos] = static_cast<char>(c);
                      pos++; }
    std::string str() const {
        size_t n = 0;
        while (n < sizeof(b) && b[n]) n++;
        return std::string(b, n);
    }
};
}

static void proc(int x, int xflag)
{
    static Buf onset, duration, text;

    x &= 0xff;

    switch (state) {
        case 0:         // looking for a new TAL
            if (x == '\0')
                break;
            if (x != '+')
                std::fprintf(stderr, "%s: unexpected character '%c' in input\n",
                             pname, x);
            else {
                state = 1;
                onset.pos = 0;
                duration.pos = 0;
                text.pos = 0;
                text.b[0] = 0;
            }
            break;
        case 1:         // accumulate characters from onset until 024 or 025
            if (x == '\025') {          // end of onset, start of duration
                x = 0;
                state = 2;
            }
            else if (x == '\024') {     // end of onset, start of annotation
                x = 0;
                state = 3;
            }
            onset.put(x);
            break;
        case 2:         // accumulate characters from duration until 024
            if (x == '\024') {  // end of onset, start of annotation
                x = 0;
                state = 3;
            }
            duration.put(x);
            break;
        case 3:         // accumulate characters from annotation until 024
            if (x == '\024') {  // end of annotation
                x = 0;
                state = 4;
            }
            text.put(x);
            break;
        case 4:         // annot just ended, there may be another
            if (text.b[0]) {    // the annotation was not empty -- output it
                std::string os = onset.str();
                double ft = std::atof(os.c_str()) * sfreq + 0.5;
                // (Conversion to long as on x86-64: LONG_MIN if out of
                // range.)
                constexpr double TWO63 = 9223372036854775808.0;     // 2^63
                long t = (ft < TWO63 && ft >= -TWO63) ?
                    static_cast<long>(ft) : LONG_MIN;
                std::string ts = text.str();
                std::string ds = duration.str();

                // replace whitespace with '_'
                for (size_t k = 0; k < ts.size(); k++)
                    if (ts[k] == ' ' || ts[k] == '\t')
                        text.b[k] = ts[k] = '_';
                std::printf("%s  %7ld %5s%5d%5d%5d\t%s",
                            t ? mstimstr(t).c_str() : "    0:00.000", t,
                            xflag ? "\"" : ts.c_str(), 0, 0, 0,
                            xflag ? ts.c_str() : "");
                if (duration.b[0])
                    std::printf("%cduration: %s", xflag ? ' ' : '\t',
                                ds.c_str());
                std::printf("\n");
            }
            if (x) {
                text.b[0] = static_cast<char>(x);
                text.pos = 1;
                state = 3;
            }
            else        // end of TAL
                state = 0;
            break;
    }
}

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);

    while (p >= s && *p != '/')
        p--;
    return (p+1);
}

static const char *help_strings[] = {
 "usage: %s -r RECORD [OPTIONS ...]\n",
 "where RECORD is the name of the input EDF+ record, and OPTIONS may include:",
 " -F FREQ     set the sampling frequency to FREQ Hz\n",
 " -h          print this usage summary",
 " -v          print column headings",
 " -x          print EDF+ annotation text in aux (default: print in anntyp)",
nullptr
};

static void help()
{
    int i;

    std::fprintf(stderr, help_strings[0], pname);
    for (i = 1; help_strings[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", help_strings[i]);
}
