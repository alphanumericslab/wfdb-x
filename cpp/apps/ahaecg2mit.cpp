// ahaecg2mit.cpp: convert *.ecg or *.txt files from an AHA Database DVD to
// WFDB-compatible format.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of convert/ahaecg2mit.c from the WFDB Software
// Package 10.7.0, by George B. Moody. The translation follows the logic and
// behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: no built-in signal parameters: the new options -F
// FREQ, -G GAIN, -R BITS and -U UNITS give the sampling frequency, gain, ADC
// resolution and units, and are required (-U unless the gain is 0; the
// original assumed those of the AHA database: 250 Hz, 400 adu/mV, 12 bits and
// millivolts); the options precede the input files, in any order; the
// short-format part of a long-format file (skipped by -s) is located from -F;
// --legacy, as the first argument, restores the original behavior. Each change
// is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/ahaecg2mit.c, WFDB Software Package 10.7.0.
//   By George B. Moody (2008); revised 2017 by Benjamin Moody. The C source
//   has no copyright or license notice.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// Behaviors of the C program that are undefined are resolved as in the other
// wfdb-x implementations (see docs/KNOWN_C_BEHAVIORS.md): the 16-byte line
// buffer of readtxtdata() keeps the bytes of earlier lines of the same input
// file and is not NUL-terminated (bytes beyond it are treated as NUL), and
// the record name is made of the (up to 4) characters that precede the
// extension.  The line buffer, the samples and the annotation are reset for
// each input file.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <wfdbx/ecgmap.hpp>
#include <wfdbx/wfdb.hpp>

// wfdb-x: getc without locking the stream (the input is read a byte at a
// time).
#if defined(_WIN32)
#define WFDBX_APP_GETC(f) _getc_nolock(f)
#else
#define WFDBX_APP_GETC(f) getc_unlocked(f)
#endif

using namespace wfdbx;

// wfdb-x: the signal parameters (-F, -G, -R, -U); the C program assumed those
// of the AHA database (250 Hz, 400 adu/mV, 12 bits, millivolts).
static const char *pname, *Uunits;
static double Ffreq, Ggain;
static int Gset, Rres;
// A frame of a binary (*.ecg) input file: two 16-bit samples and an
// annotation byte
constexpr long BINFRAMELEN = 5;
// Length of the part of a long-format record omitted from a short-format
// (35-minute) record (-s), in minutes
constexpr long SKIPMIN = 145;

static int format;
static std::FILE *ifile;
static WFDB_Annotation a;
static WFDB_Sample v[2];
static unsigned char txtbuf[16]; // readtxtdata()'s line buffer

static int readbindata()
{
    unsigned char data[BINFRAMELEN];

    if (std::fread(data, 1, sizeof(data), ifile) != sizeof(data))
        return 0; // EOF
    v[0] = (data[0] & 0xff) | ((data[1] << 8) & 0xff00);
    v[1] = (data[2] & 0xff) | ((data[3] << 8) & 0xff00);
    if (data[4] == '.')
        return 1; // samples, no annotation
    a.anntyp = (char)ammap((signed char)data[4]);
    a.subtyp = (data[4] == 'U' ? -1 : 0);
    return 2; // samples and annotation
}

static int readtxtdata()
{
    unsigned char *buf = txtbuf;
    signed char c = 0; // char is signed in the reference C implementation
    char str[sizeof(txtbuf) + 1];
    long long v0, v1;
    int n;

    for (size_t i = 0; i < sizeof(txtbuf); i++) {
        c = (signed char)WFDBX_APP_GETC(ifile);
        if (c == '\r' || c == EOF || c == '\n') break;
        buf[i] = (unsigned char)c;
    }
    if (c == EOF) return 0;
    std::memcpy(str, buf, sizeof(txtbuf));
    str[sizeof(txtbuf)] = '\0';
    char cc = (char)c;
    n = std::sscanf(str, "%lld,%lld,\"%c", &v0, &v1, &cc);
    if (n >= 1) v[0] = (WFDB_Sample)(unsigned)(unsigned long long)v0;
    if (n >= 2) v[1] = (WFDB_Sample)(unsigned)(unsigned long long)v1;
    if (n >= 3) c = (signed char)cc;
    if (n < 3) {
        std::fprintf(stderr, "Error: improperly formatted input!\n");
        std::fprintf(stderr,
                     " n = %d, buf = |%s|, v[0] = %d, v[1] = %d, c = |%c|\n",
                     n, str, v[0], v[1], c);
        return 0;
    }
    if (c == '"')
        return 1; // samples, no annotation
    a.anntyp = (char)ammap(c);
    a.subtyp = (c == 'U' ? -1 : 0);
    return 2; // samples and annotation
}

