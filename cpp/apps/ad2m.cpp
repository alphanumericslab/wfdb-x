// ad2m.cpp: convert an AHA format signal file to MIT format (C++ port of
// convert/ad2m.c)
//
// Copyright (C) 1983-2007 George B. Moody (original C program,
// convert/ad2m.c).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).
//
// This program converts AHA DB signal files in either the original tape
// format or the `compressed' CD-ROM/diskette file format to MIT format.  It
// also generates header files.

#include <cstdio>
#include <sys/stat.h>
#include <cstdlib>
#include <cstring>
#include <string>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

static bool is_directory(const char *name)
{
    struct stat st;
    return stat(name, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR;
}

#define EODF 0100000 // AHA data file end-of-data marker

static const char *pname;

static char *prog_name(char *s)
{
    char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

static const char *help_strings[] = {
    "usage: %s -i AHAFILE [ OPTIONS ... ]\n",
    "where AHAFILE is the name of the AHA-format input signal file,",
    "and OPTIONS may include:",
    " -c         process a compressed input file (default if AHAFILE ends",
    "             with .CMP or .cmp;  otherwise old AHA tape format assumed)",
    " -f TIME    begin at specified TIME (default: 0, i.e., the beginning",
    "             of the input file)",
    " -F FREQ    sampling frequency in Hz (required; AHA database: 250)",
    " -G GAIN    gain in adu per physical unit (required; AHA database: 400)",
    " -h         print this usage summary",
    " -r RECORD  specify the name of the output RECORD (default: use the,"
    "            input file name, less path info and extension, as RECORD)",
    " -R BITS    ADC resolution in bits (required; AHA database: 12)",
    " -t TIME    stop at specified TIME (default: 35 minutes after the",
    "             starting time if RECORD=x2xx or x3xx, 3 hours if",
    "             RECORD=x0xx or x1xx, or the end of the input file)",
    " -U UNITS   physical units (required unless the gain is 0; AHA: mV)",
    nullptr
};

// wfdb-x: the help text of the original program, printed in legacy mode
static const char *legacy_help_strings[] = {
    "usage: %s -i AHAFILE [ OPTIONS ... ]\n",
    "where AHAFILE is the name of the AHA-format input signal file,",
    "and OPTIONS may include:",
    " -c         process a compressed input file (default if AHAFILE ends",
    "             with .CMP or .cmp;  otherwise old AHA tape format assumed)",
    " -f TIME    begin at specified TIME (default: 0, i.e., the beginning",
    "             of the input file)",
    " -h         print this usage summary",
    " -r RECORD  specify the name of the output RECORD (default: use the,"
    "            input file name, less path info and extension, as RECORD)",
    " -t TIME    stop at specified TIME (default: 35 minutes after the",
    "             starting time if RECORD=x2xx or x3xx, 3 hours if",
    "             RECORD=x0xx or x1xx, or the end of the input file)",
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

// Integer arithmetic below wraps around as in C (32-bit int).
static int wrap_add(int a, int b)
{
    return (int)((unsigned)a + (unsigned)b);
}

static int getcvec(int *v)
{
    int x, y;
    static int v0, v1;

    if ((x = std::getchar()) == EOF)
        return 0;
    if ((y = std::getchar()) == EOF) {
        std::fprintf(stderr, "unexpected EOF in input file\n");
        return 0;
    }

    if ((x & 0x80) == 0) {
        v0 = wrap_add(v0, x & 0x7f);
        if (x & 0x40) v0 = wrap_add(v0, -128);
        v1 = wrap_add(v1, y);
        if (y & 0x80) v1 = wrap_add(v1, -256);
    } else {
        if (x & 0x40) x |= ~(0x3f);
        else x &= 0x7f;
        v0 = wrap_add(v0, x * 256 + y);
        if ((x = std::getchar()) == EOF || (y = std::getchar()) == EOF) {
            std::fprintf(stderr, "unexpected EOF in input file\n");
            return 0;
        }
        if (x & 0x80) x |= ~(0xff);
        v1 = wrap_add(v1, x * 256 + y);
    }

    v[0] = v0;
    v[1] = v1;
    return 2;
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
    std::string dfname;
    const char *Uunits = nullptr, *fstr = nullptr, *tstr = nullptr;
    double Ffreq = 0., Ggain = 0.;
    int cflag = 0, i, v[2], Gset = 0, Rres = 0;
    WFDB_Time t = 0, start_time = 0, end_time = 0;
    static WFDB_Siginfo dfarray[2];

    pname = prog_name(argv[0]);
    if (wfdbx_get_legacy()) {
        // wfdb-x: in legacy mode, the parameters of the AHA database, set by
        // the C program (250 Hz, 400 adu/mV, 12 bits, and no units, i.e.,
        // millivolts); -F, -G, -R and -U are not options then.
        Ffreq = 250.;
        Ggain = 400.;
        Gset = 1;
        Rres = 12;
        (void)setsampfreq(250.);
    }
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i] + 1)) {
            case 'c':
                cflag = 1;
                break;
            case 'f':
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: start time must follow -f\n",
                                 pname);
                    std::exit(1);
                }
                if (wfdbx_get_legacy())     // wfdb-x: as in the C program
                    start_time = strtim(argv[i]);
                else
                    fstr = argv[i]; // converted once -F is known (wfdb-x)
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
                break;
            case 'r':
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: record name must follow -r\n",
                                 pname);
                    std::exit(1);
                }
                record = argv[i];
                break;
            case 't':
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: end time must follow -t\n",
                                 pname);
                    std::exit(1);
                }
                if (wfdbx_get_legacy())     // wfdb-x: as in the C program
                    end_time = strtim(argv[i]);
                else
                    tstr = argv[i]; // converted once -F is known (wfdb-x)
                break;
            case 'F': // sampling frequency (wfdb-x)
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
            case 'G': // gain in adu per physical unit (wfdb-x)
                if (wfdbx_get_legacy())   // wfdb-x: not in the original
                    unrecognized(argv[i]);
                if (++i >= argc || std::sscanf(argv[i], "%lf", &Ggain) != 1 ||
                    Ggain < 0.) {
                    std::fprintf(stderr, "%s: gain (>= 0) must follow -G\n",
                                 pname);
                    std::exit(1);
                }
                Gset = 1;
                break;
            case 'R': // ADC resolution in bits (wfdb-x)
                if (wfdbx_get_legacy())   // wfdb-x: not in the original
                    unrecognized(argv[i]);
                if (++i >= argc || std::sscanf(argv[i], "%d", &Rres) != 1 ||
                    Rres < 1 || Rres > 32) {
                    std::fprintf(stderr,
                            "%s: ADC resolution (1-32 bits) must follow -R\n",
                                 pname);
                    std::exit(1);
                }
                break;
            case 'U': // physical units (wfdb-x)
                if (wfdbx_get_legacy())   // wfdb-x: not in the original
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
    if (ifname == nullptr) {
        help();
        std::exit(1);
    }
    // wfdb-x: the signal parameters must be given explicitly; the C program
    // assumed those of the AHA database (250 Hz, 400 adu/mV, 12 bits, and no
    // units, i.e., millivolts), as legacy mode does (the values set above for
    // legacy mode pass these checks, and no units are required then).
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
    if (Ggain != 0. && Uunits == nullptr && !wfdbx_get_legacy()) {
        std::fprintf(stderr, "%s: the units must be specified (-U)\n",
                     pname);
        std::exit(1);
    }
    (void)setsampfreq(Ffreq);
    if (fstr) start_time = strtim(fstr);
    if (tstr) end_time = strtim(tstr);
    if (0 < end_time && end_time <= start_time) {
        help();
        std::exit(1);
    }
    if (cflag == 0 && std::strlen(ifname) > 4) {
        char *q = ifname + std::strlen(ifname) - 4;

        if (std::strcmp(q, ".CMP") == 0 || std::strcmp(q, ".cmp") == 0)
            cflag = 1;
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

    if (end_time == 0 && std::strlen(record) == 4) { // assume AHA DB input
        if (record[1] == '2' || record[1] == '3')     // short format record
            end_time = strtim("35:0");
        else if (record[1] == '0' || record[1] == '1') // long format record
            end_time = strtim("3:0:0");
    }

    if (end_time == 0) {
        std::fprintf(stderr,
            "%s: warning: end time not specified, output may be truncated\n",
                     pname);
        std::fprintf(stderr, "               rerun with -t TIME to override\n");
        end_time = start_time + strtim("100:0:0");
    }

    dfname = std::string(record) + ".dat";
    dfarray[0].fname = dfarray[1].fname = dfname;
    dfarray[0].desc = dfarray[1].desc = "";
    dfarray[0].gain = dfarray[1].gain = Ggain;
    if (Uunits) dfarray[0].units = dfarray[1].units = std::string(Uunits);
    dfarray[0].fmt = dfarray[1].fmt = 212;
    dfarray[0].adcres = dfarray[1].adcres = Rres;
    if (osigfopen(dfarray, 2) < 0) std::exit(3);

    if (!cflag) { // process tape-format input file
        if (isigopen("16", dfarray, 2) < 2)
            std::exit(2);
        if (start_time > 0 && isigsettime(t = start_time) < 0)
            std::exit(2);
        while (getvec(v) == 2 && v[0] != EODF && putvec(v) > 0 &&
               ++t < end_time)
            ; // continue to soft EOF, hard error, or specified time

        (void)newheader(record); // write header with correct signal length
                                 // and checksums
        while (getvec(v) >= 0)
            ; // continue to hard EOF (to position tape properly if reading
              // from tape)
    } else { // process compressed-format input file
        while (t < start_time && getcvec(v) == 2)
            ++t;
        while (getcvec(v) == 2 && putvec(v) > 0 && ++t < end_time)
            ; // continue to hard EOF, hard error, or specified time

        (void)newheader(record); // write header with correct signal length
                                 // and checksums
    }

    wfdbquit();
    std::exit(0);
}
