// time2sec.cpp: convert a time interval to seconds.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of app/time2sec.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: with -r, a record whose header cannot be read,
// or gives no sampling frequency, is an error (exit status 2; "time2sec:
// sampling frequency of record REC is not specified"), since WFDB-x assumes
// no sampling frequency: the original used the default of 250 Hz (WFDB-x,
// 1.2.2; see docs/DIVERGENCES.md). The --legacy option (as the first
// argument) restores the original behavior.
//
// Original C program: app/time2sec.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2003-2009 George B. Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE-GPL.

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

int main(int argc, char **argv)
{
    // WFDB-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    double t;
    int milliseconds;
    long seconds;

    if (argc == 4 && std::strcmp(argv[1], "-r") == 0) {
        // WFDB-x: in normal mode, no sampling frequency is assumed: a record
        // whose header cannot be read, or gives none, is an error (the
        // original used the default of 250 Hz; a frequency of 0 gave a
        // meaningless result with the exit status 0)
        if (isigopen(argv[2], nullptr, 0) < 0 && !wfdbx_get_legacy())
            std::exit(2);
        if (sampfreq(nullptr) <= 0. && !wfdbx_get_legacy()) {
            std::fprintf(stderr, "%s: sampling frequency of record %s is not "
                         "specified\n", argv[0], argv[2]);
            std::exit(2);
        }
        t = static_cast<double>(strtim(argv[3]));
        if (t < 0) t = -t;
        // (legacy mode, as in C: with no sampling frequency, t / sf is
        // infinite or NaN)
        seconds = static_cast<long>(t / sampfreq(nullptr));
        t -= static_cast<double>(seconds * sampfreq(nullptr));
        milliseconds = static_cast<int>(
            static_cast<long>((t * 1000.) / sampfreq(nullptr) + 0.5));
        if (milliseconds >= 1000) { seconds++; milliseconds -= 1000; }
        std::printf("%ld", seconds);
        if (milliseconds)
            std::printf(".%03d", milliseconds);
        std::printf("\n");
        std::exit(0);
    } else if (argc == 2 && argv[1][0] != '-') {
        setsampfreq(1000.0);
        std::printf("%.12g\n", static_cast<double>(strtim(argv[1])) / 1000.0);
        std::exit(0);
    }

    std::fprintf(stderr, "usage: %s [-r RECORD] TIME\n", argv[0]);
    std::fprintf(stderr, " where TIME (in hh:mm:ss format) is a time interval\n");
    std::fprintf(stderr, " to be converted into seconds.  Enclose TIME in\n");
    std::fprintf(stderr, " square brackets (e.g., [9:0:0]) to convert a time\n");
    std::fprintf(stderr, " of day to the elapsed time in seconds from the\n");
    std::fprintf(stderr, " beginning of the (optionally) specified RECORD.\n");
    std::exit(1);
}
