// revise.cpp: convert obsolete-format header files into new ones.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of convert/revise.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in ADC resolution: a missing resolution
// stays unspecified (the original assumed 12 bits); --legacy, as the first
// argument, restores the original behavior. Each change is marked "wfdb-x:" in
// the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/revise.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1999 George B. Moody; revised 2018 by Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// Like the C program (which includes <wfdb/wfdblib.h>), this port opens the
// old header with the library's internal wfdb_open().

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <wfdbx/wfdb.hpp>

#include "../src/wfdblib.hpp"

using namespace wfdbx;

static detail::FilePtr iheader;
static WFDB_Siginfo si[WFDB_MAXSIG];
static WFDB_Time nsamples;

static int readoldheader(const char *record, WFDB_Siginfo *siarray);

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    char *record;
    int nsig;

    if (argc < 2) {
        std::fprintf(stderr, "usage: %s record\n", argv[0]);
        std::fprintf(stderr,
   " This program converts obsolete-format header files into new ones.\n");
        std::exit(1);
    }
    record = argv[1];
    if (std::strncmp(record, "header.", 7) == 0) record += 7;
    if ((nsig = readoldheader(record, si)) < 0)
        std::exit(2);
    (void)setheader(record, si, static_cast<unsigned>(nsig));
    std::exit(0);
}

