// wfdbdesc.cpp: describe signal specifications.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of app/wfdbdesc.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency, gain, ADC
// resolution or units: an unspecified sampling frequency or ADC resolution is
// shown as "not specified" (lengths are then given in sample intervals only),
// a gain of 0 as "uncalibrated" (the original: "uncalibrated; assume 200"),
// and unspecified units as "adu/nd" (the original assumed 250 Hz, 12 bits and
// millivolts); --legacy, as the first argument, restores the original
// behavior. Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md
// gives the reasons.
//
// Original C program: app/wfdbdesc.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1989-2012 George B. Moody; revised 2018-2020 by
//   Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// This program is an expanded version of Example 5 in the WFDB Programmer's
// Guide.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include <sys/stat.h>
#ifndef S_ISREG
#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)
#endif

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

// The C library's isigopen() removes a trailing ".hea" from its argument
// in place (wfdb_striphea), which changes the record name printed below.
static void striphea(char *p)
{
    size_t len = std::strlen(p);
    if (len > 4 && std::strcmp(p + len - 4, ".hea") == 0) p[len - 4] = '\0';
}

static const char *str(const std::optional<std::string> &s)
{
    return s ? s->c_str() : "(null)";
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    const char *pname;
    int i, msrec = 0, nsig;
    std::FILE *ifile;
    std::vector<WFDB_Siginfo> s;
    WFDB_Time t;

    pname = prog_name(argv[0]);
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s RECORD [-readable]\n", pname);
        std::exit(1);
    }
    // Discover the number of signals defined in the header.
    nsig = isigopen(argv[1], nullptr, 0);
    striphea(argv[1]);
    if (nsig < 0) std::exit(2);

    // Allocate storage for nsig signal information structures.
    if (nsig > 0) s.resize(nsig);

    // If the `-readable' option is given, report only on signals which can
    // be opened.  Otherwise, report on all signals named in the header file,
    // without attempting to open them.
    if (nsig > 0 && argc > 2 &&
        std::strncmp(argv[2], "-readable", std::strlen(argv[2])) == 0)
        nsig = isigopen(argv[1], s.data(), nsig);
    else if (nsig > 0)
        nsig = isigopen(argv[1], s.data(), -nsig);
    std::printf("Record %s", argv[1]);
    setgvmode(WFDB_LOWRES);
    t = strtim("e");
    if (nsig > 0 && (s[0].fmt == 0 || s[0].nsamp != 0) && s[0].nsamp != t) {
        msrec = 1;
        std::printf(" (a %s-layout multi-segment record)\n",
                    s[0].nsamp == 0L ? "variable" : "fixed");
        if (s[0].nsamp != 0L) {
            std::printf("----------------------------------------------\n");
            std::printf("The following data apply to the entire record:\n");
            std::printf("----------------------------------------------");
        }
    }
    std::optional<std::string> info;
    if ((info = getinfo(argv[1]))) {
        std::printf("\nNotes\n=====\n");
        do {
            std::puts(info->c_str());
        } while ((info = getinfo(nullptr)));
        std::printf("=====\n");
    }
    // wfdb-x: if the sampling frequency is not specified, times are not
    // shown (the C program assumed 250 Hz).  In legacy mode, the output is
    // that of the C program.
    WFDB_Frequency freq = sampfreq(nullptr);
    const bool timed = freq > 0. || wfdbx_get_legacy();
    std::string p = timed ? mstimstr(0L) : "";
    std::printf("\nStarting time: %s\n",
                !p.empty() && p[0] == '[' ? p.c_str() : "not specified");
    std::printf("Length: ");
    struct stat st;
    if (!timed && (nsig < 1 || t > 0L))
        std::printf("%lld sample intervals\n", t);
    else if (nsig < 1 || t > 0L)
        std::printf("%s (%lld sample intervals)\n",
                    t > 0L ? mstimstr(t).c_str() : "0", t);
    else if (s[0].fmt && s[0].fname &&
             stat(s[0].fname->c_str(), &st) == 0 && S_ISREG(st.st_mode) &&
             (ifile = std::fopen(s[0].fname->c_str(), "rb")) != nullptr &&
             (std::fseek(ifile, 0L, SEEK_END) == 0)) {
        int framesize = 0;
        long nbytes = std::ftell(ifile) - wfdbgetstart(0);

        std::fclose(ifile);
        for (i = 0; i < nsig && s[i].group == 0; i++) framesize += s[i].spf;
        switch (s[0].fmt) {
        case 8:
        case 80:
            t = nbytes / framesize;
            break;
        case 16:
        case 61:
        case 160:
            t = nbytes / (2 * framesize);
            break;
        case 24:
            t = nbytes / (3 * framesize);
            break;
        case 32:
            t = nbytes / (4 * framesize);
            break;
        case 212:
            t = (2L * nbytes) / (3 * framesize);
            break;
        case 310:
        case 311:
            t = (3L * nbytes) / (4 * framesize);
            break;
        default:
            t = -1;
            break;
        }
        if (t >= 0 && !timed)
            std::printf("%lld sample intervals [from signal file size]\n", t);
        else if (t >= 0)
            std::printf("%s (%lld sample intervals) [from signal file size]\n",
                        mstimstr(t).c_str(), t);
        else
            std::printf("not specified\n");
    } else
        std::printf("not specified\n");
    if (timed)
        std::printf("Sampling frequency: %.12g Hz\n", freq);
    else
        std::printf("Sampling frequency: not specified\n");
    std::printf("%d signal%s\n", nsig, nsig == 1 ? "" : "s");
    if (nsig < 1) std::exit(2);
    if (msrec && s[0].nsamp != 0L) {
        std::printf("----------------------------------------------\n");
        std::printf("The following data apply to the first segment:\n");
        std::printf("----------------------------------------------\n");
        if (timed)
            std::printf("Segment length: %s (%ld sample intervals)\n",
                        mstimstr(s[0].nsamp).c_str(), s[0].nsamp);
        else
            std::printf("Segment length: %ld sample intervals\n",
                        s[0].nsamp);
    }
    for (i = 0; i < nsig; i++) {
        std::printf("Group %d, Signal %d:\n", s[i].group, i);
        std::printf(" File: %s\n", s[i].fmt ? str(s[i].fname) : "[none]");
        std::printf(" Description: %s\n", str(s[i].desc));
        std::printf(" Gain: ");
        if (wfdbx_get_legacy()) {   // wfdb-x: as in the C program
            if (s[i].gain == 0.)
                std::printf("uncalibrated; assume %g", WFDB_DEFGAIN);
            else
                std::printf("%.12g", s[i].gain);
            std::printf(" adu/%s\n", s[i].units ? s[i].units->c_str() : "mV");
        } else if (s[i].gain == 0.)    // wfdb-x: no default gain
            std::printf("uncalibrated\n");
        else
            // wfdb-x: unspecified units are shown as "nd" (C assumed mV)
            std::printf("%.12g adu/%s\n", s[i].gain,
                        s[i].units ? s[i].units->c_str() : "nd");
        std::printf(" Initial value: %d\n", s[i].initval);
        if (s[i].fmt != 0) std::printf(" Storage format: %d", s[i].fmt);
        if (s[i].spf > 1) std::printf(" (%d samples per frame)", s[i].spf);
        if (s[i].fmt != 0 || s[i].spf > 1) std::printf("\n");
        std::printf(" I/O: ");
        if (s[i].bsize == 0)
            std::printf("can be unbuffered\n");
        else
            std::printf("%d-byte blocks\n", s[i].bsize);
        if (s[i].adcres > 0 || wfdbx_get_legacy())
            std::printf(" ADC resolution: %d bits\n", s[i].adcres);
        else    // wfdb-x: no default resolution
            std::printf(" ADC resolution: not specified\n");
        std::printf(" ADC zero: %d\n", s[i].adczero);
        std::printf(" Baseline: %d\n", s[i].baseline);
        if (s[i].nsamp > 0L) std::printf(" Checksum: %d\n", s[i].cksum);
    }
    std::exit(0);
}
