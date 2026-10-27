// rdsamp.cpp: print an arbitrary number of samples from each signal.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of app/rdsamp.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency or gain: the
// sampling frequency is required for time arguments, time columns and XML
// output (-X), and the gain of each selected signal for physical units (-p,
// -P) (the original assumed 250 Hz and 200 adu/mV); unspecified units are
// shown as "nd" (the original showed "mV"); --legacy, as the first argument,
// restores the original behavior. Each change is marked "wfdb-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/rdsamp.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2010 George B. Moody; revised 2017-2020 by
//   Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// The output is identical to that of the C program.  Samples are read in
// blocks with getvecs() (equivalent to repeated getvec() calls) except when
// the time column is printed with timstr() or mstimstr(), whose results could
// depend on library state changed while reading (e.g., at the start of a new
// segment); raw sample values are formatted without printf (with identical
// results) for speed.

#include <charconv>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

// values for timeunits
#define SECONDS     1
#define MINUTES     2
#define HOURS       3
#define TIMSTR      4
#define MSTIMSTR    5
#define SHORTTIMSTR 6
#define HHMMSS      7
#define SAMPLES     8

#define WFDBXMLPROLOG "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" \
    "<?xml-stylesheet type=\"text/xsl\"" \
    " href=\"wfdb.xsl\"?>\n" \
    "<!DOCTYPE wfdbsampleset PUBLIC \"-//PhysioNet//DTD WFDB 1.0//EN\"" \
    " \"http://physionet.org/physiobank/database/XML/wfdb.dtd\">\n"

// Widths of the columns of tab-separated output (as in the C format strings
// "%15s", "\t%7s", and "\t%15s"): the time column, and the sample columns
// in standard and in high-precision (-P) output.
constexpr int TCOLW = 15, VCOLW = 7, HPCOLW = 15;
constexpr int CHUNK = 4096;     // frames read at a time with getvecs()

static const char *pname;

// ---------------------------------------------------------------------------
// Buffered standard output

namespace {

class Output {
public:
    Output() : buf_(BUFSIZE) {}
    ~Output() { flush(); }

    void flush()
    {
        if (n_) std::fwrite(buf_.data(), 1, n_, stdout);
        n_ = 0;
    }

    void put(const char *s, size_t len)
    {
        if (n_ + len > BUFSIZE) {
            flush();
            if (len > BUFSIZE) {
                std::fwrite(s, 1, len, stdout);
                return;
            }
        }
        std::memcpy(buf_.data() + n_, s, len);
        n_ += len;
    }

    void puts(const char *s) { put(s, std::strlen(s)); }

    void putc(char c)
    {
        if (n_ + 1 > BUFSIZE) flush();
        buf_[n_++] = c;
    }

#if defined(__GNUC__)
    __attribute__((format(printf, 2, 3)))
#endif
    void printf(const char *format, ...)
    {
        va_list ap;
        if (BUFSIZE - n_ < PRINTF_RESERVE) flush();
        va_start(ap, format);
        int k = std::vsnprintf(buf_.data() + n_, BUFSIZE - n_, format, ap);
        va_end(ap);
        if (k < 0) return;
        if (static_cast<size_t>(k) < BUFSIZE - n_) {
            n_ += k;
            return;
        }
        std::string s(k + 1, '\0');
        va_start(ap, format);
        std::vsnprintf(&s[0], k + 1, format, ap);
        va_end(ap);
        put(s.data(), k);
    }

