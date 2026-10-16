// xform.cpp: sampling frequency, amplitude, and format conversion for WFDB
// records (C++ port of app/xform.c)
//
// Copyright (C) 1983-2010 George B. Moody (original C program, app/xform.c;
// revised 2017-2020 by Benjamin Moody).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).
//
// Dither uses an exact emulation of glibc's rand() (after srand(0)), so that
// the output is the same on all platforms.  Conversions of out-of-range
// doubles to int yield INT_MIN (as on x86), and int additions and
// subtractions wrap around.

#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include <wfdbx/ecgcodes.hpp>
#include <wfdbx/wfdb.hpp>

#include "cemul.hpp"

using namespace wfdbx;
using cemul::d2i;
using cemul::iadd;
using cemul::isub;

static const char *pname;
static const char *script = nullptr;
static double gcd(double x, double y);
static const char *prog_name(const char *s);
static void help();

static cemul::GlibcRand rng;   // glibc's rand(), for platform-independent dither

// The following definition yields dither with a triangular PDF in (-1,1).
#define DITHER (((double)rng.rand() + (double)rng.rand()) / \
                cemul::GlibcRand::RAND_MAX_ - 1.0)

static char *script_fgets(char *buffer, size_t length, std::FILE *f)
{
    if (!std::fgets(buffer, static_cast<int>(length), f)) {
        if (script) {
            std::fprintf(stderr, "\n%s: unexpected end of file in %s\n",
                         pname, script);
            std::exit(1);
        } else {
            std::strcpy(buffer, "\n");
        }
    }
    return (buffer);
}

// wfdb-x: legacy mode (original behavior).  The ADC resolution the C program
// offered for an output signal in format fmt, given the resolution res of
// the input (or previous output) signal.
static int legacy_output_adcres(int fmt, int res)
{
    switch (fmt) {
    case 80:
    case 508:
        return 8;
    case 212:
        return (res < 8 || res > 12) ? 12 : res;
    case 310:
        return (res < 8 || res > 10) ? 10 : res;
    case 24:
    case 524:
        return (res < 8 || res > 24) ? 24 : res;
    case 32:
        return (res < 8 || res > 32) ? 32 : res;
    case 16:
    case 61:
    case 160:
    case 516:
    default:
        return (res < 8 || res > 16) ? WFDB_DEFRES : res;
    }
}

