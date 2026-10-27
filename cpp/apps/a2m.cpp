// a2m.cpp: convert an AHA format annotation file to MIT format.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of convert/a2m.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the new option -F
// FREQ gives it when the record has no header or its header gives none, and is
// then required (the original assumed 250 Hz, or 1 sample per second without a
// header); annotation times given in milliseconds (AHA file types 1 to 3) are
// converted at the record's sampling frequency (the original assumed 4 ms per
// sample); --legacy, as the first argument, restores the original behavior.
// Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the
// reasons.
//
// Original C program: convert/a2m.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2010 George B. Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// This program converts four types of AHA format annotation files to MIT
// format:
//
//  Type  Description
//
//    0   AHA-format annotation files produced by WFDB library-based programs
//        that use AHA_WRITE mode and `putann' (the `m2a' translator is an
//        example of such a program).  Time is measured in sample intervals
//        from the beginning of the record, and MIT annotation codes are
//        included and read into the `chan' field of the annotation by
//        `getann';  if such codes are present (i.e., if `chan' is non-zero),
//        the AHA code is ignored.
//
//    1   Standard AHA annotation files from short-format AHA DB distribution
//        tapes.  Time is measured in milliseconds from the beginning of the
//        test period (five minutes, or 75000 sample intervals at 4 ms/sample
//        interval, after the first sample).
//
//    2   Standard AHA annotation files from long-format AHA DB distribution
//        tapes.  Time is measured as for filetype 1, except that the test
//        period begins 2.5 hours (2,225,000 sample intervals) after the first
//        sample.
//
//    3   `Compressed' (*.ANO) annotation files from AHA DB CD-ROMs or floppy
//        diskettes.  Time is measured as for files of type 1 or 2, depending
//        on the record name (x2xx or x3xx: short format, x0xx or x1xx: long
//        format).

#include <cstdio>
#include <sys/stat.h>
#include <cstdlib>
#include <cstring>
#include <string>

#include <wfdbx/ecgmap.hpp>
#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