    // Equivalent of printf("<lead>%<width>.<prec>f", x) (lead may be 0).
    void fixed(char lead, double x, int width, int prec)
    {
        char tmp[400];
        char *p = tmp + 1;
#if defined(__cpp_lib_to_chars) && __cpp_lib_to_chars >= 201611L
        std::to_chars_result r = std::to_chars(p, tmp + sizeof(tmp), x,
                                               std::chars_format::fixed, prec);
        if (r.ec != std::errc()) {
            if (lead) putc(lead);
            printf("%*.*f", width, prec, x);
            return;
        }
        size_t len = r.ptr - p;
#else
        int k = std::snprintf(p, sizeof(tmp) - 1, "%.*f", prec, x);
        if (k < 0 || static_cast<size_t>(k) >= sizeof(tmp) - 1) {
            if (lead) putc(lead);
            printf("%*.*f", width, prec, x);
            return;
        }
        size_t len = k;
#endif
        size_t pad = len < static_cast<size_t>(width) ? width - len : 0;
        if (n_ + len + pad + 1 > BUFSIZE) flush();
        if (lead) buf_[n_++] = lead;
        while (pad--) buf_[n_++] = ' ';
        std::memcpy(buf_.data() + n_, p, len);
        n_ += len;
    }

    // Equivalent of printf("<lead>%<width>lld", v) (lead may be 0).
    void integer(char lead, long long v, int width)
    {
        char tmp[32];
        char *e = tmp + sizeof(tmp), *p = e;
        unsigned long long u = v < 0 ? 0ULL - static_cast<unsigned long long>(v)
                                     : static_cast<unsigned long long>(v);
        do {
            *--p = static_cast<char>('0' + u % 10);
            u /= 10;
        } while (u);
        if (v < 0) *--p = '-';
        while (e - p < width) *--p = ' ';
        if (lead) *--p = lead;
        size_t len = e - p;
        if (n_ + len > BUFSIZE) flush();
        std::memcpy(buf_.data() + n_, p, len);
        n_ += len;
    }

private:
    static constexpr size_t BUFSIZE = 1 << 16;
    // Space left free before printf(), enough for any of its uses here
    static constexpr size_t PRINTF_RESERVE = 512;
    std::vector<char> buf_;
    size_t n_ = 0;
};

Output out;

} // namespace

// Escape quotes and backslashes for CSV column headings.  (The C version of
// this function does not terminate for most strings that contain these
// characters; see docs/KNOWN_C_BEHAVIORS.md.)
static std::string escapify(const char *s)
{
    std::string r;
    for (; *s; s++) {
        if (*s == '\'' || *s == '\\') r += '\\';
        r += *s;
    }
    return r;
}

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

