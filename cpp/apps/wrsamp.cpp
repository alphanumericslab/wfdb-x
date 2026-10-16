// wrsamp.cpp: select fields or columns from a file and generate a WFDB record
// (C++ port of app/wrsamp.c)
//
// Copyright (C) 1993-2014 George B. Moody (original C program, app/wrsamp.c;
// revised 2020 by Benjamin Moody).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).
//
// Where the C program's behavior is undefined (input lines that end with a
// field separator, lines with fewer fields than the selected columns), the
// behavior described in docs/KNOWN_C_BEHAVIORS.md is used.

#include <climits>
#include <cstdint>
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
static unsigned int ncols = 0;
static unsigned int nosig = 0;

static cemul::GlibcRand rng;   // glibc's rand(), for platform-independent dither

// The following definition yields dither with a triangular PDF in (-1,1).
static double dither()
{
    double a = static_cast<double>(rng.rand());
    double b = static_cast<double>(rng.rand());
    return (a + b) / cemul::GlibcRand::RAND_MAX_ - 1.0;
}

// Read a line delimited by rsep (an unterminated last line is discarded).
// Returns nullptr at the end of the input.  As in C, the line is a C string
// (it ends at its first null character, if any).
static const char *read_line(std::FILE *ifile, char rsep)
{
    static std::string buf;
    int c;

    buf.clear();
    while ((c = getc(ifile)) != rsep) {
        if (c == EOF) return nullptr;
        buf.push_back(static_cast<char>(c));
    }
    return buf.c_str();
}

static int line_has_alpha(const char *line)
{
    const char *p;

    if (line)
        for (p = line; *p; p++) {
            if (*p == 'e' || *p == 'E') {
                // might be a number in printf %f form: ignore 'e' or 'E' if
                // followed by a digit or a sign
                p++;
                if (static_cast<signed char>(*p) <= '9' || *p == '-' || *p == '+') {
                    if (*p == '\0') break;
                    continue;
                }
            }
            if (('A' <= *p && *p <= 'Z') || ('a' <= *p && *p <= 'z'))
                return 1;
        }
    return 0;
}

static int line_has_tab(const char *line)
{
    if (line)
        for (const char *p = line; *p; p++)
            if (*p == '\t') return 1;
    return 0;
}

// Parse a line into tokens (as parseline() in wrsamp.c, with consecutive
// delimiters collapsed and '\\' as the escape character).  Quoted tokens
// ('...', "...", or <...>) may contain delimiters.
static std::vector<std::string> parseline(const std::string &line,
                                          const char *delim)
{
    const char esc = '\\';
    std::vector<std::string> tokens;
    size_t n = line.size(), p = 0;

    while (p < n) {
        while (p < n && std::strchr(delim, line[p])) p++;
        if (p >= n) break;
        char q = '\0';
        if (line[p] == '"' || line[p] == '\'')
            q = line[p++];
        else if (line[p] == '<') {
            p++;
            q = '>';
        }
        std::string tok;
        while (p < n && (q || !std::strchr(delim, line[p]))) {
            char c = line[p];
            if (esc && c == esc) {
                if (p + 1 >= n) break;  // escape at end of line -- ignore
                tok += line[p + 1];
                p += 2;
                continue;
            }
            if (c == q) {   // found the closing quote
                p++;
                q = '\0';
                break;
            }
            tok += c;
            p++;
        }
        tokens.push_back(tok);
    }
    return tokens;
}

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

