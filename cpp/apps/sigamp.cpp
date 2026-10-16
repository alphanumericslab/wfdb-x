// sigamp.cpp: measure signal amplitudes
// (C++ port of app/sigamp.c)
//
// Copyright (C) 1991-2009 George B. Moody (original C program, app/sigamp.c;
// revised 2018 by Benjamin Moody).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <wfdbx/ecgcodes.hpp>
#include <wfdbx/ecgmap.hpp>
#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

#define NMAX 300
#define _STRING(X) #X
#define STRING(X) _STRING(X)

// values for timeunits
#define SECONDS     1
#define MINUTES     2
#define HOURS       3
#define TIMSTR      4
#define MSTIMSTR    5
#define SHORTTIMSTR 6
#define HHMMSS      7
#define SAMPLES     8

static const char *pname;
static int namp;
static int nsig;
static int pflag;       // if non-zero, print physical units
static int qflag;       // if non-zero, suppress output of trimmed means
static int timeunits = SECONDS;
static int vflag;       // if non-zero, print individual measurements
static std::vector<int> v0, vmax, vmin, vv;
static std::vector<std::vector<double>> amp;
static std::vector<double> vmean, vsum;
static WFDB_Time dt1, dt2, dtw;
static WFDB_Anninfo ai;
static const char *ainame;
static WFDB_Frequency sfreq;
static std::vector<WFDB_Siginfo> si;
static WFDB_Time from = 0L, to = 0L, t;