static void process(const char *record)
{
    std::string ofname;
    int stat;
    WFDB_Time t = -1;
    static WFDB_Siginfo si[2];
    static WFDB_Anninfo ai;

    setsampfreq(Ffreq); // wfdb-x: -F (the C program set 250 Hz)
    ofname = std::string(record) + ".dat";
    si[0].fname = ofname;
    si[0].desc = "ECG0";
    if (Uunits) si[0].units = std::string(Uunits);
    else si[0].units.reset();
    si[0].gain = Ggain;
    si[0].fmt = 212;
    si[0].adcres = Rres;
    si[1] = si[0];
    si[1].desc = "ECG1";
    ai.name = "atr";
    ai.stat = WFDB_WRITE;
    if (osigfopen(si, 2) != 2 || annopen(record, &ai, 1) < 0) {
        wfdbquit();
        return;
    }
    if (format == 1) {
        while ((stat = readbindata())) {
            (void)putvec(v);
            if (stat > 1) {
                a.time = t;
                (void)putann(0, &a);
            }
            t++;
        }
    } else {
        while ((stat = readtxtdata())) {
            t++;
            (void)putvec(v);
            if (stat > 1) {
                a.time = t;
                (void)putann(0, &a);
            }
        }
    }
    (void)newheader(record);
    wfdbquit();
    std::fprintf(stderr, "wrote %s.atr, %s.dat, and %s.hea\n", record, record,
                 record);
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    char *p;
    std::string record;
    int i, sflag = 0;

    if (argc < 2 || std::strcmp(argv[1], "-h") == 0) {
        if (wfdbx_get_legacy())     // wfdb-x: the usage of the C program
            std::fprintf(stderr,
                         "usage: %s [-s] RECORD.XXX [RECORD.XXX]...\n",
                         argv[0]);
        else
            std::fprintf(stderr,
                         "usage: %s [-s] -F FREQ -G GAIN -R BITS -U UNITS"
                         " RECORD.XXX [RECORD.XXX]...\n", argv[0]);
        std::fprintf(stderr,
                " where RECORD.XXX is the name of the AHA DVD input file to"
                " be converted\n"
                " ('RECORD' is one of the 4-digit AHA DB record names, and"
                " 'XXX' may be either\n 'ecg' or 'txt', depending on the"
                " version of the AHA DVD.)\n"
                " Output files are RECORD.hea (text), RECORD.atr (binary),"
                " RECORD.dat (binary).\n"
                " Two or more input files may be converted in a single run.\n"
                " Use -s to make short-format (35-minute) records from"
                " long-format (2.5 hour)\n input files.  When using -s, the"
                " second digit in the output record name is\n"
                " incremented by 2.\n");
        if (!wfdbx_get_legacy())
            std::fprintf(stderr,
                " -F, -G, -R and -U give the sampling frequency (Hz), gain"
                " (adu per physical\n unit), ADC resolution (bits) and units"
                " of the signals; for the AHA DVD\n files, use -F 250 -G 400"
                " -R 12 -U mV.\n");
        std::exit(1);
    }
    // wfdb-x: options (-s and the signal parameters) precede the input
    // files, in any order.
    pname = argv[0];
    if (wfdbx_get_legacy()) {
        // wfdb-x: in legacy mode, the option of the C program (-s only, as
        // the first argument), and the parameters of the AHA database that
        // it set (250 Hz, 400 adu/mV, 12 bits, millivolts).
        if (std::strcmp(argv[i = 1], "-s") == 0) {
            sflag = 1; // produce short-format (35-minute) records
            i = 2;
        }
        Ffreq = 250.;
        Ggain = 400.;
        Gset = 1;
        Rres = 12;
        Uunits = "mV";
    } else for (i = 1; i < argc && argv[i][0] == '-' && argv[i][1] &&
             std::strchr("sFGRU", argv[i][1]) && argv[i][2] == '\0'; i++)
        switch (argv[i][1]) {
        case 's':
            sflag = 1; // produce short-format (35-minute) records
            break;
        case 'F': // sampling frequency (wfdb-x)
            if (++i >= argc || std::sscanf(argv[i], "%lf", &Ffreq) != 1 ||
                Ffreq <= 0.) {
                std::fprintf(stderr,
                             "%s: sampling frequency (> 0) must follow -F\n",
                             pname);
                std::exit(1);
            }
            break;
        case 'G': // gain in adu per physical unit (wfdb-x)
            if (++i >= argc || std::sscanf(argv[i], "%lf", &Ggain) != 1 ||
                Ggain < 0.) {
                std::fprintf(stderr, "%s: gain (>= 0) must follow -G\n",
                             pname);
                std::exit(1);
            }
            Gset = 1;
            break;
        case 'R': // ADC resolution in bits (wfdb-x)
            if (++i >= argc || std::sscanf(argv[i], "%d", &Rres) != 1 ||
                Rres < 1 || Rres > 32) {
                std::fprintf(stderr,
                             "%s: ADC resolution (1-32 bits) must follow -R\n",
                             pname);
                std::exit(1);
            }
            break;
        case 'U': // physical units (wfdb-x)
            if (++i >= argc) {
                std::fprintf(stderr, "%s: units must follow -U\n", pname);
                std::exit(1);
            }
            Uunits = argv[i];
            break;
        }
    // wfdb-x: the signal parameters must be given explicitly (see
    // docs/DIVERGENCES.md); in legacy mode, these checks pass.
    if (Ffreq <= 0.) {
        std::fprintf(stderr,
                     "%s: the sampling frequency must be specified (-F)\n",
                     pname);
        std::exit(1);
    }
    if (!Gset) {
        std::fprintf(stderr, "%s: the gain must be specified (-G)\n", pname);
        std::exit(1);
    }
    if (Rres < 1) {
        std::fprintf(stderr,
                     "%s: the ADC resolution must be specified (-R)\n",
                     pname);
        std::exit(1);
    }
    if (Ggain != 0. && Uunits == nullptr) {
        std::fprintf(stderr, "%s: the units must be specified (-U)\n",
                     pname);
        std::exit(1);
    }
    for (; i < argc; i++) {
        size_t len = std::strlen(argv[i]);
        // pointer to '.ecg' or '.txt'
        p = argv[i] + (len >= 4 ? len - 4 : 0);
        if (len >= 4 && (std::strcmp(".ecg", p) == 0 ||
                         std::strcmp(".ECG", p) == 0))
            format = 1;
        else if (len >= 4 && (std::strcmp(".txt", p) == 0 ||
                              std::strcmp(".TXT", p) == 0))
            format = 2;
        else {
            std::fprintf(stderr, "%s: ignoring '%s'\n", argv[0], argv[i]);
            continue; // not an .ecg or .txt file
        }
        if ((ifile = std::fopen(argv[i], "rb")) == nullptr) {
            std::fprintf(stderr, "%s: can't open '%s'\n", argv[0], argv[1]);
            continue;
        }
        *p = '\0'; // strip off extension
        // AHA record names are 4 (ASCII) digits
        record = (p - argv[i] >= 4) ? std::string(p - 4) : std::string(argv[i]);
        // reset the state kept for each input file
        std::memset(txtbuf, 0, sizeof(txtbuf));
        v[0] = v[1] = 0;
        a = WFDB_Annotation();
        if (sflag) { // skip first 145 minutes if making a short-format record
            // (wfdb-x: 145 minutes at -F; the C program assumed 250 Hz)
            long nskip = static_cast<long>(SKIPMIN * 60L * Ffreq); // samples

            if (format == 1)
                std::fseek(ifile, nskip * BINFRAMELEN, SEEK_SET);
            else if (format == 2) {
                long t;

                for (t = 0; t < nskip; t++)
                    (void)readtxtdata();
            }
            if (record.size() > 1)
                record[1] += 2; // fix record name (n0nn->n2nn, n1nn->n3nn)
        }
        process(record.c_str());
        std::fclose(ifile);
    }
    std::exit(0);
}