static const char *help_strings[] = {
    "usage: %s [OPTIONS ...] [COLUMN ...]\n",
    "where COLUMN selects a field to be copied (leftmost field is column 0),",
    "and OPTIONS may include:",
    " -c          check that each input line contains the same number of fields",
    " -d          add dither to the input",
    " -f N        start copying with line N (default: 0)",
    " -F FREQ     specify frequency to be written to header file (required",
    "              with -o)",
    " -G GAIN     specify gain(s) to be written to header file (required with",
    "              -o; 0 means uncalibrated)",
    " -h          print this usage summary",
    " -i FILE     read input from FILE (default: standard input)",
    " -o RECORD   save output in RECORD.dat, and generate a header file for",
    "              RECORD (default: write to standard output in format 16, do",
    "              not generate a header file)",
    " -O FORMAT   save output in the specified FORMAT (default: 16)",
    " -r RSEP     interpret RSEP as the input line separator (default: linefeed)",
    " -R BITS     specify ADC resolution(s) in bits (required with -o)",
    " -s FSEP     interpret any character in FSEP as an input field separator",
    "             (default: space, tab, carriage-return, or comma)  ",
    " -t N        stop copying at line N (default: end of input file)",
    " -U UNITS    specify units (required with -o for calibrated signals, unless",
    "              the input gives them)",
    " -x SCALE    multiply inputs by SCALE factor(s) (default: 1)",
    " -z          don't copy column 0 unless explicitly specified",
    "",
    "The input is a text file with a sample of each signal on each line. Samples",
    "can be separated by tabs, spaces, commas, or any combination of these.",
    "Consecutive separators are equivalent to single separators.",
    "",
    "To specify different GAIN or SCALE values for each output signal, provide",
    "a quoted list of values, e.g., -G \"100 50\" defines the gain for signal 0",
    "as 100, and the gain for signal 1 (and any additional signals) as 50.",
    "",
    "If the first input line contains any alphabetic characters, it is assumed",
    "to contain column headings, which are copied as signal descriptions into",
    "RECORD.hea.  If the second input line also contains alphabetic characters,",
    "it is assumed to specify the physical units for each column, which are",
    "copied as units strings into RECORD.hea.  The first line containing samples",
    "is line 0.",
    "",
    "If no COLUMN is specified, all fields are copied in order; column 0 can be",
    "omitted in this case by using the '-z' option.",
    nullptr
};

// wfdb-x: the help text of the original program, printed in legacy mode
static const char *legacy_help_strings[] = {
    "usage: %s [OPTIONS ...] [COLUMN ...]\n",
    "where COLUMN selects a field to be copied (leftmost field is column 0),",
    "and OPTIONS may include:",
    " -c          check that each input line contains the same number of fields",
    " -d          add dither to the input",
    " -f N        start copying with line N (default: 0)",
    " -F FREQ     specify frequency to be written to header file (default: 250)",
    " -G GAIN     specify gain(s) to be written to header file (default: 200)",
    " -h          print this usage summary",
    " -i FILE     read input from FILE (default: standard input)",
    " -o RECORD   save output in RECORD.dat, and generate a header file for",
    "              RECORD (default: write to standard output in format 16, do",
    "              not generate a header file)",
    " -O FORMAT   save output in the specified FORMAT (default: 16)",
    " -r RSEP     interpret RSEP as the input line separator (default: linefeed)",
    " -s FSEP     interpret any character in FSEP as an input field separator",
    "             (default: space, tab, carriage-return, or comma)  ",
    " -t N        stop copying at line N (default: end of input file)",
    " -x SCALE    multiply inputs by SCALE factor(s) (default: 1)",
    " -z          don't copy column 0 unless explicitly specified",
    "",
    "The input is a text file with a sample of each signal on each line. Samples",
    "can be separated by tabs, spaces, commas, or any combination of these.",
    "Consecutive separators are equivalent to single separators.",
    "",
    "To specify different GAIN or SCALE values for each output signal, provide",
    "a quoted list of values, e.g., -G \"100 50\" defines the gain for signal 0",
    "as 100, and the gain for signal 1 (and any additional signals) as 50.",
    "",
    "If the first input line contains any alphabetic characters, it is assumed",
    "to contain column headings, which are copied as signal descriptions into",
    "RECORD.hea.  If the second input line also contains alphabetic characters,",
    "it is assumed to specify the physical units for each column, which are",
    "copied as units strings into RECORD.hea.  The first line containing samples",
    "is line 0.",
    "",
    "If no COLUMN is specified, all fields are copied in order; column 0 can be",
    "omitted in this case by using the '-z' option.",
    nullptr
};

[[noreturn]] static void unrecognized(const char *arg)
{
    std::fprintf(stderr, "%s: unrecognized option %s\n", pname, arg);
    std::exit(1);
}