static int getrms(WFDB_Time t);
static int getptp(WFDB_Time t);
static void printamp(WFDB_Time t);
static int ampcmp(const void *p1, const void *p2);
static const char *prog_name(const char *s);
static void help();

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    const char *p, *record = nullptr;
    int gvmode = 0, i, j, jlow, jhigh, nmax = NMAX;

    // Interpret command-line arguments.
    pname = prog_name(argv[0]);
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i] + 1)) {
            case 'a':
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: annotator name must follow -a\n", pname);
                    std::exit(1);
                }
                ainame = argv[i];
                break;
            case 'd':
                if (++i >= argc - 1) {
                    std::fprintf(stderr, "%s: DT1 and DT2 must follow -d\n",
                                 pname);
                    std::exit(1);
                }
                // save arg list index, convert arguments to samples later
                // (after record has been opened and sampling frequency is
                // known)
                dt1 = i++;
                break;
            case 'f':
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: start time must follow -f\n",
                                 pname);
                    std::exit(1);
                }
                // save arg list index, convert argument to samples later
                from = i;
                break;
            case 'h':   // help requested
                help();
                std::exit(0);
                break;
            case 'H':   // operate in WFDB_HIGHRES mode
                gvmode = WFDB_HIGHRES;
                break;
            case 'n':
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: number of measurements must follow -n\n",
                                 pname);
                    std::exit(1);
                }
                if ((nmax = std::atoi(argv[i])) < 1) nmax = NMAX;
                break;
            case 'p':
                pflag = 1;
                if (*(argv[i] + 2) == 'd') timeunits = TIMSTR;
                else if (*(argv[i] + 2) == 'e') timeunits = HHMMSS;
                else if (*(argv[i] + 2) == 'h') timeunits = HOURS;
                else if (*(argv[i] + 2) == 'm') timeunits = MINUTES;
                else if (*(argv[i] + 2) == 'S') timeunits = SAMPLES;
                else timeunits = SECONDS;
                break;
            case 'q':
                qflag = 1;
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
                    std::fprintf(stderr, "%s: stop time must follow -t\n",
                                 pname);
                    std::exit(1);
                }
                // save arg list index, convert argument to samples later
                to = i;
                break;
            case 'v':
                vflag = 1;
                break;
            case 'w':
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: window size must follow -w\n",
                                 pname);
                    std::exit(1);
                }
                // save arg list index, convert argument to samples later
                dtw = i;
                break;
            default:
                std::fprintf(stderr, "%s: unrecognized option %s\n", pname,
                             argv[i]);
                std::exit(1);
                break;
            }
        else {
            std::fprintf(stderr, "%s: unrecognized argument %s\n", pname,
                         argv[i]);
            std::exit(1);
            break;
        }
    }
    if (record == nullptr) {
        help();
        std::exit(1);
    }

    // Finish initialization.
    if (gvmode == 0 && (p = std::getenv("WFDBGVMODE")))
        gvmode = std::atoi(p);
    setgvmode(gvmode | WFDB_GVPAD);

    if ((nsig = isigopen(record, nullptr, 0)) <= 0) std::exit(2);
    si.resize(nsig);
    v0.resize(nsig);
    vmax.resize(nsig);
    vmin.resize(nsig);
    vv.resize(nsig);
    amp.resize(nsig);
    vmean.resize(nsig);
    vsum.resize(nsig);
    if (isigopen(record, si.data(), nsig) != nsig) std::exit(2);
    for (i = 0; i < nsig; i++) {
        // wfdb-x: no default gain (the C program assumed 200 adu/mV for
        // uncalibrated signals, as legacy mode does).
        if (wfdbx_get_legacy()) {
            if (si[i].gain == 0.0) si[i].gain = WFDB_DEFGAIN;
        } else if (pflag && si[i].gain == 0.0) {
            std::fprintf(stderr, "%s: signal %d of record %s is uncalibrated\n",
                         pname, i, record);
            std::exit(2);
        }
        amp[i].resize(nmax);
    }
    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz,
    // as legacy mode does); the measurement windows are defined in seconds.
    if ((sfreq = sampfreq(nullptr)) <= 0.0 && wfdbx_get_legacy())
        sfreq = WFDB_DEFFREQ;
    else if (sfreq <= 0.0) {
        std::fprintf(stderr,
                     "%s: sampling frequency of record %s is not specified\n",
                     pname, record);
        std::exit(2);
    }

    // Adjust timeunits if starting time is undefined.
    if (timeunits == TIMSTR || timeunits == HHMMSS) {
        std::string p = timstr(0L);
        if (p[0] != '[') timeunits = HHMMSS;
    }
    if (timeunits == HOURS) sfreq *= 3600.;
    else if (timeunits == MINUTES) sfreq *= 60.;

    if (from > 0L) from = strtim(argv[(int)from]);
    if (to > 0L) to = strtim(argv[(int)to]);
    if (from < 0L) from = -from;
    if (to < 0L) to = -to;
    if (from >= to) to = strtim("e");

    // Collect amplitudes, print them if qflag or vflag set.
    if (ainame) {   // windows are relative to annotations
        WFDB_Annotation annot;

        ai.name = ainame;
        ai.stat = WFDB_READ;
        if (dtw > 0L) {
            std::fprintf(stderr,
                         "%s: -a and -w options cannot be used together;\n",
                         pname);
            std::fprintf(stderr, "  -w option is being ignored\n");
        }
        if (annopen(record, &ai, 1) < 0) std::exit(2);
        if (dt1 == 0L) dt1 = -(dt2 = strtim("0.05"));
        else {
            const char *p = argv[(int)dt1 + 1];

            if (*p == '-') dt2 = -strtim(p + 1);
            else dt2 = strtim(p);
            p = argv[(int)dt1];
            if (*p == '-') dt1 = strtim(p + 1);
            else dt1 = -strtim(p);
            if (dt1 > dt2) {
                WFDB_Time temp = dt1;

                dt1 = dt2; dt2 = temp;
            }
        }
        if (dt1 == dt2) dt2++;
        if (iannsettime(from) < 0) std::exit(2);
        while (getann(0, &annot) == 0 && namp < nmax &&
               (to == 0L || annot.time < to)) {
            if (map1(annot.anntyp) == NORMAL) {
                if (getptp(annot.time) < 0) break;
                if (vflag || qflag) printamp(annot.time);
                namp++;
            }
        }
    } else {        // windows are consecutive nonoverlapping segments
        if (dt1 > 0L) {
            std::fprintf(stderr,
                         "%s: -d option must be used with -a;\n", pname);
            std::fprintf(stderr, "  -d option is being ignored\n");
        }
        if (dtw == 0L || (dtw = strtim(argv[(int)dtw])) <= 0L)
            dtw = strtim("1");
        if (from > 0L && isigsettime(from) < 0L) std::exit(2);
        for (t = from; namp < nmax && (to == 0L || t < to);
             namp++, t += dtw) {
            if (getrms(t) < 0) break;
            if (vflag || qflag) printamp(t);
        }
    }

    // Calculate trimmed means of collected amplitudes unless -q option set.
    if (qflag == 0) {
        jlow = namp / 20;   // exclude the lowest and highest 5%
        jhigh = namp - jlow;
        if (vflag)
            std::printf("Trimmed mean");
        for (i = 0; i < nsig; i++) {
            double a;

            std::qsort(amp[i].data(), namp, sizeof(double), ampcmp);
            for (a = 0.0, j = jlow; j < jhigh; j++)
                a += amp[i][j];
            a /= jhigh - jlow;
            std::printf("\t%g", pflag ? a / si[i].gain : a);
        }
        std::printf("\n");
    }
    std::exit(0);
}

