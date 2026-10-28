// md2a.cpp: convert MIT format signal file(s) to AHA DB distribution tape
// format.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of convert/md2a.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: convert/md2a.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2001 George B. Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// This program converts the signal file(s) of a two-signal DB record into AHA
// DB distribution tape format (format 16, multiplexed signals, with a special
// `end of data' marker after the last sample).  It can also convert DB
// records with other numbers of signals into the same format, but AHA DB
// distribution tape format is defined only for two-signal records.
//
// This program is provided as a convenience for those who may have software
// that requires files in AHA tape format as input.  It does *not* generate
// files in the format currently used for distribution of the AHA database on
// floppy disk;  program `ad2m' can perform the reverse conversion, however.

#include <cstdio>
#include <cstdlib>
#include <vector>
#include <cstring>
#include <string>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

#define EODF 0100000 // AHA data file end-of-data marker

static const char *pname;

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

static const char *help_strings[] = {
    "usage: %s -o AHAFILE -r RECORD [ OPTIONS ... ]\n",
    "where AHAFILE is the name of the AHA-format output signal file,",
    "RECORD is the record name, and OPTIONS may include:",
    " -h         print this usage summary",
    " -n NEWREC  create a header file for the output signal file, so it",
    "             may be read as record NEWREC",
    nullptr
};

static void help()
{
    std::fprintf(stderr, help_strings[0], pname);
    for (int i = 1; help_strings[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", help_strings[i]);
}

int main(int argc, char **argv)
{
    // WFDB-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    const char *nrec = nullptr, *ofname = nullptr, *record = nullptr;
    int i, nsig;
    static WFDB_Siginfo s[WFDB_MAXSIG];

    pname = prog_name(argv[0]);
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i] + 1)) {
            case 'h': // help requested
                help();
                std::exit(1);
                break;
            case 'n': // new record name follows
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: new record name must follow -n\n",
                                 pname);
                    std::exit(1);
                }
                nrec = argv[i];
                break;
            case 'o': // output file name follows
                if (++i >= argc) {
                    std::fprintf(stderr,
                        "%s: name of AHA-format output file must follow -o\n",
                                 pname);
                    std::exit(1);
                }
                ofname = argv[i];
                break;
            case 'r':
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: record name must follow -r\n",
                                 pname);
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
    if (ofname == nullptr || record == nullptr) {
        help();
        std::exit(1);
    }

    // Give up unless at least one input signal is readable.
    if ((nsig = isigopen(record, s, WFDB_MAXSIG)) < 1)
        std::exit(2);

    // Check that the new record name is legal before proceeding.  Note that
    // this step creates a header file in the current directory which is
    // overwritten below, after the processing is completed.
    if (nrec != nullptr && newheader(nrec) < 0) std::exit(3);

    // Set the output signal specifications.
    for (i = 0; i < nsig; i++) {
        s[i].fname = ofname;
        s[i].desc = "";
        s[i].group = 0;
        s[i].fmt = 16;
    }

    // Give up if the output cannot be written.
    if (osigfopen(s, (unsigned)nsig) < nsig) std::exit(4);

    // Copy the input to the output.  Reformatting is handled by putvec().
    // x has one element per output sample of a frame (at least
    // WFDB_MAXSIG); getvec sets the first nsig, the others stay zero.  (In
    // C, x is an uninitialized array of WFDB_MAXSIG; see "Undefined
    // behaviors" in docs/KNOWN_C_BEHAVIORS.md.)
    int nout = 0;
    for (i = 0; i < nsig; i++)
        nout += s[i].spf > 1 ? s[i].spf : 1;
    std::vector<int> xv(nout > WFDB_MAXSIG ? nout : WFDB_MAXSIG, 0);
    int *x = xv.data();
    while (getvec(x) == nsig && putvec(x) == nsig)
        ;

    // Write the new header file if requested.
    if (nrec) (void)newheader(nrec);

    // Write the end-of-data marker.
    for (i = 0; i < nsig; i++)
        x[i] = EODF;
    (void)putvec(x);

    // Clean up.
    wfdbquit();
    std::exit(0);
}
