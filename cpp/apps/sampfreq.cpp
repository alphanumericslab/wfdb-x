// sampfreq.cpp: print the sampling frequency of a record.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of app/sampfreq.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior). Through
// the library, a record whose header gives no sampling frequency has the
// frequency 0, which is printed (the original printed 250); see
// docs/DIVERGENCES.md.
//
// Original C program: app/sampfreq.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1998-2012 George B. Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

static const char *pname;

static void help()
{
    std::fprintf(stderr, "usage: %s [OPTION] RECORD\n", pname);
    std::fprintf(stderr,
        " where RECORD is the name of the input record\n"
        " and OPTION may be either of:\n"
        "  -a   list all signals and their sampling frequencies\n"
        "  -h   show this help\n"
        "  -H   show the maximum sampling frequency of a multifrequency record)\n"
        " If no OPTION is used, show the base sampling frequency (frame rate).\n");
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    pname = argv[0];
    switch (argc) {
    case 1:
        help();
        std::exit(1);
        break;
    case 2:
        std::printf("%g\n", sampfreq(argv[1]));
        std::exit(0);
        break;
    case 3:
        if (std::strcmp(argv[1], "-a") == 0 ||
            std::strcmp(argv[1], "-H") == 0) {
            int i, nsig;
            double freq;
            std::vector<WFDB_Siginfo> si;

            if ((nsig = isigopen(argv[2], nullptr, 0)) > 0) {
                si.resize(nsig);
                isigopen(argv[2], si.data(), nsig);
            }
            if (argv[1][1] == 'H') {
                setgvmode(WFDB_HIGHRES);
                std::printf("%g\n", sampfreq(nullptr));
                std::exit(0);
            } else {
                setgvmode(WFDB_LOWRES);
                freq = sampfreq(nullptr);
                for (i = 0; i < nsig; i++)
                    std::printf("%s\t%g\n",
                                si[i].desc ? si[i].desc->c_str() : "(null)",
                                si[i].spf * freq);
            }
        }
    }
    // (The C program falls off the end of main; its exit status is 0.)
    return 0;
}
