// wfdbtime.cpp: convert between times and sample numbers
// (C++ port of app/wfdbtime.c)
//
// Copyright (C) 2001 George B. Moody (original C program, app/wfdbtime.c;
// revised 2017-2018 by Benjamin Moody).
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
