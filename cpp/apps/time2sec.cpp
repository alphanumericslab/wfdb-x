// time2sec.cpp: convert a time interval to seconds
// (C++ port of app/time2sec.c)
//
// Copyright (C) 2003-2009 George B. Moody (original C program,
// app/time2sec.c).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    double t;
    int milliseconds;
    long seconds;

    if (argc == 4 && std::strcmp(argv[1], "-r") == 0) {
        (void)isigopen(argv[2], nullptr, 0);
        t = static_cast<double>(strtim(argv[3]));
        if (t < 0) t = -t;
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
