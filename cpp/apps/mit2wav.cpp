// mit2wav.cpp: convert WFDB format signal files to .wav format.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of convert/mit2wav.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the record must
// give it (the original assumed 250 Hz); --legacy, as the first argument,
// restores the original behavior. Each change is marked "wfdb-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/mit2wav.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2003-2010 George B. Moody; revised 2018 by Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// The output file has exactly three chunks (a header chunk, a format chunk,
// and a data chunk); see the C source for a description.  The C program
// writes the header and format chunks to a temporary file, and prepends it
// to the signal file written by putvec() using the 'mv', 'cat', and 'rm'
// commands; this port prepends them directly, with the same result.  Where
// the C program has undefined behavior (signals with more than 16 bits of
// ADC resolution, for which it shifts by a negative amount), this port
// shifts samples to the right and uses a gain multiplier of 0.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

static const char *pname;   // name of this program, for use in error messages

static const char *prog_name(const char *s);
static void help();

// The header of a .wav file written by this program: the header chunk
// ("RIFF", length, "WAVE"), the format chunk, and the beginning of the data
// chunk ("data", length).
constexpr long WAVHDRLEN = 44;

static void out16(std::string &b, short x)
{
    b += static_cast<char>(x & 0xff);
    b += static_cast<char>((x >> 8) & 0xff);
}