// wfdb-x: legacy mode (original behavior).  The C program's guess of an
// unspecified input ADC resolution, from the format.
static int legacy_input_adcres(int fmt)
{
    switch (fmt) {
    case 80:
    case 508:
        return 8;
    case 212:
        return 12;
    case 310:
        return 10;
    case 24:
    case 524:
        return 24;
    case 32:
        return 32;
    case 16:
    case 61:
    case 160:
    case 516:
    default:
        // for historical compatibility, 16-bit formats assume a resolution
        // of WFDB_DEFRES, although it would make more sense to assume a
        // resolution of 16 here
        return WFDB_DEFRES;
    }
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    char btstring[30];
    const char *irec = nullptr, *orec = nullptr, *nrec = nullptr,
               *startp = "0:0";
    std::vector<double> gain;
    double ifreq, ofreq = 0.0;
    int clip = 0, dflag = 0, fflag = 0, gflag = 0, Hflag = 0, i,
        iframelen, j, m = 0, Mflag = 0, mn = 0, n = 0, nann = 0, nisig,
        nminutes = 0, nosig = 0, oframelen, reopen = 0, sflag = 0, spf,
        uflag = 0, use_irec_desc = 1, vt;
    std::vector<int> siglist, deltav, msiglist, v, vin, vmax, vmin, vout, vv;
    WFDB_Time from = 0L, it = 0L, nsamp = -1L, nsm = 0L, ot = 0L, spm, to = 0L;
    std::vector<WFDB_Anninfo> ai;
    WFDB_Annotation annot;
    std::vector<WFDB_Siginfo> dfin, dfout;
    static char record[WFDB_MAXRNL + 2];

    pname = prog_name(argv[0]);

    // Interpret the command-line arguments.
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i] + 1)) {
            case 'a':   // annotator(s)
                // Count the number of annotators.  Accept the next argument
                // unconditionally as an annotator name; accept additional
                // arguments until we find one beginning with `-', or the end
                // of the argument list.
                for (j = 0; ++i < argc && (j == 0 || *argv[i] != '-'); j++)
                    ;
                if (j == 0) {
                    std::fprintf(stderr, "%s: annotator(s) must follow -a\n",
                                 pname);
                    std::exit(1);
                }
                // allocate storage
                ai.resize(nann + j);
                // fill the annotator information structures
                for (i -= j, j = 0; i < argc && (j == 0 || *argv[i] != '-');
                     j++) {
                    ai[nann].name = argv[i++];
                    ai[nann++].stat = WFDB_READ;
                }
                i--;
                break;
            case 'c':   // clip (limit) output (default: discard high bits)
                clip = 1;
                break;
            case 'd':
                dflag = 1;
                rng.srand(0);   // seed for dither RNG
                break;
            case 'f':   // starting time
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: time must follow -f\n", pname);
                    std::exit(1);
                }
                from = i;
                break;
            case 'h':   // help requested
                help();
                std::exit(0);
                break;
            case 'H':   // open the input record in `high resolution' mode
                Hflag = 1;
                break;
            case 'i':   // input record name follows
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: input record name must follow -i\n",
                                 pname);
                    std::exit(1);
                }
                irec = argv[i];
                break;
            case 'M':   // multifrequency mode (no frequency changes)
                Mflag = 1;
                break;
            case 'n':   // new record name follows
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: new record name must follow -n\n",
                                 pname);
                    std::exit(1);
                }
                nrec = argv[i];
                break;
            case 'N':   // new record name follows;  use signal descriptions
                        // from output record header file in new header file
                use_irec_desc = 0;
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: new record name must follow -N\n",
                                 pname);
                    std::exit(1);
                }
                nrec = argv[i];
                break;
            case 'o':   // output record name follows
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: output record name must follow -o\n",
                                 pname);
                    std::exit(1);
                }
                orec = argv[i];
                break;
            case 's':   // signal list follows
                sflag = 1;
                // count the number of output signals
                for (j = 0; ++i < argc && *argv[i] != '-'; j++)
                    ;
                if (j == 0) {
                    std::fprintf(stderr, "%s: signal list must follow -s\n",
                                 pname);
                    std::exit(1);
                }
                // allocate storage for the signal list
                siglist.resize(nosig + j);
                // fill the signal list
                for (i -= j; i < argc && *argv[i] != '-';)
                    siglist[nosig++] = i++;
                i--;
                break;
            case 'S':   // script name follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: script name must follow -S\n",
                                 pname);
                    std::exit(1);
                }
                script = argv[i];
                break;
            case 't':   // end time
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: time must follow -t\n", pname);
                    std::exit(1);
                }
                to = i;
                break;
            case 'u':   // make annotation times unique
                uflag = 1;
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

    // Check that an input record was specified.
    if (irec == nullptr) {
        help();
        std::exit(1);
    }

    // Check that nrec and orec differ if both were specified.
    if (nrec && orec && (std::strcmp(nrec, orec) == 0)) {
        std::fprintf(stderr,
                     "%s: arguments of -n (or -N) and -o cannot be identical\n",
                     pname);
        std::exit(1);
    }

    // Determine the number of input signals.  If isigopen returns a negative
    // value, quit (isigopen will have emitted an error message).
    if ((nisig = isigopen(irec, nullptr, 0)) < 0) std::exit(2);

    // If the input record contains no signals, we won't write any -- but we
    // might still read and write annotations.
    if (nisig == 0) nosig = 0;

    // Otherwise, prepare to read and write signals.
    else {
        // Allocate storage for variables related to the input signals.
        dfin.resize(nisig);

        // Open the input signals.
        if (isigopen(irec, dfin.data(), nisig) != nisig) std::exit(2);

        // If a signal list was specified using -s, check that the specified
        // signal numbers or names are legal.
        if (sflag) {
            for (i = 0; i < nosig && nosig > 0; i++) {
                const char *s;

                s = argv[siglist[i]];
                if ((siglist[i] = findsig(s)) < 0) {
                    std::fprintf(stderr,
                        "%s: warning: record %s doesn't have a signal '%s'\n",
                                 pname, irec, s);
                    // Delete illegal signal numbers from the list.
                    for (j = i; j + 1 < nosig; j++)
                        siglist[j] = siglist[j + 1];
                    nosig--;
                    i--;
                }
            }
            // If the signal list contained no valid signal numbers, treat
            // this situation as if no signal list was specified.
            if (nosig == 0)
                sflag = 0;
        }

        // If the signal list was not specified using -s, initialize it now.
        if (sflag == 0) {
            nosig = nisig;
            siglist.resize(nosig);
            for (i = 0; i < nosig; i++)
                siglist[i] = i;
        }

        // Allocate storage for variables related to the output signals.
        dfout.resize(nosig);
        gain.resize(nosig);
        deltav.resize(nosig);
        msiglist.resize(nosig);
        v.resize(nosig);
        vmax.resize(nosig);
        vmin.resize(nosig);
        vv.resize(nosig);
    }

    // Determine the input sampling frequency.
    if (Mflag)
        setgvmode(WFDB_LOWRES);
    else if (Hflag)
        setgvmode(WFDB_HIGHRES);
    ifreq = sampfreq(nullptr);
    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    // the input header did not specify one, as legacy mode does).
    if (ifreq <= 0. && !wfdbx_get_legacy()) {
        std::fprintf(stderr,
                     "%s: sampling frequency of record %s is not specified\n",
                     pname, irec);
        wfdbquit();
        std::exit(2);
    }
    spf = getspf();

    if (Mflag) {
        for (i = iframelen = 0; i < nisig; i++)
            iframelen += dfin[i].spf;
        for (i = oframelen = 0; i < nosig; i++)
            oframelen += dfin[siglist[i]].spf;
    } else {
        iframelen = nisig;
        oframelen = nosig;
    }
    vin.resize(iframelen > 0 ? iframelen : 1);
    vout.resize(oframelen > 0 ? oframelen : 1);

    if (orec != nullptr) {  // an output record was specified
        // If a new record name was specified, check that it can be created.
        if (nrec && newheader(nrec) < 0) std::exit(2);

        // Determine the output sampling frequency.
        if (orec) ofreq = sampfreq(orec);
        // wfdb-x: no default sampling frequency (except in legacy mode)
        if (ofreq == 0. && !wfdbx_get_legacy()) {
            std::fprintf(stderr,
                         "%s: sampling frequency of record %s is not "
                         "specified\n", pname, orec);
            wfdbquit();
            std::exit(2);
        }
        (void)setsampfreq(ifreq / spf);

        if (ifreq != ofreq) {
            if (Mflag != 0) {
                std::fprintf(stderr,
      "%s: -M option may not be used if sampling frequency is to be changed\n",
                             pname);
                wfdbquit();
                std::exit(1);
            }
        }
    }

    // If no output record was specified, get signal specs interactively.
    else {
        static char answer[32], directory[32];
        static const int *formats = WFDB_FMT_LIST;
        int format = 0;
        std::FILE *ttyin;

        ttyin = std::fopen(script ? script : "/dev/tty", "r");
        if (ttyin == nullptr) ttyin = stdin;
        if (nrec == nullptr) {
            do {
                std::fprintf(stderr,
                 "Choose a name for the output record (up to %d characters): ",
                             WFDB_MAXRNL);
                script_fgets(record, WFDB_MAXRNL + 2, ttyin);
                record[std::strlen(record) - 1] = '\0';
            } while (record[0] == '\0' || newheader(record) < 0);
            nrec = record;
        }
        if (sflag == 0) {
            do {
                nosig = nisig;
                std::fprintf(stderr,
                             "Number of signals to be written (1-%d) [%d]: ",
                             nisig, nosig);
                script_fgets(answer, sizeof(answer), ttyin);
                (void)std::sscanf(answer, "%d", &nosig);
                if (nosig == 0) {
                    std::fprintf(stderr,
                        "No signals will be written.  Are you sure? [n]: ");
                    script_fgets(answer, sizeof(answer), ttyin);
                    if (*answer != 'y' && *answer != 'Y')
                        nosig = -1;
                }
            } while (nosig < 0 || nosig > nisig);
        }
        if (Mflag) {
            ofreq = ifreq;
            std::fprintf(stderr,
                "Sampling frequency (%g frames/sec) will be unchanged\n",
                         ofreq);
        } else do {
            ofreq = ifreq;
            std::fprintf(stderr,
                "Output sampling frequency (Hz per signal, > 0) [%g]: ",
                         ofreq);
            script_fgets(answer, sizeof(answer), ttyin);
            (void)std::sscanf(answer, "%lf", &ofreq);
        } while (ofreq < 0);
        if (ofreq == 0 && wfdbx_get_legacy())
            ofreq = WFDB_DEFFREQ;   // wfdb-x: as in the C program
        else if (ofreq == 0) {  // wfdb-x: the C program assumed 250 Hz
            std::fprintf(stderr,
                         "%s: the output sampling frequency must be > 0\n",
                         pname);
            wfdbquit();
            std::exit(1);
        }
        if (nosig > 0) {
            std::fprintf(stderr,
                "Specify the name of the directory in which the output\n");
            std::fprintf(stderr,
                " signals should be written, or press <return> to write\n");
            std::fprintf(stderr, " them in the current directory: ");
            script_fgets(directory, sizeof(directory) - 1, ttyin);
            if (*directory == '\n') *directory = '\0';
            else directory[std::strlen(directory) - 1] = '/';
            std::fprintf(stderr, "Any of these output formats may be used:\n");
            std::fprintf(stderr, "    8   8-bit first differences\n");
            std::fprintf(stderr,
                "   16   16-bit two's complement amplitudes (LSB first)\n");
            std::fprintf(stderr,
                "   61   16-bit two's complement amplitudes (MSB first)\n");
            std::fprintf(stderr, "   80   8-bit offset binary amplitudes\n");
            std::fprintf(stderr, "  160   16-bit offset binary amplitudes\n");
            std::fprintf(stderr,
                "  212   2 12-bit amplitudes bit-packed in 3 bytes\n");
            std::fprintf(stderr,
  "  310   3 10-bit amplitudes bit-packed in 15 LS bits of each of 2 words\n");
            std::fprintf(stderr,
  "  311   3 10-bit amplitudes bit-packed in 30 LS bits of 4 bytes\n");
            std::fprintf(stderr,
  "   24   24-bit two's complement amplitudes (LSB first)\n");
            std::fprintf(stderr,
  "   32   32-bit two's complement amplitudes (LSB first)\n");
            std::fprintf(stderr,
                "  508  8-bit amplitudes with FLAC compression\n");
            std::fprintf(stderr,
                "  516  16-bit amplitudes with FLAC compression\n");
            std::fprintf(stderr,
                "  524  24-bit amplitudes with FLAC compression\n");
            do {
                format = dfin[0].fmt;
                std::fprintf(stderr,
                    "Choose an output format from the list above [%d]: ",
                             format);
                script_fgets(answer, sizeof(answer), ttyin);
                (void)std::sscanf(answer, "%d", &format);
                for (i = 1; i < WFDB_NFMTS; i++) // skip format[0] (= 0)
                    if (format == formats[i]) break;
            } while (i >= WFDB_NFMTS);
            if (nosig > 1) {
                std::fprintf(stderr, "Save all signals in one file? [y]: ");
                script_fgets(answer, sizeof(answer), ttyin);
            }
            // Use the input signal specifications as defaults for output.
            for (i = 0; i < nosig; i++)
                dfout[i] = dfin[siglist[i]];
            if (nosig <= 1 || (answer[0] != 'n' && answer[0] != 'N')) {
                std::string filename = std::string(directory) + nrec + ".dat";
                for (i = 0; i < nosig; i++) {
                    dfout[i].fname = filename;
                    dfout[i].group = 0;
                }
            } else {
                for (i = 0; i < nosig; i++) {
                    dfout[i].fname = std::string(directory) + nrec + ".d" +
                                     std::to_string(i);
                    dfout[i].group = i;
                }
            }
        }
        for (i = 0; i < nosig; i++) {
            // Make sure output signals are written in the chosen format.
            dfout[i].fmt = format;
            if (Mflag == 0) dfout[i].spf = 1;
            dfout[i].bsize = 0;     // no block size is defined
            if (!use_irec_desc) {
                char description[WFDB_MAXDSL + 2], units[WFDB_MAXUSL + 2];
                char *p;

                std::fprintf(stderr,
                             "Signal %d description (up to %d characters): ",
                             i, WFDB_MAXDSL);
                script_fgets(description, WFDB_MAXDSL + 2, ttyin);
                description[std::strlen(description) - 1] = '\0';
                dfout[i].desc = std::string(description);
                std::fprintf(stderr,
                             "Signal %d units (up to %d characters): ",
                             i, WFDB_MAXUSL);
                script_fgets(units, WFDB_MAXUSL + 2, ttyin);
                for (p = units; *p; p++) {
                    if (*p == ' ' || *p == '\t') *p = '_';
                    else if (*p == '\n') { *p = '\0'; break; }
                }
                if (*units) dfout[i].units = std::string(units);
                else dfout[i].units.reset();
            }
            std::fprintf(stderr, " Signal %d gain (adu/%s) [%g]: ",
                         i, dfout[i].units ? dfout[i].units->c_str()
                         : wfdbx_get_legacy() ? "mV" : "nd",
                         dfout[i].gain);   // wfdb-x: C showed "mV"
            script_fgets(answer, sizeof(answer), ttyin);
            std::sscanf(answer, "%lf", &dfout[i].gain);
            // wfdb-x: a resolution is offered only if it comes from the input
            // (or the previous output signal) and suits the output format;
            // the C program otherwise offered one based on the format (12 bits
            // for 16-bit formats).  Without one, the user must give it.
            // Legacy mode: as in the C program.
            do {
                int maxres;

                if (i > 0) dfout[i].adcres = dfout[i - 1].adcres;
                if (wfdbx_get_legacy()) {
                    dfout[i].adcres = legacy_output_adcres(dfout[i].fmt,
                                                           dfout[i].adcres);
                    std::fprintf(stderr,
                        " Signal %d ADC resolution in bits (8-32) [%d]: ", i,
                                 dfout[i].adcres);
                    script_fgets(answer, sizeof(answer), ttyin);
                    (void)std::sscanf(answer, "%d", &dfout[i].adcres);
                    continue;
                }
                switch (dfout[i].fmt) {
                case 80:
                case 508: maxres = 8; break;
                case 212: maxres = 12; break;
                case 310: maxres = 10; break;
                case 24:
                case 524: maxres = 24; break;
                case 32: maxres = 32; break;
                default: maxres = 16; break;
                }
                if (dfout[i].adcres >= 8 && dfout[i].adcres <= maxres)
                    std::fprintf(stderr,
                        " Signal %d ADC resolution in bits (8-32) [%d]: ", i,
                                 dfout[i].adcres);
                else {
                    std::fprintf(stderr,
                        " Signal %d ADC resolution in bits (8-32): ", i);
                    dfout[i].adcres = 0;
                }
                script_fgets(answer, sizeof(answer), ttyin);
                (void)std::sscanf(answer, "%d", &dfout[i].adcres);
                if (dfout[i].adcres == 0) {
                    std::fprintf(stderr,
                        "%s: the ADC resolution of signal %d must be "
                        "specified\n", pname, i);
                    wfdbquit();
                    std::exit(1);
                }
            } while (dfout[i].adcres < 8 || dfout[i].adcres > 32);
            std::fprintf(stderr, " Signal %d ADC zero level (adu) [%d]: ",
                         i, dfout[i].adczero);
            script_fgets(answer, sizeof(answer), ttyin);
            (void)std::sscanf(answer, "%d", &dfout[i].adczero);
        }
    }

    // Check the starting and ending times.
    if (from) startp = argv[(int)from];
    from = strtim(startp);
    if (from < 0L) from = -from;
    std::snprintf(btstring, sizeof(btstring), "%s", mstimstr(-from).c_str());
    if (to) {
        to = strtim(argv[(int)to]);
        if (to < 0L) to = -to;
        if (to > 0L && (nsamp = to - from) <= 0L) {
            std::fprintf(stderr,
                         "%s: 'to' time must be later than 'from' time\n",
                         pname);
            std::exit(1);
        }
    }
    spm = strtim("1:0");

    if (Mflag) {
        // In multifrequency mode, the preceding calculations are performed
        // in low-resolution mode (so that 'from' and 'to' are rounded to the
        // nearest frame number, and 'nsamp' is the number of frames to
        // copy.)  For annotation processing, switch to high-resolution mode,
        // convert 'from' and 'to' into high-resolution sample numbers, and
        // set the output annotation resolution accordingly.
        setgvmode(WFDB_HIGHRES);
        spf = getspf();
        from *= spf;
        to *= spf;
        setafreq(ofreq * spf);
    } else {
        // For a single-frequency record, the time resolution for output
        // annotations is equal to the output frame frequency (ofreq), so we
        // do not need an explicit time resolution.  If a default time
        // resolution is set by isigopen, remove it.
        setafreq(0.0);
    }

    // Process the annotation file(s), if any.
    if (nann > 0) {
        const char *p0;
        int cc;
        WFDB_Time tt;

        // Check that the input annotation files are readable.
        if (annopen(irec, ai.data(), static_cast<unsigned>(nann)) < 0 ||
            iannsettime(from) < -1)
            std::exit(2);

        // Associate the output annotation files with the new record, if a
        // new record name was specified.
        if (nrec) p0 = nrec;
        // Otherwise, associate them with the existing output record.
        else p0 = orec;

        // Check that the output annotation files are writeable, without
        // closing the input annotation files.
        std::string p1 = std::string("+") + (p0 ? p0 : "(null)");
        for (i = 0; i < nann; i++)
            ai[i].stat = WFDB_WRITE;
        if (annopen(p1.c_str(), ai.data(), static_cast<unsigned>(nann)) < 0)
            std::exit(2);

        // Write the annotation files.
        for (i = 0; i < nann; i++) {
            tt = 0L;
            cc = -129;
            while (getann(static_cast<unsigned>(i), &annot) == 0 &&
                   (to == 0L || annot.time <= to)) {
                if (annot.time == 0 && annot.subtyp == 0 &&
                    annot.chan == 0 && annot.num == 0 &&
                    (annot.anntyp == NOTQRS || annot.anntyp == NOTE))
                    continue;
                annot.time = static_cast<WFDB_Time>(
                    (annot.time - from) * ofreq / ifreq);
                // If the -u option was specified, make sure that the
                // corrected annotation time is positive and that it is later
                // than the previous annotation time (exception: if it
                // matches the previous annotation time, but the chan field
                // is greater than that of the previous annotation, no time
                // adjustment is performed).
                if (uflag && (annot.time < tt ||
                              (annot.time == tt && annot.chan <= cc)))
                    annot.time = ++tt;
                else tt = annot.time;
                cc = annot.chan;
                (void)putann(static_cast<unsigned>(i), &annot);
            }
        }

        // Close the annotation files.
        for (i = nann - 1; i >= 0; i--) {
            iannclose(i);
            oannclose(i);
        }
    }

    // Quit if no signals are to be written.
    if (nosig == 0) std::exit(0);

    // Check that the input signals are readable.
    std::fprintf(stderr, "Checking input signals ...");
    if (isigsettime(from) < 0)
        std::exit(2);
    std::fprintf(stderr, " done\n");

    // If an output record was specified using `-o', check that the output
    // signals are writable.  Suppress warning messages about possible
    // sampling frequency differences.
    wfdbquiet();
    if (orec && (osigopen(orec, dfout.data(), static_cast<unsigned>(nosig))
                 != nosig)) {
        std::fprintf(stderr, "%s: can't write output signals\n", pname);
        std::exit(2);
    }
    wfdbverbose();

    // Make sure that signal file format is not 0 (putvec cannot write to a
    // null record).
    for (i = 0; i < nosig; i++) {
        if (dfout[i].fmt == 0) {
            std::fprintf(stderr, "%s: signal %d format cannot be 0"
                         " (changing to format 16)\n", pname, i);
            dfout[i].fmt = 16;
            reopen = 1; // record must be (re)opened using osigfopen to make
                        // the change effective
        }
    }

    // Without -M, the output frames hold one sample of each signal (as for
    // output signals specified interactively), so signals of the -o record
    // with more than one sample per frame are (re)opened with one.  (C
    // reads past the end of its output array; see "Undefined behaviors" in
    // docs/KNOWN_C_BEHAVIORS.md.)
    if (Mflag == 0) {
        for (i = 0; i < nosig; i++) {
            if (dfout[i].spf > 1) {
                dfout[i].spf = 1;
                reopen = 1;
            }
        }
    }

    // If the `-n' option was specified, copy the signal descriptions from
    // the input record header file into the WFDB_Siginfo structures for the
    // output record (for eventual storage in the new output header file).
    // To make the changes effective, the output signals must be (re)opened
    // using osigfopen.
    if (nrec && use_irec_desc) {
        for (i = 0; i < nosig; i++)
            dfout[i].desc = dfin[siglist[i]].desc;
        reopen = 1;
    }

    // Determine relative gains and offsets of the signals.  If any output
    // gain must be adjusted, the output signals must be reopened (to ensure
    // that the correct gains are written to the output header).
    for (i = 0; i < nosig; i++) {
        j = siglist[i];
        // A signal may be rescaled by xform depending on the gains and ADC
        // resolutions specified.  The rules for doing so are as follows:
        // 1.  If the output gain has not been specified, the signal is
        //     scaled only if the input and output ADC resolutions differ.
        //     In this case, the scale factor (gain[]) is determined so that
        //     the appropriate number of bits will be dropped from or added
        //     to each signal.
        // 2.  If the output gain has been specified, the signal is scaled by
        //     the ratio of the output and input gains.  (wfdb-x: if the input
        //     signal is uncalibrated, this is an error; the C program assumed
        //     an input gain of WFDB_DEFGAIN.)
        // These rules differ from those used by earlier versions of xform,
        // although the default behavior remains the same in most cases.

        if (dfout[i].gain == 0.) {      // output gain not specified
            // wfdb-x: rescaling by ADC resolution needs both resolutions (the
            // C program guessed an unspecified input resolution from the
            // format, assuming WFDB_DEFRES for 16-bit formats, as legacy
            // mode does).
            if (wfdbx_get_legacy()) {
                if (dfin[j].adcres == 0)
                    dfin[j].adcres = legacy_input_adcres(dfin[j].fmt);
            } else if (dfin[j].adcres == 0 || dfout[i].adcres == 0) {
                const char *r = dfin[j].adcres == 0 ? irec
                                                    : (orec ? orec : nrec);
                std::fprintf(stderr, "%s: ADC resolution of signal %d of "
                             "record %s is not specified\n", pname,
                             dfin[j].adcres == 0 ? j : i,
                             r ? r : "(null)");
                wfdbquit();
                std::exit(2);
            }
            gain[i] = (double)(1LL << dfout[i].adcres) /
                      (double)(1LL << dfin[j].adcres);
        } else if (dfin[j].gain == 0.) {    // output gain specified, but
                                            // input gain not specified
            if (wfdbx_get_legacy())     // wfdb-x: as in the C program
                gain[i] = dfout[i].gain / WFDB_DEFGAIN;
            else {
                std::fprintf(stderr,
                             "%s: signal %d of record %s is uncalibrated; it "
                             "cannot be rescaled to the specified gain\n",
                             pname, j, irec);
                wfdbquit();
                std::exit(2);
            }
        } else                            // input and output gains specified
            gain[i] = dfout[i].gain / dfin[j].gain;

        if (gain[i] != 1.) gflag = 1;
        deltav[i] = d2i(dfout[i].adczero - gain[i] * dfin[j].adczero);
        if (dfout[i].gain != dfin[j].gain * gain[i] ||
            dfout[i].baseline != dfin[j].baseline * gain[i]) {
            dfout[i].gain = dfin[j].gain * gain[i];
            dfout[i].baseline = d2i(dfin[j].baseline * gain[i]);
            reopen = 1;
        }
        // Note that dfout[i].gain is 0 (indicating that the signal is
        // uncalibrated) if dfin[j].gain is 0.  This is a *feature*, not a
        // bug:  we don't want to create output signals that appear to have
        // been calibrated if the inputs weren't calibrated.
    }

    // Reopen output signals if necessary.  (The C program first copies the
    // strings that may be deallocated by osigfopen; the WFDB_Siginfo
    // structures of this implementation own their strings.)
    if (reopen) {
        if (osigfopen(dfout.data(), static_cast<unsigned>(nosig)) != nosig)
            std::exit(2);
    }

    // Determine the legal range of sample values for each output signal.
    for (i = 0; i < nosig; i++) {
        vmax[i] = static_cast<int>(static_cast<unsigned long long>(
            dfout[i].adczero + (1ULL << (dfout[i].adcres - 1)) - 1));
        vmin[i] = static_cast<int>(static_cast<unsigned long long>(
            dfout[i].adczero - (1ULL << (dfout[i].adcres - 1))));
    }

    // If resampling is required, initialize the interpolation/decimation
    // parameters.
    if (ifreq != ofreq) {
        double f = gcd(ifreq, ofreq);

        fflag = 1;
        m = d2i(ifreq / f);
        n = d2i(ofreq / f);
        mn = m * n;
        (void)getvec(vin.data());
        for (i = 0; i < nosig; i++) {
            WFDB_Sample v = vin[siglist[i]];

            if (v != WFDB_INVALID_SAMPLE)
                vv[i] = d2i(v * gain[i] + deltav[i]);
            else
                vv[i] = WFDB_INVALID_SAMPLE;
        }
    }

    // If in multifrequency mode, set msiglist offsets.
    if (Mflag) {
        int j, k;

        for (i = 0; i < nosig; i++) {
            for (j = k = 0; j < siglist[i]; j++)
                k += dfin[j].spf;
            msiglist[i] = k;
        }
    }

    // Process the signals.
    if (fflag == 0 && gflag == 0) {     // no frequency or gain changes
        if (Mflag == 0) {               // standard mode
            while (getvec(vin.data()) >= nisig &&
                   (nsamp == -1L || nsamp-- > 0L)) {
                if (++nsm >= spm) {
                    nsm = 0L;
                    std::fprintf(stderr, ".");
                    std::fflush(stderr);
                    if (++nminutes >= 60) {
                        nminutes = 0;
                        std::fprintf(stderr, "\n");
                    }
                }
                for (i = 0; i < nosig; i++) {
                    if ((vt = vin[siglist[i]]) == WFDB_INVALID_SAMPLE)
                        vout[i] = vt;
                    else {
                        vout[i] = iadd(vt, deltav[i]);
                        if (vout[i] > vmax[i]) {
                            std::fprintf(stderr,
                                         "v[%d] = %d (out of range)\n",
                                         i, vout[i]);
                            if (clip) vout[i] = vmax[i];
                            else vmax[i] = vout[i];
                        } else if (vout[i] < vmin[i]) {
                            std::fprintf(stderr,
                                         "v[%d] = %d (out of range)\n",
                                         i, vout[i]);
                            if (clip) vout[i] = vmin[i];
                            else vmin[i] = vout[i];
                        }
                    }
                }
                if (putvec(vout.data()) < 0) break;
            }
        } else {                        // multifrequency mode
            while (getframe(vin.data()) >= nisig &&
                   (nsamp == -1L || nsamp-- > 0L)) {
                int j, k;

                if (++nsm >= spm) {
                    nsm = 0L;
                    std::fprintf(stderr, ".");
                    std::fflush(stderr);
                    if (++nminutes >= 60) {
                        nminutes = 0;
                        std::fprintf(stderr, "\n");
                    }
                }
                for (i = j = 0; i < nosig; i++) {
                    for (k = 0; k < dfout[i].spf; j++, k++) {
                        if ((vt = vin[msiglist[i] + k]) ==
                            WFDB_INVALID_SAMPLE)
                            vout[j] = vt;
                        else {
                            vout[j] = iadd(vt, deltav[i]);
                            if (vout[j] > vmax[i]) {
                                std::fprintf(stderr,
                                             "v[%d] = %d (out of range)\n",
                                             i, vout[j]);
                                if (clip) vout[j] = vmax[i];
                                else vmax[i] = vout[j];
                            } else if (vout[j] < vmin[i]) {
                                std::fprintf(stderr,
                                             "v[%d] = %d (out of range)\n",
                                             i, vout[j]);
                                if (clip) vout[j] = vmin[i];
                                else vmin[i] = vout[j];
                            }
                        }
                    }
                }
                if (putvec(vout.data()) < 0) break;
            }
        }
    } else if (fflag == 0 && gflag != 0) {  // change gain only
        if (Mflag == 0) {               // standard mode
            while (getvec(vin.data()) >= nisig &&
                   (nsamp == -1L || nsamp-- > 0L)) {
                if (++nsm >= spm) {
                    nsm = 0L;
                    std::fprintf(stderr, ".");
                    std::fflush(stderr);
                    if (++nminutes >= 60) {
                        nminutes = 0;
                        std::fprintf(stderr, "\n");
                    }
                }
                for (i = 0; i < nosig; i++) {
                    if ((vt = vin[siglist[i]]) == WFDB_INVALID_SAMPLE)
                        vout[i] = vt;
                    else {
                        double vd = vt * gain[i] + deltav[i];

                        if (dflag) vd += DITHER;
                        if (vd >= 0) vout[i] = d2i(vd + 0.5);
                        else vout[i] = d2i(vd - 0.5);
                        if (vout[i] > vmax[i]) {
                            std::fprintf(stderr,
                                         "v[%d] = %d (out of range)\n",
                                         i, vout[i]);
                            if (clip) vout[i] = vmax[i];
                            else vmax[i] = vout[i];
                        } else if (vout[i] < vmin[i]) {
                            std::fprintf(stderr,
                                         "v[%d] = %d (out of range)\n",
                                         i, vout[i]);
                            if (clip) vout[i] = vmin[i];
                            else vmin[i] = vout[i];
                        }
                    }
                }
                if (putvec(vout.data()) < 0) break;
            }
        } else {                        // multifrequency mode
            while (getframe(vin.data()) >= nisig &&
                   (nsamp == -1L || nsamp-- > 0L)) {
                int j, k;

                if (++nsm >= spm) {
                    nsm = 0L;
                    std::fprintf(stderr, ".");
                    std::fflush(stderr);
                    if (++nminutes >= 60) {
                        nminutes = 0;
                        std::fprintf(stderr, "\n");
                    }
                }
                for (i = j = 0; i < nosig; i++) {
                    for (k = 0; k < dfout[i].spf; j++, k++) {
                        if ((vt = vin[msiglist[i] + k]) ==
                            WFDB_INVALID_SAMPLE)
                            vout[j] = vt;
                        else {
                            double vd = vt * gain[i] + deltav[i];

                            if (dflag) vd += DITHER;
                            if (vd >= 0) vout[j] = d2i(vd + 0.5);
                            else vout[j] = d2i(vd - 0.5);
                            if (vout[j] > vmax[i]) {
                                std::fprintf(stderr,
                                             "v[%d] = %d (out of range)\n",
                                             i, vout[j]);
                                if (clip) vout[j] = vmax[i];
                                else vmax[i] = vout[j];
                            } else if (vout[j] < vmin[i]) {
                                std::fprintf(stderr,
                                             "v[%d] = %d (out of range)\n",
                                             i, vout[j]);
                                if (clip) vout[j] = vmin[i];
                                else vmin[i] = vout[j];
                            }
                        }
                    }
                }
                if (putvec(vout.data()) < 0) break;
            }
        }
    } else if (fflag != 0 && gflag == 0) {  // change frequency only
        while (getvec(vin.data()) >= nisig &&
               (nsamp == -1L || nsamp-- > 0L)) {
            if (++nsm >= spm) {
                nsm = 0L;
                std::fprintf(stderr, ".");
                std::fflush(stderr);
                if (++nminutes >= 60) {
                    nminutes = 0;
                    std::fprintf(stderr, "\n");
                }
            }
            for (i = 0; i < nosig; i++) {
                if ((vt = vin[siglist[i]]) == WFDB_INVALID_SAMPLE)
                    v[i] = vt;
                else
                    v[i] = iadd(vt, deltav[i]);
            }
            while (ot <= it) {
                double x = (ot % n == 0) ? 1.0 : (double)(ot % n) / (double)n;
                for (i = 0; i < nosig; i++) {
                    if (v[i] == WFDB_INVALID_SAMPLE ||
                        vv[i] == WFDB_INVALID_SAMPLE)
                        vout[i] = WFDB_INVALID_SAMPLE;
                    else {
                        double vd = vv[i] + x * isub(v[i], vv[i]);

                        if (dflag) vd += DITHER;
                        if (vd >= 0) vout[i] = d2i(vd + 0.5);
                        else vout[i] = d2i(vd - 0.5);
                        if (vout[i] > vmax[i]) {
                            std::fprintf(stderr,
                                         "v[%d] = %d (out of range)\n",
                                         i, vout[i]);
                            if (clip) vout[i] = vmax[i];
                            else vmax[i] = vout[i];
                        } else if (vout[i] < vmin[i]) {
                            std::fprintf(stderr,
                                         "v[%d] = %d (out of range)\n",
                                         i, vout[i]);
                            if (clip) vout[i] = vmin[i];
                            else vmin[i] = vout[i];
                        }
                    }
                }
                if (putvec(vout.data()) < 0) { nsamp = 0L; break; }
                ot += m;
            }
            for (i = 0; i < nosig; i++)
                vv[i] = v[i];
            if (it > mn) { it -= mn; ot -= mn; }
            it += n;
        }
    } else if (fflag != 0 && gflag != 0) {  // change frequency and gain
        while (getvec(vin.data()) >= nisig &&
               (nsamp == -1L || nsamp-- > 0L)) {
            if (++nsm >= spm) {
                nsm = 0L;
                std::fprintf(stderr, ".");
                std::fflush(stderr);
                if (++nminutes >= 60) {
                    nminutes = 0;
                    std::fprintf(stderr, "\n");
                }
            }
            for (i = 0; i < nosig; i++) {
                if ((vt = vin[siglist[i]]) == WFDB_INVALID_SAMPLE)
                    v[i] = vt;
                else {
                    double vd = vt * gain[i] + deltav[i];

                    if (dflag) vd += DITHER;
                    if (vd >= 0) v[i] = d2i(vd + 0.5);
                    else v[i] = d2i(vd - 0.5);
                }
            }
            while (ot <= it) {
                double x = (ot % n == 0) ? 1.0 : (double)(ot % n) / (double)n;
                for (i = 0; i < nosig; i++) {
                    if (v[i] == WFDB_INVALID_SAMPLE ||
                        vv[i] == WFDB_INVALID_SAMPLE)
                        vout[i] = WFDB_INVALID_SAMPLE;
                    else {
                        double vd = vv[i] + x * isub(v[i], vv[i]);

                        if (dflag) vd += DITHER;
                        if (vd >= 0) vout[i] = d2i(vd + 0.5);
                        else vout[i] = d2i(vd - 0.5);
                        if (vout[i] > vmax[i]) {
                            std::fprintf(stderr,
                                         "v[%d] = %d (out of range)\n",
                                         i, vout[i]);
                            if (clip) vout[i] = vmax[i];
                            else vmax[i] = vout[i];
                        } else if (vout[i] < vmin[i]) {
                            std::fprintf(stderr,
                                         "v[%d] = %d (out of range)\n",
                                         i, vout[i]);
                            if (clip) vout[i] = vmin[i];
                            else vmin[i] = vout[i];
                        }
                    }
                }
                if (putvec(vout.data()) < 0) { nsamp = 0L; break; }
                ot += m;
            }
            for (i = 0; i < nosig; i++)
                vv[i] = v[i];
            if (it > mn) { it -= mn; ot -= mn; }
            it += n;
        }
    }
    if (nminutes > 0) std::fprintf(stderr, "\n");

    // Generate a new header file, if so requested.
    if (nrec) {
        std::optional<std::string> info;

        (void)setsampfreq(ofreq);
        if (btstring[0] == '[') {
            btstring[std::strlen(btstring) - 1] = '\0'; // discard final ']'
            (void)setbasetime(btstring + 1);
        }
        (void)newheader(nrec);

        // Copy info strings from the input header file into the new one.
        // Suppress error messages from the WFDB library.
        wfdbquiet();
        if ((info = getinfo(irec)))
            do {
                (void)putinfo(info->c_str());
            } while ((info = getinfo(nullptr)));

        // Append additional info summarizing what xform has done.
        std::string xinfo = std::string("Produced by ") + pname +
                            " from record " + irec + ", beginning at " +
                            startp;
        (void)putinfo(xinfo.c_str());
        for (i = 0; i < nosig; i++)
            if (siglist[i] != i) {
                char buf[64];

                xinfo = std::string("record ") + nrec + ", signal " +
                        std::to_string(i) + " <- record " + irec +
                        ", signal " + std::to_string(siglist[i]);
                if (gain[i] != 1.) {
                    std::snprintf(buf, sizeof(buf), " * %g", gain[i]);
                    xinfo += buf;
                }
                if (deltav[i] != 0) {
                    std::snprintf(buf, sizeof(buf), " %c %d",
                                  deltav[i] > 0 ? '+' : '-',
                                  deltav[i] > 0 ? deltav[i] : -deltav[i]);
                    xinfo += buf;
                }
                (void)putinfo(xinfo.c_str());
            }
        wfdbverbose();
    }
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

    if (x > y) tol = 0.001 * y;
    else tol = 0.001 * x;

    while (1) {
        if (x > y && x - y > tol) x -= y;
        else if (y > x && y - x > tol) y -= x;
        else return (x);
    }
}

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

