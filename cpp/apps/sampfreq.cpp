// sampfreq.cpp: print the sampling frequency of a record
// (C++ port of app/sampfreq.c)
//
// Copyright (C) 1998-2012 George B. Moody (original C program,
// app/sampfreq.c).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).

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