static const char *help_strings[] = {
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -c          use CSV (comma-separated value) output format",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -l INTERVAL truncate output after the specified time interval (hh:mm:ss)",
    " -p          print times and samples in physical units (default: raw units)",
    " -P          same as -p, but with greater precision",
    "              -p and -P may be followed by a character to choose a time",
    "              format;  choices are:",
    "  -pd (or -Pd)  print time of day and date if known",
    "  -pe (or -Pe)  print elapsed time as <hours>:<minutes>:<seconds>",
    "  -ph (or -Ph)  print elapsed time in hours",
    "  -pm (or -Pm)  print elapsed time in minutes",
    "  -ps (or -Ps)  print elapsed time in seconds",
    "  -pS (or -PS)  print elapsed time in sample intervals",
    " -s SIGNAL [SIGNAL ...]  print only the specified signal(s)",
    " -S SIGNAL   search for a valid sample of the specified SIGNAL at or after",
    "\t\tthe time specified with -f, and begin printing then",
    " -t TIME     stop at specified time",
    " -v          print column headings",
    " -X          output in WFDB-XML format",
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
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    const char *record = nullptr, *search = nullptr;
    const char *invalid = "", *snfmt = "", *tnfmt = "", *tufmt = "",
               *vfmt = "";
    char speriod[16], tustr[21];
    int cflag = 0, highres = 0, i, isiglist = 0, nsig, nosig = 0, pflag = 0, s,
        timeunits = SECONDS, vflag = 0, xflag = 0;
    std::vector<int> sig;
    WFDB_Frequency freq;
    std::vector<WFDB_Siginfo> si;
    WFDB_Time from = 0L, maxl = 0L, to = 0L;

    pname = prog_name(argv[0]);
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i] + 1)) {
            case 'c':   // output in CSV format
                cflag = 1;
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
            case 'H':   // select high-resolution mode
                highres = 1;
                break;
            case 'l':   // maximum length of output follows
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: max output length must follow -l\n",
                                 pname);
                    std::exit(1);
                }
                maxl = i;
                break;
            case 'P':   // output in high-precision physical units
                ++pflag;
                // fall through
            case 'p':   // output in physical units specified
                ++pflag;
                if (*(argv[i] + 2) == 'd') timeunits = TIMSTR;
                else if (*(argv[i] + 2) == 'e') timeunits = HHMMSS;
                else if (*(argv[i] + 2) == 'h') timeunits = HOURS;
                else if (*(argv[i] + 2) == 'm') timeunits = MINUTES;
                else if (*(argv[i] + 2) == 'S') timeunits = SAMPLES;
                else timeunits = SECONDS;
                break;
            case 'r':   // record name
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: record name must follow -r\n",
                                 pname);
                    std::exit(1);
                }
                record = argv[i];
                break;
            case 's':   // signal list follows
                isiglist = i + 1;   // index of first argument with a signal #
                while (i + 1 < argc && *argv[i + 1] != '-') {
                    i++;
                    nosig++;        // number of elements in signal list
                }
                if (nosig == 0) {
                    std::fprintf(stderr, "%s: signal list must follow -s\n",
                                 pname);
                    std::exit(1);
                }
                break;
            case 'S':   // search for valid sample of specified signal
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: signal name or number must follow -S\n",
                                 pname);
                    std::exit(1);
                }
                search = argv[i];
                break;
            case 't':   // end time
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: time must follow -t\n", pname);
                    std::exit(1);
                }
                to = i;
                break;
            case 'v':   // verbose output -- include column headings
                vflag = 1;
                break;
            case 'X':   // output in WFDB-XML format
                xflag = cflag = vflag = 1;  // CSV inside an XML wrapper
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
    if (record == nullptr) {
        help();
        std::exit(1);
    }
    if ((nsig = isigopen(record, nullptr, 0)) <= 0) std::exit(2);
    int navail = nsig;
    si.resize(nsig);
    if ((nsig = isigopen(record, si.data(), nsig)) <= 0) std::exit(2);
    if (wfdbx_get_legacy())     // wfdb-x: legacy mode (original behavior)
        for (i = 0; i < nsig; i++)
            if (si[i].gain == 0.0) si[i].gain = WFDB_DEFGAIN;
    if (highres) setgvmode(WFDB_HIGHRES);
    freq = sampfreq(nullptr);
    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    // the header did not specify one, as legacy mode does).
    if (!wfdbx_get_legacy() && freq <= 0. &&
        ((from > 0L && wfdbx_time_needs_freq(argv[from])) ||
         (to > 0L && wfdbx_time_needs_freq(argv[to])) ||
         (maxl > 0L && wfdbx_time_needs_freq(argv[maxl])) ||
         xflag || (pflag && (timeunits != SAMPLES || vflag)))) {
        std::fprintf(stderr,
                     "%s: sampling frequency of record %s is not specified\n",
                     pname, record);
        std::exit(2);
    }
    if (from > 0L && (from = strtim(argv[from])) < 0L) from = -from;
    if (isigsettime(from) < 0) std::exit(2);
    if (to > 0L && (to = strtim(argv[to])) < 0L) to = -to;
    // number of samples returned by getvec
    int nvec = nsig;
    if (nosig) {    // print samples only from specified signals
        sig.resize(nosig);
        for (i = 0; i < nosig; i++) {
            if ((s = findsig(argv[isiglist + i])) < 0) {
                std::fprintf(stderr, "%s: can't read signal '%s'\n", pname,
                             argv[isiglist + i]);
                std::exit(2);
            }
            sig[i] = s;
        }
        nsig = nosig;
    } else {        // print samples from all signals
        sig.resize(nsig);
        for (i = 0; i < nsig; i++) sig[i] = i;
    }

    // wfdb-x: no default gain (the C program assumed 200 adu/mV for
    // uncalibrated signals, as legacy mode does).
    if (pflag && !wfdbx_get_legacy())
        for (i = 0; i < nsig; i++)
            if (si[sig[i]].gain == 0.0) {
                std::fprintf(stderr,
                             "%s: signal %d of record %s is uncalibrated\n",
                             pname, sig[i], record);
                std::exit(2);
            }

    // Reset 'from' if a search was requested.
    if (search &&
        ((s = findsig(search)) < 0 || (from = tnextvec(s, from)) < 0)) {
        std::fprintf(stderr, "%s: can't read signal '%s'\n", pname, search);
        std::exit(2);
    }

    // Reset 'to' if a duration limit was specified.
    if (maxl > 0L && (maxl = strtim(argv[maxl])) < 0L) maxl = -maxl;
    if (maxl && (to == 0L || to > from + maxl)) to = from + maxl;

    // Adjust timeunits if starting time or date is undefined.
    if (timeunits == TIMSTR) {
        std::string p = timstr(0L);
        if (p[0] != '[') timeunits = HHMMSS;
        else if (std::strlen(p.c_str()) < 16)   // "[hh:mm:ss.mmm]": no date
            timeunits = SHORTTIMSTR;
        else if (freq > 1.0) timeunits = MSTIMSTR;
    }
    if (timeunits == HOURS) freq *= 3600.;
    else if (timeunits == MINUTES) freq *= 60.;

    // Set formats for output.
    if (cflag) {    // CSV output selected
        snfmt = ",'%s'";
        if (pflag) {    // output in physical units
            switch (timeunits) {
            case SAMPLES:
                tnfmt = "'sample interval'";
                std::snprintf(tustr, sizeof(tustr), "'%g sec'", 1. / freq);
                tufmt = tustr;
                break;
            case SHORTTIMSTR:
                tnfmt = "'Time'";
                tufmt = "'hh:mm:ss.mmm'";
                break;
            case TIMSTR:
                tnfmt = "'Time and date'";
                tufmt = "'hh:mm:ss dd/mm/yyyy'";
                break;
            case MSTIMSTR:
                tnfmt = "'Time and date'";
                tufmt = "'hh:mm:ss.mmm dd/mm/yyyy'";
                break;
            case HHMMSS:
                tnfmt = "'Elapsed time'";
                tufmt = "'hh:mm:ss.mmm'";
                break;
            case HOURS:
                tnfmt = "'Elapsed time'";
                tufmt = "'hours'";
                break;
            case MINUTES:
                tnfmt = "'Elapsed time'";
                tufmt = "'minutes'";
                break;
            default:
            case SECONDS:
                tnfmt = "'Elapsed time'";
                tufmt = "'seconds'";
                break;
            }
            invalid = ",-";
            if (pflag > 1)  // output in high-precision physical units
                vfmt = ",%.8lf";
            else
                vfmt = ",%.3lf";
        } else {        // output in raw units
            tnfmt = "'sample #'";
        }
    } else {    // output in tab-separated columns selected
        if (pflag) {    // output in physical units
            switch (timeunits) {
            case SAMPLES:
                tnfmt = "sample interval";
                std::snprintf(speriod, sizeof(speriod), "(%g", 1. / freq);
                speriod[10] = '\0';     // at most 10 characters, as in C
                std::snprintf(tustr, sizeof(tustr), "%10s sec)", speriod);
                tufmt = tustr;
                break;
            case SHORTTIMSTR:
                tnfmt = "     Time";
                tufmt = "(hh:mm:ss.mmm)";
                break;
            case TIMSTR:
                tnfmt = "   Time      Date    ";
                tufmt = "(hh:mm:ss dd/mm/yyyy)";
                break;
            case MSTIMSTR:
                tnfmt = "      Time      Date    ";
                tufmt = "(hh:mm:ss.mmm dd/mm/yyyy)";
                break;
            case HHMMSS:
                tnfmt = "   Elapsed time";
                tufmt = "   hh:mm:ss.mmm";
                break;
            case HOURS:
                tnfmt = "   Elapsed time";
                tufmt = "        (hours)";
                break;
            case MINUTES:
                tnfmt = "   Elapsed time";
                tufmt = "      (minutes)";
                break;
            default:
            case SECONDS:
                tnfmt = "   Elapsed time";
                tufmt = "      (seconds)";
                break;
            }
            if (pflag > 1) {    // output in high-precision physical units
                snfmt = "\t%15s";
                invalid = "\t              -";
                vfmt = "\t%15.8lf";
            } else {
                snfmt = "\t%7s";
                invalid = "\t      -";
                vfmt = "\t%7.3lf";
            }
        } else {    // output in raw units
            snfmt = "\t%7s";
            tnfmt = "       sample #";
        }
    }

    // Print WFDB-XML prolog if '-X' option selected.
    if (xflag) {
        out.puts(WFDBXMLPROLOG);
        out.printf("<wfdbsampleset>\n"
                   "<samplingfrequency>%g</samplingfrequency>\n"
                   "<signals>%d</signals>\n<description>",
                   freq, nsig);
    }
    // Print column headers if '-v' option selected.
    if (vflag) {
        out.printf("%s", tnfmt);

        for (i = 0; i < nsig; i++) {
            // Check if a default signal description was provided by looking
            // for the string ", signal " in the desc field.  If so, replace
            // it with a shorter string.
            std::string d = si[sig[i]].desc.value_or("");
            if (std::strstr(d.c_str(), ", signal "))
                d = "sig " + std::to_string(sig[i]);
            const char *p = d.c_str();
            std::string e;
            if (cflag == 0) {
                size_t l = std::strlen(p);
                if (pflag > 1) {
                    if (l > HPCOLW) p += l - HPCOLW;
                } else {
                    if (l > VCOLW) p += l - VCOLW;
                }
            } else {
                e = escapify(p);
                p = e.c_str();
            }
            out.printf(snfmt, p);
        }
        if (xflag) out.puts("</description>");
        out.puts("\n");
    }

    std::vector<WFDB_Sample> vbuf(static_cast<size_t>(CHUNK) *
                                  (nvec > navail ? nvec : navail) + 1);

    // Print data in physical units if '-p' option selected.
    if (pflag) {
        // Print units as a second line of column headers if '-v' selected.
        if (vflag) {
            if (xflag) out.puts("<units>");
            out.printf("%s", tufmt);

            for (i = 0; i < nsig; i++) {
                // wfdb-x: unspecified units are shown as "nd" (C, legacy
                // mode: mV)
                std::string u = si[sig[i]].units ? *si[sig[i]].units
                                : wfdbx_get_legacy() ? "mV" : "nd";
                const char *p = u.c_str();
                if (cflag == 0) {
                    // "(units)", truncated to fit the column
                    char ustring[HPCOLW + 1];
                    int len = static_cast<int>(std::strlen(p));
                    if (pflag > 1) {
                        if (len > HPCOLW - 2) len = HPCOLW - 2;
                    } else if (len > VCOLW - 2)
                        len = VCOLW - 2;
                    ustring[0] = '(';
                    std::strncpy(ustring + 1, p, len);
                    ustring[len + 1] = '\0';
                    out.printf(pflag > 1 ? "\t%14s)" : "\t%6s)", ustring);
                } else {
                    out.printf(",'%s'", escapify(p).c_str());
                }
            }
            if (xflag) out.puts("</units>");
            out.puts("\n");
        }

        if (xflag) out.puts("<samplevectors>\n");
        // Frames are read in blocks unless timstr() or mstimstr() is used.
        bool block = timeunits == SAMPLES || timeunits == SECONDS ||
                     timeunits == MINUTES || timeunits == HOURS;
        // Samples are printed with out.fixed(), the equivalent of printf(vfmt).
        const char vlead = cflag ? ',' : '\t';
        const int vprec = pflag > 1 ? 8 : 3;
        const int vwidth = cflag ? 0 : (pflag > 1 ? HPCOLW : VCOLW);
        (void)vfmt;
        while (to == 0L || from < to) {
            long long k = block ? CHUNK : 1;
            if (to != 0L && to - from < k) k = to - from;
            long long m = block ? getvecs(vbuf.data(), k)
                                : (getvec(vbuf.data()) >= 0 ? 1 : 0);
            for (long long f = 0; f < m; f++) {
                const WFDB_Sample *v = vbuf.data() + f * nvec;
                if (cflag == 0) {
                    switch (timeunits) {
                    case TIMSTR:
                        out.puts(timstr(-from).c_str());
                        break;
                    case SHORTTIMSTR:
                    case MSTIMSTR:
                        out.puts(mstimstr(-from).c_str());
                        break;
                    case HHMMSS:
                        out.printf("%*s", TCOLW, from == 0L ? "0:00.000" :
                                   mstimstr(from).c_str());
                        break;
                    case SAMPLES:
                        out.integer(0, from, TCOLW);
                        break;
                    default:
                    case SECONDS:
                        out.fixed(0, static_cast<double>(from) / freq, TCOLW, 3);
                        break;
                    case MINUTES:
                        out.fixed(0, static_cast<double>(from) / freq, TCOLW, 5);
                        break;
                    case HOURS:
                        out.fixed(0, static_cast<double>(from) / freq, TCOLW, 7);
                        break;
                    }
                } else {
                    std::string ts;
                    const char *p;
                    switch (timeunits) {
                    case TIMSTR:
                        ts = timstr(-from);
                        for (p = ts.c_str(); *p == ' '; p++)
                            ;
                        out.printf("'%s'", p);
                        break;
                    case SHORTTIMSTR:
                    case MSTIMSTR:
                        ts = mstimstr(-from);
                        for (p = ts.c_str(); *p == ' '; p++)
                            ;
                        out.printf("'%s'", p);
                        break;
                    case HHMMSS:
                        if (from == 0L)
                            out.puts("'0:00.000'");
                        else {
                            ts = mstimstr(from);
                            for (p = ts.c_str(); *p == ' '; p++)
                                ;
                            out.printf("'%s'", p);
                        }
                        break;
                    case SAMPLES:
                        out.integer(0, from, 0);
                        break;
                    default:
                    case SECONDS:
                        out.fixed(0, static_cast<double>(from) / freq, 0, 3);
                        break;
                    case MINUTES:
                        out.fixed(0, static_cast<double>(from) / freq, 0, 5);
                        break;
                    case HOURS:
                        out.fixed(0, static_cast<double>(from) / freq, 0, 7);
                        break;
                    }
                }

                from++;
                for (i = 0; i < nsig; i++) {
                    if (v[sig[i]] != WFDB_INVALID_SAMPLE)
                        out.fixed(vlead, (static_cast<double>(v[sig[i]]) -
                                          si[sig[i]].baseline) /
                                             si[sig[i]].gain,
                                  vwidth, vprec);
                    else
                        out.puts(invalid);
                }
                out.putc('\n');
            }
            if (m < k) break;
        }
    }

    else {  // output in raw units
        if (xflag) out.puts("<samplevectors>\n");
        const char vlead = cflag ? ',' : '\t';
        const int twidth = cflag ? 0 : TCOLW, vwidth = cflag ? 0 : VCOLW;
        while (to == 0L || from < to) {
            long long k = CHUNK;
            if (to != 0L && to - from < k) k = to - from;
            long long m = getvecs(vbuf.data(), k);
            for (long long f = 0; f < m; f++) {
                const WFDB_Sample *v = vbuf.data() + f * nvec;
                out.integer(0, from++, twidth);
                for (i = 0; i < nsig; i++) out.integer(vlead, v[sig[i]], vwidth);
                out.putc('\n');
            }
            if (m < k) break;
        }
    }

    if (xflag)  // print trailer if WFDB-XML output was selected
        out.puts("</samplevectors>\n</wfdbsampleset>\n");

    out.flush();
    wfdbquit();
    std::exit(0);
}