static void out32(std::string &b, long x)
{
    b += static_cast<char>(x & 0xff);
    b += static_cast<char>((x >> 8) & 0xff);
    b += static_cast<char>((x >> 16) & 0xff);
    b += static_cast<char>((x >> 24) & 0xff);
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    const char *nrec = nullptr, *ofname = nullptr, *record = nullptr;
    double sps;
    int bitspersample = 0, framelen, i, mag, nsig;
    long nsamp;

    // Interpret the command line.
    pname = prog_name(argv[0]);
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i]+1)) {
          case 'h':     // help requested
            help();
            std::exit(1);
            break;
          case 'n':     // new record name follows
            if (++i >= argc) {
                std::fprintf(stderr,
                             "%s: new record name must follow -n\n", pname);
                std::exit(1);
            }
            nrec = argv[i];
            break;
          case 'o':     // output file name follows
            if (++i >= argc) {
                std::fprintf(stderr,
                      "%s: name of wav-format output file must follow -o\n",
                             pname);
                std::exit(1);
            }
            ofname = argv[i];
            if (std::strlen(ofname) < 5 ||
                std::strcmp(".wav", ofname + std::strlen(ofname) - 4)) {
                std::fprintf(stderr,
                             "%s: name of output file must end in '.wav'\n",
                             pname);
                std::exit(1);
            }
            break;
          case 'r':
            if (++i >= argc) {
                std::fprintf(stderr,
                             "%s: record name must follow -r\n", pname);
                std::exit(1);
            }
            record = argv[i];
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

    // Check that required arguments are present and valid.
    if (ofname == nullptr || record == nullptr) {
        help();
        std::exit(1);
    }
    if (nrec && std::strcmp(record, nrec) == 0) {
        std::fprintf(stderr,
              "%s: names of input and output records must not be identical\n",
                     pname);
        std::exit(1);
    }

    // Open the input record and allocate memory for per-signal objects.
    if ((nsig = isigopen(record, nullptr, 0)) <= 0) std::exit(2);
    std::vector<WFDB_Siginfo> s(nsig);
    std::vector<int> offset(nsig), shift(nsig);
    std::vector<WFDB_Sample> x(nsig), y(nsig);
    if ((nsig = isigopen(record, s.data(), nsig)) <= 0)
        std::exit(3);
    // wfdb-x: no default frequency (except in legacy mode)
    if (!wfdbx_get_legacy() && sampfreq(nullptr) <= 0.) {
        std::fprintf(stderr,
                     "%s: sampling frequency of record %s is not specified\n",
                     pname, record);
        std::exit(3);
    }

    // Check that the new record name is legal before proceeding.  Note that
    // this step creates a header file, which is overwritten after the
    // processing is completed.
    if (nrec != nullptr && newheader(nrec) < 0) std::exit(3);

    // Set the output signal parameters.
    for (i = 0; i < nsig; i++) {
        if (s[i].adcres > bitspersample) bitspersample = s[i].adcres;
        offset[i] = s[i].adczero;
        s[i].adczero = 0;
        shift[i] = 16 - s[i].adcres;
        s[i].adcres = 16;
        mag = shift[i] >= 0 ? static_cast<int>(1u << shift[i]) : 0;
        s[i].gain *= mag;
        s[i].baseline -= offset[i];
        s[i].baseline = static_cast<int>(static_cast<unsigned>(s[i].baseline)
                                         * static_cast<unsigned>(mag));
        s[i].fname = std::string(ofname);
        s[i].group = 0;
        s[i].fmt = 16;
        s[i].spf = 1;
    }

    // Get information needed for the header and format chunks.
    nsamp = static_cast<long>(strtim("e"));
    sps = static_cast<double>(strtim("1"));
    framelen = nsig * 2;

    // Give up if the output cannot be written.
    if (osigfopen(s.data(), static_cast<unsigned>(nsig)) < nsig) std::exit(4);

    for (i = 0; i < nsig; i++)
        wfdbsetstart(static_cast<WFDB_Signal>(i), WAVHDRLEN);

    // Make the header and format chunks, and the first 8 bytes of the data
    // chunk (written to a temporary file in the C version).
    std::string hdr = "RIFF";
    out32(hdr, nsamp*framelen + WAVHDRLEN - 8);  // sample bytes, and the
                                      // rest of the header after this field
    hdr += "WAVEfmt ";
    out32(hdr, 16);     // number of bytes to follow in format chunk
    out16(hdr, 1);      // format tag
    out16(hdr, static_cast<short>(nsig));
    out32(hdr, static_cast<long>(sps));
    out32(hdr, static_cast<long>(sps*framelen));
    out16(hdr, static_cast<short>(framelen));
    out16(hdr, static_cast<short>(bitspersample));
    hdr += "data";
    out32(hdr, nsamp*framelen);

    // Copy the input to the output.  Reformatting is handled by putvec().
    while (getvec(x.data()) == nsig) {
        for (i = 0; i < nsig; i++)
            y[i] = shift[i] >= 0 ?
                static_cast<int>(static_cast<unsigned>(x[i] - offset[i])
                                 << shift[i]) :
                (x[i] - offset[i]) >> -shift[i];
        if (putvec(y.data()) != nsig)
            break;
    }

    // Write the new header file if requested.
    setsampfreq(sampfreq(nullptr));
    if (nrec) (void)newheader(nrec);

    // Clean up.
    wfdbquit();

    // Prepend the header and format chunks to the new signal file.
    std::string data;
    if (std::FILE *f = std::fopen(ofname, "rb")) {
        char buf[1 << 16];
        size_t n;
        while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0)
            data.append(buf, n);
        std::fclose(f);
    }
    if (std::FILE *f = std::fopen(ofname, "wb")) {
        std::fwrite(hdr.data(), 1, hdr.size(), f);
        std::fwrite(data.data(), 1, data.size(), f);
        std::fclose(f);
    }

    std::exit(0);
}

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);

    while (p >= s && *p != '/')
        p--;
    return (p+1);
}

static const char *help_strings[] = {
    "usage: %s -o FILE.wav -r RECORD [ OPTIONS ... ]\n",
    "where FILE.wav is the name of the wav-format output signal file,",
    "RECORD is the record name, and OPTIONS may include:",
    " -h         print this usage summary",
    " -n NEWREC  create a header file for the output signal file, so it",
    "             may be read as record NEWREC",
    nullptr
};

static void help()
{
    int i;

    std::fprintf(stderr, help_strings[0], pname);
    for (i = 1; help_strings[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", help_strings[i]);
}
