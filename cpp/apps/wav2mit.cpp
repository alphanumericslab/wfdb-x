// wav2mit.cpp: convert a .wav format file to WFDB format.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of convert/wav2mit.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in gain or units: the new options -G
// GAIN (required) and -U UNITS (required unless the gain is 0) give them (the
// original wrote 12.5 adu/mV for 8-bit and 6400 adu/mV for 16-bit files, in
// millivolts); --legacy, as the first argument, restores the original
// behavior. Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md
// gives the reasons.
//
// Original C program: convert/wav2mit.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2003-2004 George B. Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// Most .wav files are already written in a WFDB-compatible format.  This
// program simply creates a .hea (WFDB header) file that describes the .wav
// file; other WFDB applications can then read the .wav file directly.  To
// perform the reverse conversion, use 'mit2wav'.  (See the C source for a
// description of the .wav format.)
//
// Where the C program has undefined behavior (without -r, the record name
// it generates contains one uninitialized byte; a format chunk with no
// signals divides by zero), this port uses the input file name without
// '.wav' as the record name, and 0 as the number of samples (see
// docs/KNOWN_C_BEHAVIORS.md).

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <wfdbx/wfdb.hpp>

// WFDB-x: getc without locking the stream (the input is read a byte at a
// time).
#if defined(_WIN32)
#define WFDBX_APP_GETC(f) _getc_nolock(f)
#else
#define WFDBX_APP_GETC(f) getc_unlocked(f)
#endif

using namespace wfdbx;

static const char *pname;   // name of this program, for use in error messages
static int errflag = 0;     // non-zero if EOF reached in input file
static std::FILE *ifile;    // input (.wav) file pointer

static short in16();
static long in32();
static const char *prog_name(const char *s);
static void help();

// Length of the header of a .wav file with three chunks: the header chunk
// ("RIFF", length, "WAVE"), a 16-byte format chunk, and the beginning of the
// data chunk ("data", length).
constexpr long WAVHDRLEN = 44;

// Exit after reporting an unrecognized option (WFDB-x: also the WFDB-x
// options, in legacy mode).
[[noreturn]] static void unrecognized(const char *arg)
{
    std::fprintf(stderr, "%s: unrecognized option %s\n", pname, arg);
    std::exit(1);
}