static int readoldheader(const char *record, WFDB_Siginfo *siarray)
{
    char linebuf[256], *p;
    WFDB_Frequency f;
    WFDB_Signal s;
    WFDB_Time ns;
    unsigned int i;
    static const char sep[] = " \t\n";

    // Try to open the header file.
    if ((iheader = detail::wfdb_open("header", record, WFDB_READ)) == nullptr) {
        wfdb_error("init: can't open header for record %s\n", record);
        return (-1);
    }

    // Get the first token (the record name) from the first non-empty,
    // non-comment line.
    do {
        if (iheader->fgets(linebuf, sizeof(linebuf)) == nullptr) {
            wfdb_error("init: can't find record name in record %s header\n",
                       record);
            return (-2);
        }
    } while ((p = std::strtok(linebuf, sep)) == nullptr || *p == '#');
    if (iheader->fp() != stdin && std::strcmp(p, record) != 0) {
        wfdb_error("init: record name in record %s header is incorrect\n",
                   record);
        return (-2);
    }

    // Identify which type of header file is being read by trying to get
    // another token from the line which contains the record name.
    // (Old-style headers have only one token on the first line, but
    // new-style headers have two or more.)
    if ((p = std::strtok(nullptr, sep)) != nullptr) {
        std::fprintf(stderr,
           "The header for record %s appears not to be an old-style header.\n",
                     record);
        return (-2);
    }

    else {
        // We come here if there were no other tokens on the line which
        // contained the record name.  The file appears to be an old-style
        // header file.

        WFDB_Group g, ng;
        int mpx;

        // Determine the number of signal groups.
        if (iheader->fgets(linebuf, sizeof(linebuf)) == nullptr ||
            (p = std::strtok(linebuf, sep)) == nullptr) {
            wfdb_error("init: incorrect format in record %s header\n", record);
            return (-2);
        }
        ng = static_cast<WFDB_Group>(std::atoi(p));

        // Now get information for each signal group.
        for (g = s = 0; g < ng; g++) {

            // Set the group number for the first signal in the group.
            siarray[s].group = g;

            // Get the signal file name.
            if (iheader->fgets(linebuf, sizeof(linebuf)) == nullptr ||
                (p = std::strtok(linebuf, sep)) == nullptr) {
                wfdb_error("init: incorrect format in record %s header\n",
                           record);
                return (-2);
            }
            siarray[s].fname = std::string(p);

            // Determine the gain.
            if (iheader->fgets(linebuf, sizeof(linebuf)) == nullptr ||
                (p = std::strtok(linebuf, sep)) == nullptr) {
                wfdb_error("init: incorrect format in record %s header\n",
                           record);
                return (-2);
            }
            siarray[s].gain = std::atof(p);

            // Determine the sampling frequency.
            if (iheader->fgets(linebuf, sizeof(linebuf)) == nullptr ||
                (p = std::strtok(linebuf, sep)) == nullptr ||
                (f = std::atof(p)) <= 0.) {
                wfdb_error("init: incorrect format in record %s header\n",
                           record);
                return (-2);
            }
            (void)setsampfreq(f);

            // Determine the format, block size, and number of signals in
            // this group.  In old-style headers these three quantities are
            // encoded into two fields.
            if (iheader->fgets(linebuf, sizeof(linebuf)) == nullptr ||
                (p = std::strtok(linebuf, sep)) == nullptr) {
                wfdb_error("init: incorrect format in record %s header\n",
                           record);
                return (-2);
            }
            i = static_cast<unsigned>(std::atoi(p));
            mpx = (p = std::strtok(nullptr, sep)) ? std::atoi(p) : 1;
            if (mpx == 0) mpx = 1;
            if (i != 8 && i != 16) {
                siarray[s].bsize = static_cast<int>(i);
                if (mpx < 0) {
                    mpx = -mpx;
                    siarray[s].fmt = 8;
                }
                else
                    siarray[s].fmt = 16;
            }
            else {
                siarray[s].fmt = static_cast<int>(i);
                siarray[s].bsize = 0;
            }

            // Determine the ADC resolution.
            siarray[s].adcres = (p = std::strtok(nullptr, sep)) ?
                                std::atoi(p) :
                                (wfdbx_get_legacy() ? WFDB_DEFRES : 0);
            // wfdb-x: C (and legacy mode) assumed WFDB_DEFRES

            // Determine the ADC zero.
            siarray[s].adczero = (p = std::strtok(nullptr, sep)) ?
                                 std::atoi(p) : 0;

            // Determine the initial value.
            if (iheader->fgets(linebuf, sizeof(linebuf)) == nullptr ||
                (p = std::strtok(linebuf, sep)) == nullptr) {
                wfdb_error("init: incorrect format in record %s header\n",
                           record);
                return (-2);
            }
            siarray[s].initval = std::atoi(p);

            // Determine the number of samples.
            ns = (p = std::strtok(nullptr, sep)) ? std::atol(p) : 0L;
            if (ns < 0L) {
                wfdb_error("init: incorrect format in record %s header\n",
                           record);
                return (-2);
            }
            if (nsamples == 0L) nsamples = ns;
            else if (ns > 0L && ns != nsamples) {
                wfdb_error("warning (init):\n");
                wfdb_error(" record %s durations are inconsistent\n", record);
                // nsamples must match the shortest record duration.
                if (nsamples > ns)
                    nsamples = ns;
            }

            // Determine the checksum.
            if ((p = std::strtok(nullptr, sep)) != nullptr) {
                siarray[s].cksum = std::atoi(p);
                siarray[s].nsamp = static_cast<long>(ns);
            }
            else {
                siarray[s].cksum = 0;
                siarray[s].nsamp = 0L;
            }

            // If this signal group contains more than one signal, make
            // additional copies of the siginfo structure for the other
            // signals.
            while (++s < WFDB_MAXSIG && --mpx > 0)
                siarray[s] = siarray[s-1];

            if (s == WFDB_MAXSIG && (mpx > 0 || g < ng - 1)) {
                wfdb_error("init: too many signals in record %s\n", record);
                return (-2);
            }
        }

        // Now generate signal descriptions for each signal.
        for (i = 0; i < s; i++) {
            char desc[WFDB_MAXRNL + 1024];
            std::snprintf(desc, sizeof(desc), "record %s, signal %d", record,
                          static_cast<int>(i));
            siarray[i].desc = std::string(desc);
        }
    }

    return static_cast<int>(s);   // return number of available signals
}