static const char *help_strings[] = {
    "usage: %s -i IREC [OPTIONS ...]\n",
    "where IREC is the name of the record to be converted, and OPTIONS may",
    " include any of:",
    " -a ANNOTATOR [ANNOTATOR ...]  copy annotations for the specified ANNOTATOR",
    "              from IREC;  two or more ANNOTATORs may follow -a",
    " -c          clip output (default: wrap around if out-of-range)",
    " -d          add dither to the input if changing sampling frequency or gain",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          open the input record in `high resolution' mode",
    " -M          process multifrequency record without changing frequencies",
    " -n NREC     create a header file, using record name NREC and signal",
    "              descriptions from IREC",
    " -N NREC     as for -n, but copy signal descriptions from OREC",
    " -o OREC     produce output signal file(s) as specified by the header file",
    "              for record OREC",
    " -s SIGNAL [SIGNAL ...]  write only the specified signal(s)",
    " -S SCRIPT   take answers to prompts from SCRIPT (a text file)",
    " -t TIME     stop at specified time",
    " -u          adjust annotation times if needed to make them unique",
    "Unless you use `-o' to specify an *existing* header that describes the",
    "desired signal files, you will be asked for output specifications.  Use",
    "`-n' to name the record to be created.  Use `-s' to select a subset of the",
    "input signals, or to re-order them in the output file;  arguments that",
    "follow `-s' are *input* signal numbers (0,1,2,...) or names.",
    nullptr
};

static void help()
{
    std::fprintf(stderr, help_strings[0], pname);
    for (int i = 1; help_strings[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", help_strings[i]);
}