int main(int argc, char **argv)
{
    // WFDB-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    char buf[80];
    const char *ifname = nullptr, *record = nullptr;
    std::string recbuf;
    const char *Uunits = nullptr;     // WFDB-x: -U
    double sps, Ggain = 0.;           // WFDB-x: -G
    int Gset = 0;
    int bitspersample, framelen, i, nsig, tag, wres;
    long flen, len, wnsamp;

    // Interpret the command line.
    pname = prog_name(argv[0]);
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i]+1)) {
          case 'G':     // gain in adu per physical unit (WFDB-x)
              if (wfdbx_get_legacy())   // WFDB-x: not in the original
                  unrecognized(argv[i]);
            if (++i >= argc || std::sscanf(argv[i], "%lf", &Ggain) != 1 ||
                Ggain < 0.) {
                std::fprintf(stderr, "%s: gain (>= 0) must follow -G\n",
                             pname);
                std::exit(1);
            }
            Gset = 1;
            break;
          case 'h':     // help requested
            help();
            std::exit(1);
            break;
          case 'i':     // input file name follows
            if (++i >= argc) {
                std::fprintf(stderr,
                      "%s: name of wav-format input file must follow -i\n",
                             pname);
                std::exit(1);
            }
            ifname = argv[i];
            if (std::strlen(ifname) < 5 ||
                std::strcmp(".wav", ifname + std::strlen(ifname) - 4)) {
                std::fprintf(stderr,
                             "%s: name of input file must end in '.wav'\n",
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
          case 'U':     // physical units (WFDB-x)
              if (wfdbx_get_legacy())   // WFDB-x: not in the original
                  unrecognized(argv[i]);
            if (++i >= argc) {
                std::fprintf(stderr, "%s: units must follow -U\n", pname);
                std::exit(1);
            }
            Uunits = argv[i];
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

    // Check that required arguments are present and valid.
    if (ifname == nullptr) {
        help();
        std::exit(1);
    }
    // WFDB-x: the gain and units must be given explicitly; the C program
    // wrote 12.5 adu/mV for 8-bit and 6400 adu/mV for 16-bit files, with no
    // units (millivolts).  (The sampling frequency and the resolution are
    // those given in the file.)  Legacy mode: as in the C program.
    if (!Gset && !wfdbx_get_legacy()) {
        std::fprintf(stderr, "%s: the gain must be specified (-G)\n", pname);
        std::exit(1);
    }
    if (Ggain != 0. && Uunits == nullptr && !wfdbx_get_legacy()) {
        std::fprintf(stderr, "%s: the units must be specified (-U)\n",
                     pname);
        std::exit(1);
    }

    // If the record name was not specified, generate it from ifname.
    if (record == nullptr) {
        recbuf.assign(ifname, std::strlen(ifname) - 4);
        record = recbuf.c_str();
    }

    // Open the input file.
    if ((ifile = std::fopen(ifname, "rb")) == nullptr) {
        std::fprintf(stderr, "%s: can't open %s\n", pname, ifname);
        std::exit(2);
    }

    // Determine the size of the input file.
    std::fseek(ifile, 0L, SEEK_END);
    flen = std::ftell(ifile);
    std::fseek(ifile, 0L, SEEK_SET);

    // Read and check the header chunk.
    if (std::fread(buf, 1, 4, ifile) != 4 ||
        std::strncmp(buf, "RIFF", 4)) {
        std::fprintf(stderr, "%s: %s is not a .wav-format file\n", pname,
                     ifname);
        std::exit(3);
    }
    len = in32() + 8;
    if (len != flen) {
        std::fprintf(stderr,
          "%s: header chunk of %s has incorrect length (%ld, should be %ld)\n",
                     pname, ifname, len, flen);
        std::exit(3);
    }
    if (std::fread(buf, 1, 4, ifile) != 4 ||
        std::strncmp(buf, "WAVE", 4)) {
        std::fprintf(stderr, "%s: %s is not a .wav-format file\n", pname,
                     ifname);
        std::exit(3);
    }

    // Read and check the format chunk.
    if (std::fread(buf, 1, 4, ifile) != 4 ||
        std::strncmp(buf, "fmt ", 4)) {
        std::fprintf(stderr, "%s: format chunk missing or corrupt in %s\n",
                     pname, ifname);
        std::exit(3);
    }
    len = in32();
    tag = in16();
    if (len != 16 || tag != 1) {
        std::fprintf(stderr, "%s: unsupported format %d in %s\n",
                     pname, tag, ifname);
        std::exit(3);
    }
    nsig = in16();
    sps = static_cast<double>(in32());
    (void)in32();               // bytes per second
    framelen = in16();
    bitspersample = in16();
    if (bitspersample <= 8) {
        wres = 8;
        if (wfdbx_get_legacy()) Ggain = 12.5;  // WFDB-x: the C program's gain
    } else if (bitspersample <= 16) {
        wres = 16;
        if (wfdbx_get_legacy()) Ggain = 6400;  // WFDB-x: the C program's gain
    } else {
        std::fprintf(stderr,
                     "%s: unsupported resolution (%d bits/sample) in %s\n",
                     pname, bitspersample, ifname);
        std::exit(3);
    }
    if (framelen != nsig * wres / 8) {
        std::fprintf(stderr,
                     "%s: format chunk of %s has incorrect frame length\n",
                     pname, ifname);
        std::exit(3);
    }

    // Read and check the beginning of the data chunk.
    if (std::fread(buf, 1, 4, ifile) != 4 ||
        std::strncmp(buf, "data", 4)) {
        std::fprintf(stderr, "%s: data chunk missing or corrupt in %s\n",
                     pname, ifname);
        std::exit(3);
    }
    len = in32();
    wnsamp = framelen ? len / framelen : 0;

    if (nsig < 0) {             // (malloc fails in the C version)
        std::fprintf(stderr, "%s: insufficient memory\n", pname);
        std::exit(2);
    }
    std::vector<WFDB_Siginfo> s(static_cast<size_t>(nsig));

    for (i = 0; i < nsig; i++) {
        s[i].fname = std::string(ifname);
        s[i].desc.reset();
        if (Uunits) s[i].units = std::string(Uunits);
        else s[i].units.reset();
        s[i].gain = Ggain;
        s[i].initval = 0;
        s[i].group = 0;
        s[i].fmt = (wres == 16) ? 16 : 80;
        s[i].spf = 1;
        s[i].bsize = 0;
        s[i].adcres = wres;
        s[i].adczero = (wres == 16) ? 0 : 128;
        s[i].baseline = s[i].adczero;
        s[i].nsamp = wnsamp;
        s[i].cksum = 0;
        wfdbsetstart(static_cast<WFDB_Signal>(i), WAVHDRLEN);
    }
    setsampfreq(sps);

    if (setheader(record, s.data(), static_cast<unsigned>(nsig)))
        std::exit(4);

    // Clean up.
    wfdbquit();

    std::exit(0);
}

static short in16()
{
    short a, b, r;

    if ((a = static_cast<short>(WFDBX_APP_GETC(ifile))) == EOF ||
        (b = static_cast<short>(WFDBX_APP_GETC(ifile))) == EOF) {
        errflag = EOF;
        return (EOF);
    }
    r = static_cast<short>((a & 0xff) | ((b << 8) & 0xff00));
    return (r);
}

static long in32()
{
    long a, b, c, d, r;

    if ((a = WFDBX_APP_GETC(ifile)) == EOF ||
        (b = WFDBX_APP_GETC(ifile)) == EOF ||
        (c = WFDBX_APP_GETC(ifile)) == EOF ||
        (d = WFDBX_APP_GETC(ifile)) == EOF) {
        errflag = EOF;
        return (EOF);
    }
    r = (a & 0xff) | ((b << 8) & 0xff00) |
        ((c << 16) & 0xff0000) | ((d << 24) & 0xff000000);
    return (r);
}

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);

    while (p >= s && *p != '/')
        p--;
    return (p+1);
}

static const char *help_strings[] = {
    "usage: %s -i FILE.wav -r RECORD [ OPTIONS ... ]\n",
    "where FILE.wav is the name of the wav-format input signal file,",
    "and OPTIONS may include:",
    " -G GAIN    gain in adu per physical unit (required; 0: uncalibrated)",
    " -h         print this usage summary",
    " -r RECORD  create RECORD.hea (default: FILE.hea)",
    " -U UNITS   physical units (required unless the gain is 0)",
    nullptr
};

// WFDB-x: the help text of the original program, printed in legacy mode
static const char *legacy_help_strings[] = {
    "usage: %s -i FILE.wav -r RECORD [ OPTIONS ... ]\n",
    "where FILE.wav is the name of the wav-format input signal file,",
    "and OPTIONS may include:",
    " -h         print this usage summary",
    " -r RECORD  create RECORD.hea (default: FILE.hea)",
    nullptr
};

static void help()
{
    // WFDB-x: the original help text in legacy mode
    const char **hs = wfdbx_get_legacy() ? legacy_help_strings : help_strings;
    int i;

    std::fprintf(stderr, hs[0], pname);
    for (i = 1; hs[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", hs[i]);
}