// wfdb-x: the ADC resolution the C program (and legacy mode) inferred from
// the format.
static int legacy_adcres(int format)
{
    switch (format) {
    case 508:
    case 80: return 8;
    case 310:
    case 311: return 10;
    case 212: return 12;
    case 516:
    case 16:
    case 160:
    case 61: return 16;
    case 524:
    case 24: return 24;
    case 32: return 32;
    default:
        // resolution for unknown future formats
        if (format > 100 && format % 100 > 0 && format % 100 <= 32)
            return format % 100;
        return WFDB_DEFRES;
    }
}

static void help()
{
    // wfdb-x: the original help text in legacy mode
    const char **hs = wfdbx_get_legacy() ? legacy_help_strings : help_strings;

    std::fprintf(stderr, hs[0], pname);
    for (int i = 1; hs[i] != nullptr; i++) {
        std::fprintf(stderr, "%s\n", hs[i]);
        if (i % 23 == 0) {     // pause after each screenful (23 lines)
            char b[5];
            std::fprintf(stderr, "--More--");
            if (std::fgets(b, 5, stdin) == nullptr) b[0] = '\0';
            std::fprintf(stderr, "\033[A\033[2K");  // erase "--More--"
        }
    }
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    const char *gain = "", *line = nullptr, *record = nullptr, *scale = "";
    const char *res = "", *uopt = nullptr;     // wfdb-x: -R and -U
    const char *delim = " \t\r\n,";     // defpmode.delim
    char rsep = '\n', sflag = 0, Xflag = 0;
    std::vector<std::string> dstrings, ustrings;
    bool have_dstrings = false, have_ustrings = false;
    double freq = 0.0;  // wfdb-x: no default frequency
    int dflag = 0, format = 16, i, j, zflag = 0;
    std::FILE *ifile = stdin;
    long t = 0L, t0 = 0L, t1 = 0L;
    std::vector<std::string> ta;

    pname = prog_name(argv[0]);
    if (wfdbx_get_legacy())
        freq = WFDB_DEFFREQ;    // wfdb-x: the default of the C program

    for (i = 1; i < argc && *argv[i] == '-'; i++) {
        switch (*(argv[i] + 1)) {
        case 'c':
            break;
        case 'd':
            dflag = 1;
            rng.srand(0);   // seed for dither RNG
            break;
        case 'f':
            if (++i >= argc || (t0 = std::atol(argv[i])) <= 0L) {
                std::fprintf(stderr, "%s: starting line # must follow -f\n",
                             pname);
                std::exit(1);
            }
            break;
        case 'F':
            if (++i >= argc || (freq = std::atof(argv[i])) <= 0.) {
                std::fprintf(stderr, "%s: sampling frequency must follow -F\n",
                             pname);
                std::exit(1);
            }
            break;
        case 'G':
            if (++i >= argc) {
                std::fprintf(stderr, "%s: gain(s) must follow -G\n", pname);
                std::exit(1);
            }
            gain = argv[i];
            break;
        case 'h':
            help();
            std::exit(1);
            break;
        case 'R':   // wfdb-x: ADC resolution(s) in bits
            if (wfdbx_get_legacy())     // wfdb-x: not in the original
                unrecognized(argv[i]);
            if (++i >= argc) {
                std::fprintf(stderr, "%s: ADC resolution(s) must follow -R\n",
                             pname);
                std::exit(1);
            }
            res = argv[i];
            break;
        case 'U':   // wfdb-x: units
            if (wfdbx_get_legacy())     // wfdb-x: not in the original
                unrecognized(argv[i]);
            if (++i >= argc) {
                std::fprintf(stderr, "%s: units must follow -U\n", pname);
                std::exit(1);
            }
            uopt = argv[i];
            break;
        case 'i':
            if (++i >= argc) {
                std::fprintf(stderr, "%s: input file name must follow -i\n",
                             pname);
                std::exit(1);
            }
            if (ifile != stdin) std::fclose(ifile);
            if (std::strcmp(argv[i], "-") == 0)
                ifile = stdin;
            else if ((ifile = std::fopen(argv[i], "r")) == nullptr) {
                std::fprintf(stderr, "%s: can't read `%s'\n", pname, argv[i]);
                std::exit(2);
            }
            break;
        case 'l':
            if (++i >= argc) --i;
            std::fprintf(stderr, "%s: -l is obsolete, ignored\n", pname);
            break;
        case 'o':
            if (++i >= argc) {
                std::fprintf(stderr, "%s: record name must follow -o\n",
                             pname);
                std::exit(1);
            }
            record = argv[i];
            break;
        case 'O':
            if (++i >= argc) {
                std::fprintf(stderr, "%s: output format must follow -O\n",
                             pname);
                std::exit(1);
            }
            format = std::atoi(argv[i]);
            break;
        case 'r':
            if (++i >= argc) {
                std::fprintf(stderr, "%s: line separator must follow -r\n",
                             pname);
                std::exit(1);
            }
            rsep = argv[i][0];
            break;
        case 's':
            if (++i >= argc) {
                std::fprintf(stderr,
                             "%s: field separator(s) must follow -s\n", pname);
                std::exit(1);
            }
            sflag = 1;
            delim = argv[i];
            break;
        case 't':
            if (++i >= argc || (t1 = std::atol(argv[i])) <= 0L) {
                std::fprintf(stderr, "%s: ending line # must follow -t\n",
                             pname);
                std::exit(1);
            }
            break;
        case 'x':
            if (++i >= argc) {
                std::fprintf(stderr,
                             "%s: scaling factor(s) must follow -x\n", pname);
                std::exit(1);
            }
            scale = argv[i];
            break;
        case 'z':   // ignore column 0
            zflag = 1;
            break;
        default:
            unrecognized(argv[i]);
        }
    }

    // wfdb-x: the sampling frequency, the gains, the ADC resolutions, and the
    // units (of calibrated signals) must be specified when a header is
    // written (the C program assumed 250 Hz, 200 adu/mV, a resolution based
    // on the format, and millivolts), as legacy mode does.
    if (record != nullptr && !wfdbx_get_legacy()) {
        if (freq <= 0.) {
            std::fprintf(stderr,
                         "%s: the sampling frequency must be specified (-F)\n",
                         pname);
            std::exit(1);
        }
        if (*gain == '\0') {
            std::fprintf(stderr, "%s: the gain(s) must be specified (-G)\n",
                         pname);
            std::exit(1);
        }
        if (*res == '\0') {
            std::fprintf(stderr,
                         "%s: the ADC resolution(s) must be specified (-R)\n",
                         pname);
            std::exit(1);
        }
    }

    nosig = argc - i;   // any remaining arguments are column numbers

    // Determine the number of input columns, and (if present) the signal
    // names and the units for each signal.  Start by reading the first line
    // of the input file.
    if ((line = read_line(ifile, rsep)) == nullptr) {
        if (rsep != '\n') {
            if (record == nullptr)
                std::fprintf(stderr,
                             "%s: use -o to specify the output record name",
                             pname);
            else
                std::fprintf(stderr,
                             "%s: no record separators in input\n"
                             "Try specifying a different separator after the "
                             "-r option.\n", pname);
        } else
            std::fprintf(stderr, "%s: no newlines in input\n", pname);
        std::exit(3);
    }
    // Recognize WFDB-XML format if present.
    if (std::strncmp(line, "<?xml ", 6) == 0) {
        Xflag = 1;
        zflag = 1;  // ignore column 0
        do {
            if ((line = read_line(ifile, rsep)) == nullptr) {
                std::fprintf(stderr,
                             "%s: XML input, but no <wfdbsampleset> found\n",
                             pname);
                std::exit(1);
            }
        } while (std::strcmp(line, "<wfdbsampleset>"));
        do {
            if ((line = read_line(ifile, rsep)) == nullptr) {
                std::fprintf(stderr, "%s: empty <wfdbsampleset>\n", pname);
                std::exit(1);
            }
            size_t len = std::strlen(line);
            if (std::strncmp(line, "<samplingfrequency>", 19) == 0)
                std::sscanf(line + 19, "%lf", &freq);
            else if (std::strncmp(line, "<description>", 13) == 0) {
                // strip <description> and </description>
                std::string d = len >= 27 ? std::string(line + 13, len - 27)
                                          : std::string();
                ta = parseline(d, delim);
                dstrings = ta;
                have_dstrings = true;
                ncols = static_cast<unsigned>(ta.size());
            } else if (std::strncmp(line, "<units>", 7) == 0) {
                // strip <units> and </units>
                std::string u = len >= 15 ? std::string(line + 7, len - 15)
                                          : std::string();
                ta = parseline(u, delim);
                ustrings = ta;
                have_ustrings = true;
            }
        } while (std::strcmp(line, "<samplevectors>"));
        if ((line = read_line(ifile, rsep)) == nullptr) {
            std::fprintf(stderr, "%s: empty <wfdbsampleset>\n", pname);
            std::exit(1);
        }
    }

    else {  // non-XML input
        // Unless -s was given, note if line 0 contains any tab characters.
        if (sflag == 0 && line_has_tab(line)) delim = "\t";
        ta = parseline(line, delim);
        ncols = static_cast<unsigned>(ta.size());
        // If it contains any alphabetic characters, save the signal names.
        if (line_has_alpha(line)) {
            have_dstrings = true;
            for (const std::string &tk : ta) {
                size_t k = tk.find_first_not_of(' ');
                dstrings.push_back(k == std::string::npos ? "" : tk.substr(k));
            }
            // Read the second line.
            if ((line = read_line(ifile, rsep)) == nullptr) {
                std::fprintf(stderr, "%s: no data\n", pname);
                std::exit(1);
            }
            // If it has any alphabetic characters, save the unit strings.
            else if (line_has_alpha(line)) {
                ta = parseline(line, delim);
                have_ustrings = true;
                for (const std::string &tk : ta) {
                    size_t k = tk.find_first_not_of(' ');
                    std::string u = k == std::string::npos ? "" : tk.substr(k);
                    if (!u.empty() && u[0] == '(') {
                        char last = u.back();
                        u.erase(0, 1);
                        if (last == ')') u.pop_back();
                    }
                    ustrings.push_back(u);
                }
                // Read the third line.
                if ((line = read_line(ifile, rsep)) == nullptr) {
                    std::fprintf(stderr, "%s: no data\n", pname);
                    std::exit(1);
                }
            }
        }
    }

    // read selected column numbers into fv[...]
    std::vector<int> fv;
    if (nosig) {
        fv.resize(nosig);
        for (i = argc - static_cast<int>(nosig), j = 0; i < argc; i++, j++) {
            if (std::sscanf(argv[i], "%d", &fv[j]) != 1 || fv[j] < 0 ||
                static_cast<unsigned>(fv[j]) >= ncols) {
                std::fprintf(stderr, "%s: unrecognized argument %s\n", pname,
                             argv[i]);
                std::exit(1);
            }
        }
    } else {    // copy all column numbers (or all except 0) into fv[...]
        nosig = ncols - zflag;
        if (nosig > INT_MAX) {
            std::fprintf(stderr, "WFDB: can't allocate (%lu*%lu) bytes for fv\n",
                         static_cast<unsigned long>(nosig),
                         static_cast<unsigned long>(sizeof(int)));
            std::exit(1);
        }
        fv.resize(nosig);
        for (i = 0, j = zflag; i < static_cast<int>(nosig); i++, j++) fv[i] = j;
    }

    std::vector<WFDB_Sample> vout(nosig);
    std::vector<WFDB_Siginfo> si(nosig);
    std::vector<double> scalef(nosig);

    // open the output record
    std::string ofname = record == nullptr ? "-" : std::string(record) + ".dat";

    for (unsigned k = 0; k < nosig; k++) {
        si[k].fname = ofname;
        if (have_dstrings)
            si[k].desc = static_cast<size_t>(fv[k]) < dstrings.size() ?
                dstrings[fv[k]] : std::string();
        else
            si[k].desc = "col " + std::to_string(fv[k]);
        if (uopt) {     // wfdb-x: -U (the last one applies to the rest)
            while (*uopt == ' ') uopt++;
            if (*uopt) {
                const char *q = uopt;
                while (*q && *q != ' ') q++;
                si[k].units = std::string(uopt, q - uopt);
                uopt = q;
            } else
                si[k].units = k == 0 ? std::string() : si[k - 1].units;
        } else if (have_ustrings)
            si[k].units = static_cast<size_t>(fv[k]) < ustrings.size() ?
                ustrings[fv[k]] : std::string();
        else
            si[k].units = std::string();
        si[k].group = 0;
        si[k].fmt = format;
        si[k].spf = 1;
        si[k].bsize = 0;
        // wfdb-x: the ADC resolutions are given by -R (the last one applies
        // to the remaining signals); the C program (and legacy mode) inferred
        // them from the format or assumed WFDB_DEFRES.
        if (wfdbx_get_legacy())
            si[k].adcres = legacy_adcres(format);
        else {
            while (*res == ' ') res++;
            if (std::sscanf(res, "%d", &si[k].adcres) < 1)
                si[k].adcres = (k == 0) ? 0 : si[k - 1].adcres;
            else
                while (*res != '\0' && *res != ' ') res++;
            if (record != nullptr && si[k].adcres < 1) {
                std::fprintf(stderr,
                             "%s: the ADC resolution(s) must be specified (-R)\n",
                             pname);
                std::exit(1);
            }
        }
        si[k].adczero = 0;
        si[k].baseline = 0;
        while (*gain == ' ') gain++;
        if (std::sscanf(gain, "%lf", &si[k].gain) < 1)
            // wfdb-x: C (legacy mode): WFDB_DEFGAIN
            si[k].gain = (k == 0) ? (wfdbx_get_legacy() ? WFDB_DEFGAIN : 0.)
                                  : si[k - 1].gain;
        else
            while (*gain != '\0' && *gain != ' ') gain++;
        // wfdb-x: the units of a calibrated signal must be specified, by -U
        // or by the input (the C program left them out: millivolts).
        if (record != nullptr && !wfdbx_get_legacy() && si[k].gain != 0. &&
            (!si[k].units || si[k].units->empty())) {
            std::fprintf(stderr, "%s: the units must be specified (-U)\n",
                         pname);
            std::exit(1);
        }
        while (*scale == ' ') scale++;
        if (std::sscanf(scale, "%lf", &scalef[k]) < 1)
            scalef[k] = (k == 0) ? 1.0 : scalef[k - 1];
        else
            while (*scale != '\0' && *scale != ' ') scale++;
    }

    // discard any additional lines containing text
    while (line_has_alpha(line)) line = read_line(ifile, rsep);

    // (As in C, the result of osigfopen is compared with an unsigned number,
    // so that errors are not detected here.)
    if (static_cast<unsigned>(osigfopen(si.data(), nosig)) < nosig ||
        setsampfreq(freq) < 0)
        std::exit(2);

    // skip any unwanted samples at the beginning
    for (t = 0; t < t0; t++) line = read_line(ifile, rsep);

    // pick up base time if it's there
    if (zflag && line) {
        if (*line == '[') {
            std::string btime(line + 1, strnlen(line + 1, 23));
            setbasetime(btime.c_str());
        } else if (*line && *(line + 1) == '[') {
            std::string btime(line + 2, strnlen(line + 2, 23));
            setbasetime(btime.c_str());
        }
    }

    // read and copy samples
    while (line != nullptr && (t1 == 0L || t++ < t1)) {
        ta = parseline(line, delim);

        for (unsigned k = 0; k < nosig; k++) {
            double v;
            const char *tok = static_cast<size_t>(fv[k]) < ta.size() ?
                ta[fv[k]].c_str() : "";

            if (std::sscanf(tok, "%lf", &v) == 1) {
                v *= scalef[k];
                if (dflag) v += dither();
                if (v >= 0)
                    vout[k] = d2i(v + 0.5);
                else
                    vout[k] = d2i(v - 0.5);
            } else
                vout[k] = WFDB_INVALID_SAMPLE;
        }
        if (putvec(vout.data()) < 0) break;

        line = read_line(ifile, rsep);
        if (line && Xflag && std::strncmp(line, "</samplevectors>", 16) == 0) {
            if ((line = read_line(ifile, rsep)) != nullptr)
                if (std::strcmp(line, "</wfdbsampleset>"))
                    std::fprintf(stderr,
                                 "%s: (warning) unexpected EOF in XML input\n",
                                 pname);
            break;
        }
    }

    // write the header
    (void)setsampfreq(freq);
    if (record != nullptr) (void)newheader(record);
    wfdbquit();
    std::exit(0);
}