static bool is_directory(const char *name)
{
    struct stat st;
    return stat(name, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR;
}

static const char *pname;

constexpr size_t AHA_ANNLEN = 6;    // length of a compressed AHA annotation
// Sampling frequency of the AHA DB (Hz), assumed in legacy mode (wfdb-x)
constexpr double AHA_FREQ = 250.;

// A time in milliseconds as a sample number, at the sampling frequency of the
// record (wfdb-x; the C program, like legacy mode, assumed 4 ms per sample).
static WFDB_Time ms_to_samples(WFDB_Time t)
{
    if (wfdbx_get_legacy()) return t >> 2;  // 4 msec/sample
    return static_cast<WFDB_Time>(t * sampfreq(nullptr) / 1000.);
}

static char *prog_name(char *s)
{
    char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

static const char *help_strings[] = {
    "usage: %s -i AHAFILE [ OPTIONS ... ]\n",
    "where AHAFILE is the name of the AHA-format input annotation file,",
    "and OPTIONS may include:",
    " -a ANNOTATOR  specify the output annotator name (default: 'atr')",
    " -F FREQ       sampling frequency, if the record header does not specify",
    "                one (AHA database: 250)",
    " -h            print this usage summary",
    " -r RECORD     specify the name of the output RECORD (default: use the",
    "                input file name, less path info and extension, as RECORD)",
    " -s TIME       shift annotations by TIME",
    "                (defaults: 0 for TYPE 0,",
    "                      5:0 for TYPE 1, (or TYPE 3 if RECORD=x2xx or x3xx)",
    "                   2:30:0 for TYPE 2, (or TYPE 3 if RECORD=x0xx or x1xx)",
    " -t TYPE       specify type of file to be converted:",
    "                0 for files produced by WFDB applications in AHA format,",
    "                1 for short-format tape files,",
    "                2 for long-format tape files, or",
    "                3 for compressed files from AHA DB CD-ROMs or diskettes",
    "                (defaults: 3 if AHAFILE ends in .ANO or .ano, else 0)",
    nullptr
};

// wfdb-x: the help text of the original program, printed in legacy mode
static const char *legacy_help_strings[] = {
    "usage: %s -i AHAFILE [ OPTIONS ... ]\n",
    "where AHAFILE is the name of the AHA-format input annotation file,",
    "and OPTIONS may include:",
    " -a ANNOTATOR  specify the output annotator name (default: 'atr')",
    " -h            print this usage summary",
    " -r RECORD     specify the name of the output RECORD (default: use the",
    "                input file name, less path info and extension, as RECORD)",
    " -s TIME       shift annotations by TIME",
    "                (defaults: 0 for TYPE 0,",
    "                      5:0 for TYPE 1, (or TYPE 3 if RECORD=x2xx or x3xx)",
    "                   2:30:0 for TYPE 2, (or TYPE 3 if RECORD=x0xx or x1xx)",
    " -t TYPE       specify type of file to be converted:",
    "                0 for files produced by WFDB applications in AHA format,",
    "                1 for short-format tape files,",
    "                2 for long-format tape files, or",
    "                3 for compressed files from AHA DB CD-ROMs or diskettes",
    "                (defaults: 3 if AHAFILE ends in .ANO or .ano, else 0)",
    nullptr
};

static void help()
{
    // wfdb-x: the original help text in legacy mode
    const char **hs = wfdbx_get_legacy() ? legacy_help_strings : help_strings;

    std::fprintf(stderr, hs[0], pname);
    for (int i = 1; hs[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", hs[i]);
}

static int getcann(WFDB_Annotation *ap)
{
    char buf[AHA_ANNLEN];
    long h, m, l;

    if (std::fread(buf, 1, AHA_ANNLEN, stdin) != AHA_ANNLEN) // hard EOF
        return -1;
    // Compressed AHA format:
    //  buf[0]  AHA label (`N', `V', `F', `R', `E', `P', `Q', `[', `]', or `U')
    //  buf[1]  high byte of ahatime, or 0xff if at soft EOF
    //  buf[2]  middle byte of ahatime
    //  buf[3]  low byte of ahatime
    //  buf[4]  high byte of annotation serial number (ignored here)
    //  buf[5]  low byte of serial number
    if ((unsigned)(buf[1] & 0xff) == 0xff) // soft EOF
        return -1;

    ap->anntyp = (char)ammap(buf[0]); // convert AHA label to annotation code

    if (ap->anntyp == 0)
        return -1; // alternate soft EOF, used in a few AHA DB CD-ROM files
    if (buf[0] == 'U')  // AHA `U' (unreadable data) label
        ap->subtyp = -1; // decode as NOISE, subtype = -1
    else
        ap->subtyp = 0;  // all others have subtype = 0

    h = (long)buf[1] & 0xff;
    m = (long)buf[2] & 0xff;
    l = (long)buf[3] & 0xff;
    ap->time = (h << 16) | (m << 8) | l; // time in milliseconds from the
                                         // start of the annotated segment
    return 0;
}

// Exit after reporting an unrecognized option (wfdb-x: also the wfdb-x
// options, in legacy mode).
[[noreturn]] static void unrecognized(const char *arg)
{
    std::fprintf(stderr, "%s: unrecognized option %s\n", pname, arg);
    std::exit(1);
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    char *ifname = nullptr, *p, *record = nullptr;
    const char *oann = "atr";
    int i, type = -1;
    WFDB_Time offset = 0;
    double Ffreq = 0.;
    unsigned int nann = 2;
    WFDB_Anninfo afarray[2];
    static WFDB_Annotation annot;

    // Read and interpret command-line arguments.
    pname = prog_name(argv[0]);
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i] + 1)) {
            case 'a': // annotator name follows
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: output annotator name must follow -a\n",
                                 pname);
                    std::exit(1);
                }
                oann = argv[i];
                break;
            case 'F': // sampling frequency follows (wfdb-x)
                if (wfdbx_get_legacy())   // wfdb-x: not in the original
                    unrecognized(argv[i]);
                if (++i >= argc || std::sscanf(argv[i], "%lf", &Ffreq) != 1 ||
                    Ffreq <= 0.) {
                    std::fprintf(stderr,
                              "%s: sampling frequency (> 0) must follow -F\n",
                                 pname);
                    std::exit(1);
                }
                break;
            case 'h': // help requested
                help();
                std::exit(1);
                break;
            case 'i': // input file name follows
                if (++i >= argc) {
                    std::fprintf(stderr,
                        "%s: name of AHA-format input file must follow -i\n",
                                 pname);
                    std::exit(1);
                }
                ifname = argv[i];
                if (type < 0 && std::strlen(ifname) > 4) {
                    p = ifname + std::strlen(ifname) - 4;
                    if (std::strcmp(p, ".ANO") == 0 ||
                        std::strcmp(p, ".ano") == 0)
                        type = 3;
                }
                break;
            case 'r': // record name follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: record name must follow -a\n",
                                 pname);
                    std::exit(1);
                }
                record = argv[i];
                break;
            case 's': // time shift follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: time shift must follow -s\n",
                                 pname);
                    std::exit(1);
                }
                offset = i; // save position in arg list, convert to time
                            // later when sampling frequency is known
                break;
            case 't': // file type follows
                if (++i >= argc || (type = std::atoi(argv[i])) < 0 ||
                    type > 3) {
                    std::fprintf(stderr,
                                 "%s: file type (0-3) must follow -t\n",
                                 pname);
                    std::exit(1);
                }
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

    // Quit if input filename was not specified.
    if (ifname == nullptr) {
        help();
        std::exit(1);
    }

    // Attach the input file to the standard input.
    // (C reads a directory forever; wfdb-x reports it as unreadable)
    if (std::strcmp(ifname, "-") != 0 &&
        (is_directory(ifname) ||
         std::freopen(ifname, "rb", stdin) == nullptr)) {
        std::fprintf(stderr, "%s: can't read input file `%s'\n", pname,
                     ifname);
        std::exit(2);
    }

    // If no output record name was specified, use the basename of the input
    // file (prog_name strips off any path info from ifname, and any extension
    // is stripped off in the 'for' loop).
    if (record == nullptr) {
        record = prog_name(ifname);
        if (*record)
            for (p = record + 1; *p; p++)
                if (*p == '.') {
                    *p = '\0';
                    break;
                }
    }

    if (type < 0) type = 0;

    // Open the annotation files.
    afarray[0].name = oann;
    afarray[0].stat = WFDB_WRITE;
    if (type != 3) {
        afarray[1].name = "-";
        afarray[1].stat = WFDB_AHA_READ;
    } else
        nann = 1;
    if (annopen(record, afarray, nann) < 0)
        std::exit(2);

    // Set the time shift.
    // wfdb-x: if the record header does not give the sampling frequency, -F
    // must give it.  (The C program assumed the rate of the AHA database,
    // 250 Hz, if a header without a frequency existed, and 1 sample per
    // second if there was no header, as legacy mode does.)
    if (wfdbx_get_legacy()) {
        if (sampfreq(record) == 0.)
            (void)setsampfreq(AHA_FREQ);
    } else if (sampfreq(record) <= 0.) {
        if (Ffreq > 0.)
            (void)setsampfreq(Ffreq);
        else {
            std::fprintf(stderr, "%s: sampling frequency of record %s is not "
                         "specified (use -F)\n", pname, record);
            std::exit(1);
        }
    }
    if (offset)
        offset = strtim(argv[offset]);
    else {
        switch (type) {
        case 0:
            break;
        case 1:
            offset = strtim("5:0");
            break;
        case 2:
            offset = strtim("2:30:0");
            break;
        case 3:
            if (std::strlen(record) == 4 &&
                (record[1] == '0' || record[1] == '1'))
                offset = strtim("2:30:0"); // long format
            else if (std::strlen(record) == 4 &&
                     (record[1] == '2' || record[1] == '3'))
                offset = strtim("5:0"); // short format
            // otherwise, leave offset at zero (unrecognized format)
            break;
        }
    }

    // Reformat the annotations.
    switch (type) {
    case 0:
        while (getann(0, &annot) >= 0) {
            if (annot.chan) { // MIT annotation code present
                annot.anntyp = (char)annot.chan;
                annot.chan = 0;
            }
            annot.time += offset;
            if (putann(0, &annot) < 0)
                break;
        }
        break;
    // Times in milliseconds are converted at the sampling frequency of the
    // record (wfdb-x; the C program assumed 4 ms per sample, i.e., 250 Hz,
    // whatever the record's frequency, as legacy mode does).
    case 1:
    case 2:
        while (getann(0, &annot) >= 0) {
            annot.time = ms_to_samples(annot.time) + offset;
            (void)putann(0, &annot);
        }
        break;
    case 3:
        while (getcann(&annot) >= 0) {
            annot.time = ms_to_samples(annot.time) + offset;
            (void)putann(0, &annot);
        }
        break;
    }

    wfdbquit();
    std::exit(0);
}
