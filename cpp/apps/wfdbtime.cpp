// wfdbtime.cpp: convert between times and sample numbers.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of app/wfdbtime.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the record must
// give it (the original assumed 250 Hz); --legacy, as the first argument,
// restores the original behavior. Each change is marked "wfdb-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/wfdbtime.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2001 George B. Moody; revised 2017-2018 by Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    const char *record = nullptr;
    char sbuf[32];
    int i;
    WFDB_Time t;

    for (i = 1; i < argc; i++) {
        if (std::strcmp(argv[i], "-r") == 0) {
            if (record) wfdbquit();
            if (++i == argc) break;
            record = argv[i];
            if (isigopen(record, nullptr, 0) < 0) std::exit(2);
            // wfdb-x: no default frequency (except in legacy mode)
            if (!wfdbx_get_legacy() && sampfreq(nullptr) <= 0.) {
                std::fprintf(stderr,
                             "%s: sampling frequency of record %s is not "
                             "specified\n", argv[0], record);
                std::exit(2);
            }
        } else if (record) {
            if ((t = strtim(argv[i])) < 0L) t = -t;
            std::snprintf(sbuf, sizeof(sbuf), "s%lld", t);
            std::printf("%15s\t%15s", sbuf,
                        (t == 0L) ? "0:00.000" : mstimstr(t).c_str());
            std::printf("\t%15s\n", mstimstr(-t).c_str());
        }
    }
    if (record == nullptr) {
        std::fprintf(stderr, "usage: %s [ -r RECORD [ TIME ] ]\n", argv[0]);
        std::fprintf(stderr, " where RECORD is the name of the input record\n");
        std::fprintf(stderr, " Each TIME is a time to be converted\n");
        std::exit(1);
    }
    wfdbquit();
    std::exit(0);
}