static int getrms(WFDB_Time t)
{
    int i, v;
    WFDB_Time tt;

    if (getvec(vv.data()) < nsig) return (-1);

    for (i = 0; i < nsig; i++) {
        vmean[i] = v0[i] = vv[i];
        vsum[i] = 0.0;
    }

    for (tt = 1; tt < dtw; tt++) {
        if (getvec(vv.data()) < nsig) return (-1);
        for (i = 0; i < nsig; i++)
            vmean[i] += vv[i];
    }

    if (isigsettime(t) < 0 || getvec(vv.data()) < nsig) return (-1);

    // The quantity vv[i] - v0[i] is normally zero, but may be non-zero if
    // the signals are stored in difference format (since isigsettime may
    // introduce a DC error in this case).  In the calculation of vmean[i]
    // below, this quantity is used to correct any such error.
    for (i = 0; i < nsig; i++) {
        vmean[i] = vmean[i] / dtw + vv[i] - v0[i];
        v = static_cast<int>(vv[i] - vmean[i]);
        vsum[i] += (double)v * v;
    }

    for (tt = 1; tt < dtw; tt++) {
        if (getvec(vv.data()) < nsig) return (-1);
        for (i = 0; i < nsig; i++) {
            v = static_cast<int>(vv[i] - vmean[i]);
            vsum[i] += (double)v * v;
        }
    }

    for (i = 0; i < nsig; i++)
        amp[i][namp] = std::sqrt(vsum[i] / dtw);

    return (0);
}

static int getptp(WFDB_Time t)
{
    int i;
    WFDB_Time tt;

    if (isigsettime(t + dt1) < 0) return (-1);

    if (getvec(vmin.data()) < nsig) return (-1);

    for (i = 0; i < nsig; i++)
        vmax[i] = vmin[i];

    for (tt = dt1; tt < dt2; tt++) {
        if (getvec(vv.data()) < nsig) return (-1);
        for (i = 0; i < nsig; i++) {
            if (vv[i] < vmin[i]) vmin[i] = vv[i];
            else if (vv[i] > vmax[i]) vmax[i] = vv[i];
        }
    }

    for (i = 0; i < nsig; i++)
        amp[i][namp] = vmax[i] - vmin[i];

    return (0);
}

static void printamp(WFDB_Time t)
{
    int i;

    switch (timeunits) {
    case TIMSTR:  std::printf("%s", mstimstr(-t).c_str()); break;
    case HHMMSS:  std::printf("%s", mstimstr(t).c_str()); break;
    case SAMPLES: std::printf("%lld", t); break;
    default:      std::printf("%lf", t / sfreq); break;
    }
    for (i = 0; i < nsig; i++)
        std::printf("\t%g", pflag ? amp[i][namp] / si[i].gain :
                    amp[i][namp]);
    std::printf("\n");
}

static int ampcmp(const void *a, const void *b)
{
    const double *p1 = static_cast<const double *>(a);
    const double *p2 = static_cast<const double *>(b);

    if (*p1 > *p2) return (1);
    else if (*p1 == *p2) return (0);
    else return (-1);
}

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

static const char *help_strings[] = {
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where OPTIONS may include any of:",
    " -a ANN      specify annotator, measure amplitudes near QRS annotations",
    " -d DT1 DT2  set measurement window relative to QRS annotations",
    "              defaults: DT1 = 0.05 (seconds before annotation);",
    "              DT2 = 0.05 (seconds after annotation)",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -n NMAX     make up to NMAX measurements per signal (default: NMAX = "
        STRING(NMAX) ")",
    " -p          print results in physical units (default: ADC units)",
    "              -p may be followed by a character to choose a time format:",
    "  -pd         print time of day and date if known",
    "  -pe         print elapsed time as <hours>:<minutes>:<seconds>",
    "  -ph         print elapsed time in hours",
    "  -pm         print elapsed time in minutes",
    "  -ps         print elapsed time in seconds (default)",
    "  -pS         print elapsed time in sample intervals",
    " -q          quick mode: print individual measurements only",
    " -t TIME     stop at specified time",
    " -v          verbose mode: print individual measurements and trimmed means",
    " -w DTW      set RMS amplitude measurement window",
    "              default: DTW = 1 (second)",
    nullptr
};

static void help()
{
    std::fprintf(stderr, help_strings[0], pname);
    for (int i = 1; help_strings[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", help_strings[i]);
}
