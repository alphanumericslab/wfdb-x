// edf2mit.cpp: convert EDF (European Data Format) file to MIT format header
// and signal files (C++ port of convert/edf2mit.c)
//
// Copyright (C) 1996-2004 George B. Moody (original C program,
// convert/edf2mit.c).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).
//
// As in the C program, the header fields are read into one reusable 81-byte
// buffer, so a 16-character signal label is followed by a space and by the
// bytes that remain in the buffer from earlier fields (see
// docs/KNOWN_C_BEHAVIORS.md).  Where the C program has undefined behavior,
// this port uses: 0 for header fields that cannot be parsed and are left
// uninitialized in C; the characters of the input file name only (not the
// bytes beyond its end) for the default record name; 0 for samples beyond
// the end of a data record (if the samples per frame do not divide the
// samples per record); 0 frames per record if a signal has 0 samples per
// frame; and INT_MIN for out-of-range conversions of doubles to int (as on
// x86).

#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <wfdbx/wfdb.hpp>

#include "cemul.hpp"

using namespace wfdbx;
using cemul::d2i;

static const char *pname;

static double gcd(double x, double y);
static void help();

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    char buf[81] = {}, record[WFDB_MAXRNL+1] = {};
    double spr = 0, sps;
    std::FILE *ifile = nullptr;
    int big_endian = 0, fpb, h, i, j, k, l, nsig = 0, nosig = 0,
        tspf = 0, ispf = 0, vflag = 0,
        day = 0, month = 0, year = 0, hour = 0, minute = 0, second = 0;
    long adcrange;
    std::vector<int> siglist;
    WFDB_Sample *vo;

    pname = argv[0];
    record[0] = '\0';
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (argv[i][1]) {
          case 'b':     // input is in big-endian byte order
            big_endian = 1;
            break;
          case 'h':     // show usage and quit
            help();
            std::exit(0);
          case 'i':     // file name follows
            if (++i < argc) {
                if (!std::strcmp(argv[i], "-"))
                    ifile = stdin;
                else {
                    ifile = std::fopen(argv[i], "rb");
                    if (ifile == nullptr) {
                        std::fprintf(stderr, "%s: can't read %s\n", pname,
                                     argv[i]);
                        std::exit(1);
                    }
                    if (record[0] == 0) {
                        size_t len = std::strlen(argv[i]);
                        for (j = 0; j < WFDB_MAXRNL &&
                                 static_cast<size_t>(j) < len; j++) {
                            char c = argv[i][j];

                            if (('0' <= c && c <= '9') ||
                                ('a' <= c && c <= 'z') ||
                                ('A' <= c && c <= 'Z'))
                                record[j] = c;
                            else if (c == '.') break;
                            else record[j] = '_';
                        }
                        record[j] = '\0';
                    }
                }
            }
            break;
          case 'r':     // record name follows
            if (++i < argc)
                std::strncpy(record, argv[i], WFDB_MAXRNL);
            else {
                std::fprintf(stderr, "%s: record name must follow -r\n",
                             pname);
                std::exit(1);
            }
            break;
          case 's':     // signal list follows
            // count the number of output signals
            for (j = 0; ++i < argc && *argv[i] != '-'; j++)
                ;
            if (j == 0) {
                std::fprintf(stderr, "%s: signal list must follow -s\n",
                             pname);
                std::exit(1);
            }
            // fill the signal list
            for (i -= j; i < argc && *argv[i] != '-'; )
                siglist.push_back(std::atoi(argv[i++]));
            nosig = static_cast<int>(siglist.size());
            i--;
            break;
          case 'v':     // select verbose mode
            vflag = 1;
            break;
        }
    }

    if (ifile == nullptr) {
        help();
        std::exit(1);
    }

    if (record[0] == '\0' || newheader(record) < 0) {
        std::fprintf(stderr, "\n");
        help();
        std::fprintf(stderr,
  "\nRun %s again, specifying a valid name for the output record,\n", argv[0]);
        std::fprintf(stderr,
                     "using the -r option as described above.\n\n");
        std::fprintf(stderr,
  "  Valid record names may include letters, digits, and underscores only.\n");
        std::exit(1);
    }

    // Read a header field of n bytes into buf, mark its end with a space,
    // and replace trailing spaces (from buf[t] backward) with NULs.  Returns
    // the index of the last non-space character (or -1).
    auto field = [&](int n, int t) {
        if (std::fread(buf, 1, n, ifile) != static_cast<size_t>(n)) {}
        buf[n] = ' ';
        int jj;
        for (jj = t; jj >= 0 && buf[jj] == ' '; jj--)
            buf[jj] = '\0';
        return jj;
    };

    if (std::fread(buf, 1, 8, ifile) != 8) {}
    // Check to see that the input is an EDF file.  (This check will detect
    // most but not all other types of files.)
    if (std::strncmp(buf, "0       ", 8)) {
        std::fprintf(stderr,
           "%s: input does not appear to be EDF -- no conversion attempted.\n",
                     pname);
        std::exit(2);
    }
    buf[8] = ' ';
    for (j = 8; j >= 0 && buf[j] == ' '; j--)
        buf[j] = '\0';
    if (vflag) std::printf("EDF version number: '%s'\n", buf);

    field(80, 80);
    if (vflag) std::printf("Patient ID: '%s'\n", buf);

    field(80, 80);
    if (vflag) std::printf("Recording ID: '%s'\n", buf);

    field(8, 8);
    if (vflag) std::printf("Recording date: '%s'\n", buf);
    std::sscanf(buf, "%d%*c%d%*c%d", &day, &month, &year);
    if (year < 1970) year += 1900;
    if (year < 1970) year += 100;       // should work for a while

    field(8, 8);
    if (vflag) std::printf("Recording time: '%s'\n", buf);
    std::sscanf(buf, "%d%*c%d%*c%d", &hour, &minute, &second);

    field(8, 8);
    if (vflag) std::printf("Number of bytes in header record: '%s'\n", buf);

    j = field(44, 44);
    if (j > 0)
    if (vflag) std::printf("Free space: '%s'\n", buf);

    field(8, 8);
    if (vflag) std::printf("Number of data records: '%s'\n", buf);

    field(8, 8);
    if (vflag)
        std::printf("Duration of each data record in seconds: '%s'\n", buf);
    std::sscanf(buf, "%lf", &spr);
    if (spr <= 0.0) spr = 1.0;

    field(4, 4);
    if (vflag) std::printf("Number of signals: '%s'\n", buf);
    std::sscanf(buf, "%d", &nsig);

    if (nsig < 1) std::exit(1);

    std::vector<WFDB_Siginfo> si(nsig);
    std::vector<int> spb(nsig);
    std::vector<long> sigdmax(nsig), sigdmin(nsig);
    std::vector<double> sigpmax(nsig), sigpmin(nsig), sampfreq(nsig);

    if (nosig == 0) {   // initialize signal list if necessary
        siglist.resize(nsig);
        for ( ; nosig < nsig; nosig++)
            siglist[nosig] = nosig;
    }
    else {
        for (i = 0; i < nosig; i++) {
            if (siglist[i] < 0 || siglist[i] >= nsig) {
                std::fprintf(stderr,
                             "%s: invalid signal number, %d, in signal list\n",
                             pname, siglist[i]);
                std::exit(1);
            }
        }
    }

    std::vector<WFDB_Siginfo> so(nosig);

    for (i = 0; i < nsig; i++) {
        field(16, 15);
        if (vflag) std::printf("Signal %d label: '%s'\n", i, buf);
        si[i].desc = std::string(buf);
    }

    for (i = 0; i < nsig; i++) {
        j = field(80, 80);
        if (vflag && j > 0)
            std::printf("Signal %d transducer type: '%s'\n", i, buf);
    }

    for (i = 0; i < nsig; i++) {
        field(8, 8);
        if (vflag) std::printf("Signal %d physical dimension: '%s'\n", i, buf);
        si[i].units = std::string(buf);
    }

    for (i = 0; i < nsig; i++) {
        field(8, 8);
        if (vflag) std::printf("Signal %d physical minimum: '%s'\n", i, buf);
        std::sscanf(buf, "%lf", &sigpmin[i]);
    }

    for (i = 0; i < nsig; i++) {
        field(8, 8);
        if (vflag) std::printf("Signal %d physical maximum: '%s'\n", i, buf);
        std::sscanf(buf, "%lf", &sigpmax[i]);
    }

    for (i = 0; i < nsig; i++) {
        field(8, 8);
        if (vflag) std::printf("Signal %d digital minimum: '%s'\n", i, buf);
        std::sscanf(buf, "%ld", &sigdmin[i]);
    }

    for (i = 0; i < nsig; i++) {
        field(8, 8);
        if (vflag) std::printf("Signal %d digital maximum: '%s'\n", i, buf);
        std::sscanf(buf, "%ld", &sigdmax[i]);
    }

    for (i = 0; i < nsig; i++) {
        if (sigpmax[i] == sigpmin[i]) {
            std::fprintf(stderr, "gain for signal %d is undefined\n", i);
            continue;
        }
        si[i].adczero = static_cast<int>((sigdmax[i]+1 + sigdmin[i])/2);
        adcrange = sigdmax[i] - sigdmin[i];
        si[i].gain = adcrange/(sigpmax[i] - sigpmin[i]);
        for (j = 0; adcrange > 1; j++)
            adcrange /= 2;
        si[i].adcres = j;
        si[i].baseline = d2i(sigdmax[i] - sigpmax[i]*si[i].gain + 1);
    }

    for (i = 0; i < nsig; i++) {
        j = field(80, 80);
        if (vflag && j > 0)
            std::printf("Signal %d filtering information: '%s'\n", i, buf);
    }

    sps = 0.0;
    for (i = 0; i < nsig; i++) {
        field(8, 8);
        if (vflag)
            std::printf("Signal %d number of samples per record: '%s'\n", i,
                        buf);
        std::sscanf(buf, "%lf", &sampfreq[i]);
        std::sscanf(buf, "%d", &spb[i]);
        sampfreq[i] /= spr;
    }

    for (i = 0; i < nsig; i++) {
        j = field(32, 32);
        if (vflag && j > 0)
            std::printf("Signal %d free space: '%s'\n", i, buf);
    }

    // Determine the base sampling frequency (the greatest common divisor of
    // all sampling frequencies for the signals in the signal list)
    sps = sampfreq[siglist[0]];
    for (i = 1; i < nosig; i++)
    if (sampfreq[siglist[i]] != sps)
        sps = gcd(sps, sampfreq[siglist[i]]);
    setsampfreq(sps);

    std::snprintf(buf, sizeof(buf), "%02d:%02d:%02d %02d/%02d/%04d",
                  hour, minute, second, day, month, year);
    setbasetime(buf);

    std::string fname = std::string(record) + ".dat";
    for (i = 0; i < nosig; i++) {
        si[siglist[i]].fname = fname;
        si[siglist[i]].fmt = 16;
        tspf += si[siglist[i]].spf = d2i(sampfreq[siglist[i]]/sps + 0.5);
        so[i] = si[siglist[i]];
    }

    for (i = ispf = 0; i < nsig; i++)
        ispf += d2i(sampfreq[i]/sps + 0.5);
    fpb = si[siglist[0]].spf ? spb[siglist[0]] / si[siglist[0]].spf : 0;

    if (vflag)
        std::printf("\nOUTPUT:\nBase sampling frequency: %g Hz\n", sps);

    for (i = j = k = 0; i < nosig; i++) {
        if ((j = si[siglist[i]].spf) > k) {
            k = j; l = siglist[i];
        }
        if (vflag)
          std::printf(
              " Signal %d samples per second: %g (%d sample%s per frame)\n",
              i, sampfreq[siglist[i]], j, j > 1 ? "s" : "");
    }

    std::vector<std::vector<char>> vin(nsig);
    std::vector<size_t> vi(nosig);  // positions within vin[siglist[j]]
    for (i = 0; i < nsig; i++)
        vin[i].resize(spb[i] > 0 ? static_cast<size_t>(spb[i]) * 2 : 0);
    std::vector<WFDB_Sample> vout(tspf > 0 ? tspf : 0);
    osigfopen(so.data(), static_cast<unsigned>(nosig));
    while (true) {
        for (i = 0; i < nsig; i++)
            j = spb[i] > 0 ?
                static_cast<int>(std::fread(vin[i].data(), 2, spb[i], ifile)) :
                0;
        if (j == 0) break;
        for (j = 0; j < nosig; j++)
            vi[j] = 0;
        for (i = 0; i < fpb; i++) {
            vo = vout.data();
            for (j = 0; j < nosig; j++) {
                const std::vector<char> &v = vin[siglist[j]];
                for (k = 0; k < so[j].spf; k++) {
                    size_t p = vi[j];
                    int b0 = p < v.size() ? v[p] : 0;
                    int b1 = p + 1 < v.size() ? v[p + 1] : 0;
                    vi[j] += 2;
                    if (big_endian) {
                        h = b0;         // high byte first
                        l = b1;         // then low byte
                    }
                    else {
                        l = b0;         // low byte first
                        h = b1;         // then high byte
                    }
                    *vo++ = static_cast<int>(
                        static_cast<short>((h << 8) | (l & 0xff)));
                }
            }
            putvec(vout.data());
        }
    }
    if (ifile != stdin) std::fclose(ifile);

    newheader(record);
    wfdbquit();
    std::exit(0);
}

