// rr2ann.cpp: create an annotation file from an RR interval list
// (C++ port of app/rr2ann.c)
//
// Copyright (C) 2000 George B. Moody (original C program, app/rr2ann.c).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).
//
// The input contains RR intervals (or times of occurrence, with -T) in text
// format, one per line.  The first token on each line is taken to be an RR
// interval; any additional tokens on the same line are ignored.  The output
// is an annotation file in which all beats are marked NORMAL (or have the
// types given in the second column of the input, with -w).

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <wfdbx/ecgcodes.hpp>
#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

#define MAXLINELEN 1024     // longer input lines will be silently split

static const char *pname;

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

static const char *help_strings[] = {
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...] <TEXT-FILE\n",
    "where RECORD and ANNOTATOR specify the output, and OPTIONS may include:",
    " -F FREQ     use FREQ as the sampling frequency (effective only if the"
    "               header file does not exist or does not specify it)",
    " -h          print this usage summary",
    " -T          TEXT-FILE contains times of occurrence, not RR intervals",
    " -x N        multiply input by N to obtain RR in sample intervals",
    "               (default: N = 1)",
    " -w          copy annotation types from second column of input",
    "TEXT-FILE should contain a column of RR intervals (or times of occurrence,",
    "if the -T option is specified), in units of sample intervals (unless the",
    "-x option is used to specify a conversion factor).   The first token on",
    "each line is taken as an RR interval, and (if the -w option is specified)",
    "the second token is taken as an annotation mnemonic (N, V, etc.);  anything",
    "else on the same line is ignored, as are empty lines, spaces and tabs at",
    "the beginning of a line non-numeric tokens and anything following them on",
    "the same line, negative intervals, and zero intervals.  The output consists",
    "of a binary annotation file (RECORD.ANNOTATOR), and (if it does not exist",
    "already) a text header file (RECORD.hea).",
    nullptr
};

// wfdb-x: the help text of the original program, printed in legacy mode
static const char *legacy_help_strings[] = {
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...] <TEXT-FILE\n",
    "where RECORD and ANNOTATOR specify the output, and OPTIONS may include:",
    " -F FREQ     use FREQ as the sampling frequency (effective only if no"
    "               header file exists;  default: 250)",
    " -h          print this usage summary",
    " -T          TEXT-FILE contains times of occurrence, not RR intervals",
    " -x N        multiply input by N to obtain RR in sample intervals",
    "               (default: N = 1)",
    " -w          copy annotation types from second column of input",
    "TEXT-FILE should contain a column of RR intervals (or times of occurrence,",
    "if the -T option is specified), in units of sample intervals (unless the",
    "-x option is used to specify a conversion factor).   The first token on",
    "each line is taken as an RR interval, and (if the -w option is specified)",
    "the second token is taken as an annotation mnemonic (N, V, etc.);  anything",
    "else on the same line is ignored, as are empty lines, spaces and tabs at",
    "the beginning of a line non-numeric tokens and anything following them on",
    "the same line, negative intervals, and zero intervals.  The output consists",
    "of a binary annotation file (RECORD.ANNOTATOR), and (if it does not exist",
    "already) a text header file (RECORD.hea).",
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

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    WFDB_Anninfo ai;
    WFDB_Annotation annot;
    WFDB_Frequency sps = 0.0;
    double rr = 0.0, t = 0.0, xfactor = 1.0;
    static char line[MAXLINELEN];
    const char *record = nullptr, *ainame = nullptr;
    int i, Tflag = 0, wflag = 0;

    pname = prog_name(argv[0]);

    // Interpret command-line options.
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i] + 1)) {
            case 'a':   // annotator follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: annotator must follow -a\n",
                                 pname);
                    std::exit(1);
                }
                ainame = argv[i];
                break;
            case 'F':   // sampling frequency in Hz
                if (++i >= argc ||
                    (sps = static_cast<WFDB_Frequency>(std::atof(argv[i]))) <=
                        0.0) {
                    std::fprintf(stderr,
                                 "%s: sampling frequency (> 0) must follow -F\n",
                                 pname);
                    std::exit(1);
                }
                break;
            case 'h':   // print usage summary and quit
                help();
                std::exit(0);
                break;
            case 'r':   // record name follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: record name must follow -r\n",
                                 pname);
                    std::exit(1);
                }
                record = argv[i];
                break;
            case 'T':   // data are times of occurrence, not RR intervals
                Tflag = 1;
                break;
            case 'x':   // multiplier to convert input to sample intervals
                if (++i >= argc || (xfactor = std::atof(argv[i])) <= 0.0) {
                    std::fprintf(stderr,
                        "%s: an input multiplier (> 0) must follow -x\n",
                        pname);
                    std::exit(1);
                }
                break;
            case 'w':   // copy annotation types from second column of input
                wflag = 1;
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
    if (record == nullptr || ainame == nullptr) {
        help();
        std::exit(1);
    }

    // sampfreq is likely to fail, since the header probably doesn't exist.
    // Suppress its error message.
    wfdbquiet();
    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz,
    // as legacy mode does); -F specifies one if the record header does not.
    WFDB_Frequency f;
    if ((f = sampfreq(record)) <= 0.0) {
        wfdbverbose();  // re-enable error reporting
        if (sps == 0.0 && wfdbx_get_legacy())
            sps = WFDB_DEFFREQ;
        else if (sps == 0.0) {
            std::fprintf(stderr,
                         "%s: sampling frequency of record %s is not specified "
                         "(use -F)\n", pname, record);
            std::exit(1);
        }
        setsampfreq(sps);
        // no header: create one (the C program: in any case)
        if ((f < 0.0 || wfdbx_get_legacy()) && newheader(record) < 0)
            std::exit(2);
    } else {
        wfdbverbose();  // re-enable error reporting
        if (sps != 0.0)
            std::fprintf(stderr,
                "%s (warning): -F option ignored (using %g for sampling frequency)\n",
                pname, sampfreq(nullptr));
    }

    ai.name = ainame;
    ai.stat = WFDB_WRITE;
    if (annopen(record, &ai, 1) < 0)    // open annotation file
        std::exit(3);
    annot.anntyp = NORMAL;

    // Read input, write an annotation for each line beginning with a
    // positive number.
    while (std::fgets(line, sizeof(line), stdin) != nullptr) {
        if (!wflag) {   // write all annotations as NORMAL
            if (std::sscanf(line, "%lf", &rr) == 0) continue;
        } else {        // copy annotation type from input
            static char astring[MAXLINELEN];

            if (std::sscanf(line, "%lf%s", &rr, astring) < 2) continue;
            if ((annot.anntyp = static_cast<char>(strann(astring))) == NOTQRS)
                continue;
        }
        if (rr <= 0.0)
            continue;
        else if (Tflag)
            t = rr * xfactor;
        else
            t += rr * xfactor;
        annot.time = static_cast<WFDB_Time>(t + 0.5);
        (void)putann(0, &annot);
    }

    // Flush buffered output.
    wfdbquit();
    std::exit(0);
}