// Calculate the greatest common divisor of x and y.  This function uses
// Euclid's algorithm, modified so that an exact answer is not required if
// the (possibly non-integral) arguments do not have a common divisor that
// can be represented exactly.
static double gcd(double x, double y)
{
    double tol;

    if (x > y) tol = 0.001*y;
    else tol = 0.001*x;

    while (true) {
        if (x > y && x-y > tol) x -= y;
        else if (y > x && y-x > tol) y -= x;
        else return (x);
    }
}

static const char *help_strings[] = {
 "usage: %s [OPTIONS ...]\n",
 "where OPTIONS may include:",
 " -b          input is in big-endian byte order (default: little-endian)",
 " -h          print this usage summary",
 " -i EDFILE   read the specified European Data Format file",
 " -r RECORD   create the specified RECORD (default: input file name without",
 "              suffix)",
 " -s SIGNAL [SIGNAL ...]  copy only the specified signal(s) (use signal",
 "              numbers, beginning with zero;  default: copy all signals)",
 " -v          print debugging output",
 "This program reads an EDF file and creates MIT-format signal and header",
 "files containing the same data.",
nullptr
};

static void help()
{
    int i;

    std::fprintf(stderr, help_strings[0], pname);
    for (i = 1; help_strings[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", help_strings[i]);
}
