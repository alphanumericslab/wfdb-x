// parsescp.cpp: parse an SCP-ECG file (read from the standard input)
// (C++ port of convert/parsescp.c)
//
// Copyright (C) 2000-2014 George B. Moody and Edna S. Moody (original C
// program, convert/parsescp.c; revised 2016-2020 by Benjamin Moody).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU General Public License, version 2 or later (see LICENSE).
//
// 'parsescp' converts SCP-ECG files produced by SpaceLabs/Burdick ECG carts
// into more easily usable formats.  See the comments in the C source for a
// full description of the program, its options, and its output files:
//   RECORD.des    (text) description (age, sex, recording bandwidth,
//                        measurements, diagnoses)
//   RECORD.ecg    (binary) reconstructed ECGs
//   RECORD.key    (text) patient's name and ID (medical record number)
//   RECORD.txt    (text) reconstructed ECGs (with -v)
//   RECORD.dat, RECORD.hea  WFDB-format record (with -w)
// With -a, an anonymized copy of the input is written to the standard output
// instead.
//
// The input is held in one byte buffer and the C program's pointers into it
// are represented by offsets.  Behaviors of the C program that are undefined
// (on defective inputs) are resolved as in the other wfdb-x implementations
// (see docs/KNOWN_C_BEHAVIORS.md): bytes beyond the end of the input are read
// as 0; signal arrays have at least 5000 samples and samples beyond the end
// of a lead are 0; missing subtraction zones are ignored and samples outside
// the arrays are skipped; strings copied into fixed-size buffers are
// truncated; a missing date or time of acquisition is left empty, and an
// invalid month is printed as "???".  Samples are written in little-endian
// byte order, as the C program does on x86.

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

#define VERSION_STRING "#ECG/1.0"

constexpr int NLEADS = 12;         // leads of a standard 12-lead ECG
constexpr int NSECTIONS = 12;      // SCP-ECG sections 0 to 11
constexpr int MAXAGE = 90;         // greater ages are censored (-a) or shown
                                   // as this value
// Output signals: the samples are rescaled to units of NV_PER_ADU (5000)
// nanovolts, so the gain SCP_GAIN (200 adu/mV) is exact, not assumed.
// (wfdb-x: the sampling frequency is the one given in the SCP file; the C
// program always wrote SCP_FREQ, 500 Hz, as legacy mode does.)
constexpr double SCP_GAIN = 200;
constexpr double SCP_FREQ = 500.;
constexpr double NV_PER_ADU = 5000.;

// The C program allocates every array with malloc/calloc; requests larger
// than this many elements are treated as allocation failures.
constexpr uint64_t MAXALLOC = (uint64_t)1 << 28;
// Signal arrays have at least this many elements (the .ecg file always
// contains 5000 samples of lead II); samples beyond a lead's length are 0.
constexpr uint64_t MINSIGLEN = 5000;

typedef std::vector<short> Sig;
typedef std::unique_ptr<Sig> SigP;

// ---- C integer conversions ----

static short i16(long long x) { return (short)(uint16_t)(uint64_t)x; }
static int i32(long long x) { return (int)(uint32_t)(uint64_t)x; }
static int i32u(uint64_t x) { return (int)(uint32_t)x; }

// C conversion of double to a 32-bit int (x86: INT_MIN if invalid).
static int d2i(double x)
{
    if (std::isnan(x) || x >= 2147483648.0 || x <= -2147483649.0)
        return INT_MIN;
    return (int)x;
}

// C conversion of double to short (via a 32-bit int, as gcc does).
static short d2s(double x) { return i16(d2i(x)); }

// C conversion of double to a 64-bit long (x86: LONG_MIN if invalid).
static long long d2l(double x)
{
    if (std::isnan(x) || x >= 9.2233720368547758e18 ||
        x < -9.2233720368547758e18)
        return LLONG_MIN;
    return (long long)x;
}

// C division of ints (truncation toward zero).
static int cdiv2(int a) { return a / 2; }

// calloc(n, sizeof(short)) for a signal; nullptr if allocation fails.
static SigP newsig(uint64_t n)
{
    if (n > MAXALLOC) return nullptr;
    return std::make_unique<Sig>((size_t)std::max(n, MINSIGLEN), 0);
}

// ---- global state ----

static int bflag = 0;  // 0: normal operation, 1: show baselines only
static int fflag = 0;  // 0: quit on CRC error, 1: continue if possible
static int tflag = 0;  // 0: normal operation, 1: show templates only
static int vflag = 0;  // 0: run quietly, 1: print (lots of) messages
static int xflag = 0;  // 0: run quietly, 1: print hexdump
static int shift = 0;  // 0: normal operation; otherwise, shift templates by
                       // this many samples before adding to residuals

static std::vector<unsigned char> data; // the input

static const char *pname;      // the name of this program
static int nleads = -1;        // number of ECG leads
static int nqrs = -1;          // number of beats detected
static std::vector<uint64_t> nsamp; // nsamp[i]: number of samples in lead i
static long long rblen;        // number of samples in refbeat (template)
static long long rblenms;      // length of refbeat in milliseconds
static int fcM;                // index of fiducial within refbeat
static double gref, gres;      // gains for refbeat and residuals
static double sfreq = -1.;     // sampling frequency (samples/second/lead)
static std::string recdate;    // date of recording
static std::string rectime;    // time of recording
static std::string recname;    // record name
static std::string patient_name; // patient's name (LAST, FIRST)
static std::string referring_dr; // referring dr
static std::string comments;   // comments
static std::string patient_id; // patient ID (medical record number)
static int age = -1;           // patient's age
static int sex = -1;           // 1: male, 2: female, 0: unknown, 9: unspec.
static int RRint = -1;         // RR interval
static int Pon = -1;           // P onset
static int Pend = -1;          // P end
static int QRSon = -1;         // QRS onset
static int QRSend = -1;        // QRS end
static int Tend = -1;          // T end
static short Paxis = 999;      // P axis
static short QRSaxis = 999;    // QRS axis
static short Taxis = 999;      // T axis
static int blfilt = -1;        // baseline filter -3 dB point
static int lpfilt = -1;        // low-pass filter -3 dB point
static int filter_bit = -1;    // see SCP spec
static int tdevid = -1;        // ID number of acquiring device
static int tinst = -1;         // institution number
static int tdept = -1;         // department number
static long long dept = -1;    // offset of location description (-1: none)
static long long inst = -1;    // offset of institution description
static int stmnts = -1;        // number of statements in report
static long long report[1200]; // offsets of the report statements (-1: none)
static int lflag = 0;  // if non-zero, low-pass filter the output
static int wflag = 0;  // if non-zero, produce a WFDB format record
static int zflag = 0;  // if non-zero, remove final transients and zero-mean
static int aflag = 0;
static int skip[NSECTIONS];
static uint64_t nout = 0; // number of samples written per signal

struct subzone {       // reference beat subtraction zone
    short type;        // beat type (0: dominant)
    long long t0;      // first sample in zone
    long long t1;      // fiducial
    long long t2;      // last sample in zone
};
static std::vector<std::unique_ptr<subzone>> subz; // (nullptr: missing)

static std::vector<SigP> ecg;  // ecg[i]: reconstructed ECG for ith lead
static bool have_ecg = false;
static std::vector<SigP> refbeat; // reference beat (template)

// Indices of the leads within ecg[].
static short leadI = -1, leadII = -1, leadIII = -1, aVR = -1, aVF = -1,
             aVL = -1, V1 = -1, V2 = -1, V3 = -1, V4 = -1, V5 = -1, V6 = -1;

struct ECGmeas {     // sets of measurements in section 10
    short leadid;    // Lead ID (index into leadname[])
    short vlen;      // length of the rest of the data for this lead
    short Pdur;      // P duration
    short PRint;     // PR interval
    short QRSdur;    // QRS duration
    short QTint;     // QT interval
    short Qdur;      // Q duration
    short Rdur;      // R duration
    short Sdur;      // S duration
    short Rpdur;     // R' duration
    short Spdur;     // S' duration
    short Qamp;      // Q amplitude
    short Ramp;      // R amplitude
    short Samp;      // S amplitude
    short Rpamp;     // R' amplitude
    short Spamp;     // S' amplitude
    short Jamp;      // J-point amplitude
    short Ppamp;     // P+ amplitude
    short Pnamp;     // P- amplitude
    short Tpamp;     // T+ amplitude
    short Tnamp;     // T- amplitude
    short STslope;   // ST slope
    short Pmorph;    // P morphology
    short Tmorph;    // T morphology
    short isoI;      // isoelectric segment at QRS onset
    short isoK;      // isoelectric segment at QRS end
    short tind;      // time of intrinsicoid deflection
    short qual;      // recording quality
    short st20;      // ST amplitude at J + 20 ms
    short st60;      // ST amplitude at J + 60 ms
    short st80;      // ST amplitude at J + 80 ms
    short strr16;    // ST amplitude at J + RRmean/16
    short strr8;     // ST amplitude at J + RRmean/8
};
static std::vector<ECGmeas> ecgmeas;
static int nsecleads;  // number of leads with measurements in section 10

static const char *month[] = {
    "January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December"
};

static const char *leadname[] = { // standard lead names
    "<Unspecified lead>", "I", "II", "V1", "V2",                 //  0 -  4
    "V3", "V4", "V5", "V6", "V7",                                //  5 -  9
    "V2R", "V3R", "V4R", "V5R", "V6R",                           // 10 - 14
    "V7R", "X", "Y", "Z", "CC5",                                 // 15 - 19
    "CM5", "Left Arm", "Right Arm", "Left Leg", "I (Frank)",     // 20 - 24
    "E", "C", "A", "M", "F",                                     // 25 - 29
    "H", "I-cal", "II-cal", "V1-cal", "V2-cal",                  // 30 - 34
    "V3-cal", "V4-cal", "V5-cal", "V6-cal", "V7-cal",            // 35 - 39
    "V2R-cal", "V3R-cal", "V4R-cal", "V5R-cal", "V6R-cal",       // 40 - 44
    "V7R-cal", "X-cal", "Y-cal", "Z-cal", "CC5-cal",             // 45 - 49
    "CM5-cal", "Left Arm-cal", "Right Arm-cal", "Left Leg-cal",
    "I-cal (Frank)",                                             // 50 - 54
    "E-cal", "C-cal", "A-cal", "M-cal", "F-cal",                 // 55 - 59
    "H-cal", "III", "aVR", "aVL", "aVF",                         // 60 - 64
    "-aVR", "V8", "V9", "V8R", "V9R",                            // 65 - 69
    "D (Nehb - Dorsal)", "A (Nehb - Anterior)", "J (Nehb - Inferior",
    "Defibrillator lead: anterior-lateral",
    "External pacing lead: anterior-posterior",                  // 70 - 74
    "A1 (Auxiliary unipolar lead 1)", "A2 (Auxiliary unipolar lead 2)",
    "A3 (Auxiliary unipolar lead 3)", "A4 (Auxiliary unipolar lead 4)",
    "V8-cal",                                                    // 75 - 79
    "V9-cal", "V8R-cal", "V9R-cal", "D-cal (Nehb - Dorsal)",
    "A-cal (Nehb - Anterior)",                                   // 80 - 84
    "J-cal (Nehb - Inferior)"                                    // 85
};
static const int NLEADNAMES = (int)(sizeof(leadname) / sizeof(leadname[0]));

// ---- access to the input buffer ----

static unsigned b(long long off)
{
    return (off >= 0 && (uint64_t)off < data.size()) ? data[(size_t)off] : 0;
}

static unsigned get16(long long off)
{
    return b(off) | (b(off + 1) << 8);
}

static void put16(unsigned val, long long off)
{
    if (off >= 0 && (uint64_t)off < data.size())
        data[(size_t)off] = (unsigned char)(val & 0xff);
    if (off + 1 >= 0 && (uint64_t)(off + 1) < data.size())
        data[(size_t)(off + 1)] = (unsigned char)((val >> 8) & 0xff);
}

static uint64_t get32(long long off)
{
    uint64_t r = (uint64_t)b(off) | ((uint64_t)b(off + 1) << 8) |
                 ((uint64_t)b(off + 2) << 16) | ((uint64_t)b(off + 3) << 24);
    if (r & 0x80000000u) // *p << 24 is a sign-extended int
        r |= 0xFFFFFFFF00000000ull;
    return r;
}

// The NUL-terminated string at off (ends at the end of the data).
static std::string cstr(long long off)
{
    std::string s;
    if (off < 0) return s;
    for (uint64_t k = (uint64_t)off; k < data.size() && data[(size_t)k]; k++)
        s += (char)data[(size_t)k];
    return s;
}

static unsigned short getcrc(long long off, long long length)
{
    unsigned char a, bb, crchigh = 0xff, crclow = 0xff;

    while (length-- > 0) {
        crchigh = a = (unsigned char)(b(off++) ^ crchigh);
        a >>= 4;          // top 4 bits of a are now zero
        a ^= crchigh;

        // swap crchigh, crclow
        crchigh = crclow;
        crclow = a;

        // rotate a left by four bits (swap nibbles)
        bb = (unsigned char)((a & 0xf) << 4);
        a >>= 4;
        bb = a |= bb;

        // rotate a left by one more bit
        if (a & 0x80) a = (unsigned char)((a << 1) | 1);
        else a = (unsigned char)(a << 1);

        crchigh ^= a &= 0x1f;
        a = bb & 0xf0;
        crchigh ^= a;     // crchigh complete

        // rotate b left by one bit
        if (bb & 0x80) bb = (unsigned char)((bb << 1) | 1);
        else bb = (unsigned char)(bb << 1);

        crclow ^= bb &= 0xe0; // crclow complete
    }
    return (unsigned short)((crchigh << 8) | crclow);
}

static int crcok(long long off, long long length, unsigned short crcref,
                 const char *description)
{
    unsigned short crc = getcrc(off, length);

    if (crc == crcref) {
        if (vflag) std::printf("%s: correct (%d)\n", description, crc);
        return 1;
    } else {
        if (vflag)
            std::printf("%s: error (calculated: %d, expected: %d)\n",
                        description, crc, crcref);
        if (fflag)
            return 0;
        else
            std::exit(1); // quit on CRC error unless in -f (force) mode
    }
}

static int isprint_c(unsigned c) { return 32 <= c && c < 127; }

// Signal k, if it exists.
static Sig *sigp(long long k)
{
    if (k < 0 || (uint64_t)k >= ecg.size()) return nullptr;
    return ecg[(size_t)k].get();
}

// Signal k, or (if it does not exist) an array of zero samples.
static Sig &srcsig(long long k);

static uint64_t nsampk(long long k)
{
    if (k < 0 || (uint64_t)k >= nsamp.size()) return 0;
    return nsamp[(size_t)k];
}

// ---- output ----

// Weighted sums of the low-pass filter, evaluated in the order of the C
// expressions (one operation per statement, so that no compiler fuses them).
static double wsum3(double a, double wa, double bv, double wb, double c,
                    double wc)
{
    double x = a * wa;
    double y = bv * wb;
    double z = c * wc;
    double r = x + y;
    r = r + z;
    return r;
}

static double wsum4(double a, double wa, double bv, double wb, double c,
                    double wc, double d, double wd)
{
    double r = wsum3(a, wa, bv, wb, c, wc);
    double z = d * wd;
    r = r + z;
    return r;
}

// This low-pass filter is implemented as a 5-tap weighted moving average FIR
// filter.  The -3 dB point is at roughly 1/10 the sampling frequency.  It is
// applied only to the .ecg file, not to the text-format samples.
static void lowpass()
{
    for (int i = 0; i < nleads; i++) {
        Sig *inp = sigp(i);
        if (inp == nullptr) continue;
        uint64_t n = nsampk(i);
        SigP outp = newsig(n);
        if (!outp) {
            std::fprintf(stderr, "Insufficient memory for filtering\n");
            break;
        }
        Sig &in = *inp, &out = *outp;
        const uint64_t nin = in.size(), nout = out.size();
        // samples beyond the end of the input array read as 0, and writes
        // beyond the end of the output array are skipped
        auto x = [&](uint64_t k) -> double {
            return k < nin ? (double)in[k] : 0.0;
        };
        auto xs = [&](uint64_t k) -> int { return k < nin ? (int)in[k] : 0; };
        auto put = [&](uint64_t k, short v) {
            if (k < nout) out[k] = v;
        };
        uint64_t j;
        put(0, d2s(wsum3(x(0), 0.67, x(1), 0.22, x(2), 0.11)));
        put(1, d2s(wsum4(x(0), 0.33, x(1), 0.34, x(2), 0.22, x(3), 0.11)));
        // C: for (j = 2; j < nsamp[i] - 2; j++), with an unsigned (wrapping)
        // bound; iterations past the end of the output array would only make
        // skipped writes, so the loop stops there (the final writes below
        // are then skipped too).
        const uint64_t jend = std::min(n - 2, nout);
        for (j = 2; j < jend; j++)
            out[j] = d2s(wsum3(x(j), 0.34, xs(j - 1) + xs(j + 1), 0.22,
                               xs(j - 2) + xs(j + 2), 0.11));
        put(j, d2s(wsum4(x(j - 2), 0.11, x(j - 1), 0.22, x(j), 0.34,
                         x(j + 1), 0.33)));
        j++;
        put(j, d2s(wsum3(x(j - 2), 0.11, x(j - 1), 0.22, x(j), 0.67)));
        ecg[i] = std::move(outp);
    }
}

static void prval(std::FILE *ofile, short val)
{
    if (val == 29999)
        std::fprintf(ofile, "  n/comp"); // not computed (ever) by analyzer
    else if (val == 29998)
        std::fprintf(ofile, "     rej"); // lead rejected, not computed
    else if (val == 19999)
        std::fprintf(ofile, "  absent"); // corresponding wave not present
    else
        std::fprintf(ofile, "%8d", val);
}

static void precgmeas(std::FILE *ofile)
{
    struct Row { const char *label; short ECGmeas::*field; };
    static const Row rows[] = {
        { "\nP duration    ms", &ECGmeas::Pdur },
        { "\nPR interval   ms", &ECGmeas::PRint },
        { "\nQRS duration  ms", &ECGmeas::QRSdur },
        { "\nQT interval   ms", &ECGmeas::QTint },
        { "\nQ duration    ms", &ECGmeas::Qdur },
        { "\nR duration    ms", &ECGmeas::Rdur },
        { "\nS duration    ms", &ECGmeas::Sdur },
        { "\nR' duration   ms", &ECGmeas::Rpdur },
        { "\nS' duration   ms", &ECGmeas::Spdur },
        { "\nQ amplitude   uV", &ECGmeas::Qamp },
        { "\nR amplitude   uV", &ECGmeas::Ramp },
        { "\nS amplitude   uV", &ECGmeas::Samp },
        { "\nJ amplitude   uV", &ECGmeas::Jamp },
        { "\nP+ amplitude  uV", &ECGmeas::Ppamp },
        { "\nP- amplitude  uV", &ECGmeas::Pnamp },
        { "\nT+ amplitude  uV", &ECGmeas::Tpamp },
        { "\nT- amplitude  uV", &ECGmeas::Tnamp },
        { "\nST slope    uV/s", &ECGmeas::STslope },
        { "\nP morphology  --", &ECGmeas::Pmorph },
        { "\nT morphology  --", &ECGmeas::Tmorph },
        { "\nIsoelec (I)   ms", &ECGmeas::isoI },
        { "\nIsoelec (K)   ms", &ECGmeas::isoK },
        { "\nIntrins defl  ms", &ECGmeas::tind },
        { "\nQuality       --", &ECGmeas::qual },
        // FIXME: SCP spec doesn't specify units of st20, 60, 80, rr16,
        // rr8 -- assume they are microvolts
        { "\nST (J+20ms)   uV", &ECGmeas::st20 },
        { "\nST (J+60ms)   uV", &ECGmeas::st60 },
        { "\nST (J+80ms)   uV", &ECGmeas::st80 },
        { "\nST (J+RRm/16) uV", &ECGmeas::strr16 },
        { "\nST (J+RRm/8)  uV", &ECGmeas::strr8 },
    };
    int i, n = (int)ecgmeas.size();

    std::fprintf(ofile, "Parameter  Units");
    for (i = 0; i < n; i++) {
        if (0 < ecgmeas[i].leadid && ecgmeas[i].leadid <= 85)
            std::fprintf(ofile, "%8s", leadname[ecgmeas[i].leadid]);
        else
            std::fprintf(ofile, "  <%4d>", ecgmeas[i].leadid);
    }
    for (const Row &r : rows) {
        std::fprintf(ofile, "%s", r.label);
        for (i = 0; i < n; i++)
            prval(ofile, ecgmeas[i].*(r.field));
    }
    std::fprintf(ofile, "\n");
}

// Write n samples of signal s, beginning at sample i0, as little-endian
// 16-bit integers.
static void write_samples(std::FILE *f, const Sig &s, size_t i0, size_t n)
{
    std::vector<unsigned char> buf;
    buf.reserve(2 * n);
    for (size_t i = i0; i < i0 + n && i < s.size(); i++) {
        unsigned v = (unsigned short)s[i];
        buf.push_back((unsigned char)(v & 0xff));
        buf.push_back((unsigned char)(v >> 8));
    }
    if (!buf.empty()) std::fwrite(buf.data(), 1, buf.size(), f);
}

static const Sig &sigr(long long k)
{
    static const Sig zero(MINSIGLEN, 0);
    Sig *s = sigp(k);
    return s ? *s : zero;
}

static Sig &srcsig(long long k)
{
    static Sig zero;
    Sig *s = sigp(k);
    if (s) return *s;
    size_t n = (size_t)std::max(nout, MINSIGLEN);
    zero.assign(n, 0);
    return zero;
}

static short sample_at(long long k, uint64_t i)
{
    const Sig &s = sigr(k);
    return i < s.size() ? s[(size_t)i] : 0;
}

static int write_wfdb_record()
{
    std::string filename = recname + ".dat";
    static const char *wleadname[NLEADS] = {
        "I", "II", "III", "aVR", "aVF", "aVL",
        "V1", "V2", "V3", "V4", "V5", "V6"
    };
    static WFDB_Sample v[NLEADS];
    static WFDB_Siginfo s[NLEADS];
    long long order[NLEADS] = { leadI, leadII, leadIII, aVR, aVF, aVL,
                            V1, V2, V3, V4, V5, V6 };
    char info[64];

    // wfdb-x: the sampling frequency is the one given in the SCP file (the C
    // program always wrote 500 Hz, as legacy mode does); without one, no
    // record is written.
    if (!wfdbx_get_legacy()) {
        if (sfreq <= 0.) {
            std::fprintf(stderr, "%s: sampling frequency not specified; "
                         "record %s not written\n", pname, recname.c_str());
            return 0;
        }
        setsampfreq(sfreq);
    }
    if (newheader(recname.c_str()) < 0)
        return 0;

    if (wfdbx_get_legacy())
        setsampfreq(SCP_FREQ); // FIXME: we should calculate this!

    for (int i = 0; i < NLEADS; i++) {
        s[i].fname = filename;
        s[i].desc = wleadname[i];
        s[i].units = "mV";
        s[i].fmt = 16;
        s[i].gain = SCP_GAIN;  // wfdb-x: exact, not assumed (see SCP_GAIN)
        s[i].adcres = 16; // FIXME: we should calculate this!
    }
    if (osigfopen(s, NLEADS) < NLEADS)
        return 0;
    std::string ptime = recdate + " " + rectime + "\n";
    setbasetime(ptime.c_str());

    // write the ECG samples
    for (uint64_t i = 0; i < nout; i++) {
        for (int k = 0; k < NLEADS; k++)
            v[k] = sample_at(order[k], i);
        if (putvec(v) < 0) break;
    }
    (void)newheader(recname.c_str());
    std::snprintf(info, sizeof(info), "<age>: %d <sex>: %c",
                  (age < MAXAGE) ? age : MAXAGE,
                  ((sex == 1) ? 'M' : (sex == 2) ? 'F' : '?'));
    putinfo(info);
    wfdbquit();
    return 1;
}

static int write_output()
{
    std::string dname, ename, kname, tname;
    std::FILE *dfile = nullptr, *efile = nullptr, *kfile = nullptr,
              *tfile = nullptr;

    if (recname.empty()) recname = "ecg"; // default record name
    dname = recname + ".des";
    ename = recname + ".ecg";
    kname = recname + ".key";
    tname = recname + ".txt";
    if ((dfile = std::fopen(dname.c_str(), "wb")) == nullptr) {
        std::fprintf(stderr, "%s: can't create '%s'\n", pname, dname.c_str());
        return 0;
    }
    if ((efile = std::fopen(ename.c_str(), "wb")) == nullptr) {
        std::fclose(dfile);
        std::fprintf(stderr, "%s: can't create '%s'\n", pname, ename.c_str());
        return 0;
    }
    if ((kfile = std::fopen(kname.c_str(), "wb")) == nullptr) {
        std::fclose(dfile);
        std::fclose(efile);
        std::fprintf(stderr, "%s: can't create '%s'\n", pname, kname.c_str());
        return 0;
    }
    if (vflag && (tfile = std::fopen(tname.c_str(), "wb")) == nullptr) {
        std::fclose(dfile);
        std::fclose(efile);
        std::fclose(kfile);
        std::fprintf(stderr, "%s: can't create '%s'\n", pname, tname.c_str());
        return 0;
    }

    // Write the description file first.
    std::fprintf(dfile, VERSION_STRING " description\n");
    std::fprintf(dfile, "Record: %s (%s %s)\n", recname.c_str(),
                 recdate.c_str(), rectime.c_str());
    std::fprintf(dfile, "Age: %d\n", age);
    std::fprintf(dfile, "Sex: ");
    switch (sex) {
    case 1: std::fprintf(dfile, "M\n"); break;
    case 2: std::fprintf(dfile, "F\n"); break;
    case 0: std::fprintf(dfile, "not known\n"); break;
    case 9: std::fprintf(dfile, "unspecified\n"); break;
    default: std::fprintf(dfile, "<error>\n"); break; // shouldn't happen
    }
    std::fprintf(dfile, "Referring Dr: %s\n", referring_dr.c_str());
    std::fprintf(dfile, "Comments: %s\n", comments.c_str());
    if (tdevid == 0)
        std::fprintf(dfile, "Cart ID: <missing>\n");
    else
        std::fprintf(dfile, "Cart ID: %d\n", tdevid);
    std::string sdept = (dept < 0) ? std::string("<missing>") : cstr(dept);
    std::fprintf(dfile, "Department: %s\n", sdept.c_str());
    if (tdept == 0)
        std::fprintf(dfile, "Department #: <missing>\n");
    else
        std::fprintf(dfile, "Department #: %s\n", sdept.c_str());
    std::string sinst = (inst < 0) ? std::string("<missing>") : cstr(inst);
    std::fprintf(dfile, "Institution: %s\n", sinst.c_str());
    if (tinst == 0)
        std::fprintf(dfile, "Institution #: <missing>\n");
    else
        std::fprintf(dfile, "Institution #: %d\n", tinst);

    for (int i = 0; i < stmnts; i++)
        std::fprintf(dfile, "Report %d: %s\n", i,
                     report[i] < 0 ? "(null)" : cstr(report[i]).c_str());

    // FIXME -- according to the SCP spec, units for blfilt should be .01 Hz,
    // not .0001 Hz;  but files from Spacelabs carts have blfilt equal to 500
    // and clearly are diagnostic (0.05-100 Hz) bandwidth.
    std::fprintf(dfile, "Bandwidth: %g-%d Hz\n", blfilt * 0.0001, lpfilt);
    std::fprintf(dfile, "Filtering:");
    if (filter_bit & 1) std::fprintf(dfile, " 60 Hz notch");
    if (filter_bit & 2) std::fprintf(dfile, " 50 Hz notch");
    if (filter_bit & 4) std::fprintf(dfile, " Artifact filter");
    if (filter_bit & 8) std::fprintf(dfile, " Baseline filter");
    if (filter_bit & 0xf0) std::fprintf(dfile, " <undefined>");
    if (filter_bit == 0) std::fprintf(dfile, " <not specified>");
    std::fprintf(dfile, "\n\n");

    std::fprintf(dfile, "RR interval: %d\n", RRint);
    std::fprintf(dfile, "P onset: %d\n", Pon);
    std::fprintf(dfile, "P end: %d\n", Pend);
    std::fprintf(dfile, "QRS onset: %d\n", QRSon);
    std::fprintf(dfile, "QRS end: %d\n", QRSend);
    std::fprintf(dfile, "T end: %d\n", Tend);
    std::fprintf(dfile, "P axis: %d\n", Paxis);
    std::fprintf(dfile, "QRS axis: %d\n", QRSaxis);
    std::fprintf(dfile, "T axis: %d\n", Taxis);

    precgmeas(dfile);
    std::fclose(dfile);

    // Generate the key file.  The patient's name and ID number should appear
    // only in this file (and in the debugging output, if enabled using -v).
    std::fprintf(kfile, VERSION_STRING " key\n");
    std::fprintf(kfile, "Record: %s (%s %s)\n", recname.c_str(),
                 recdate.c_str(), rectime.c_str());
    std::fprintf(kfile, "Name: %s\n", patient_name.c_str());
    std::fprintf(kfile, "MRN: %s\n", patient_id.c_str());
    std::fclose(kfile);

    // If the -z option was selected, then for each signal:
    //  1. Calculate the median amplitude of the first 5000 samples in the
    //     signal
    //  2. If its final sample is zero, replace that sample with the previous
    //     one.  This step eliminates transients that occur occasionally.
    //  3. Subtract the calculated median amplitude from all of the samples.
    // If the result after subtracting the median falls outside of the +/- 10
    // millivolt range (+/- 2000 A/D units), it is assumed to be invalid, and
    // the sample is stored with the value WFDB_INVALID_SAMPLE (-32768).
    if (zflag) {
        constexpr short ZMAX = 2000;    // 10 mV, in A/D units
        static short buf[MINSIGLEN], m, v;

        for (int s = 0; s < nleads; s++) {
            Sig *sp = sigp(s);
            if (sp == nullptr) continue;
            Sig &sig = *sp;
            uint64_t ns = nsampk(s);
            size_t i, imax = (size_t)((ns > MINSIGLEN) ? MINSIGLEN : ns);
            for (i = 0; i < imax; i++)
                buf[i] = i < sig.size() ? sig[i] : 0;
            std::sort(buf, buf + imax);
            m = buf[imax / 2];
            uint64_t k = ns - 1;
            if (1 <= k && k < sig.size() && sig[(size_t)k] == 0)
                sig[(size_t)k] = sig[(size_t)k - 1];
            for (uint64_t ii = 0; ii < nout && ii < sig.size(); ii++) {
                v = sig[(size_t)ii] = i16(sig[(size_t)ii] - m);
                if (v < -ZMAX || v > ZMAX)
                    sig[(size_t)ii] = (short)WFDB_INVALID_SAMPLE;
            }
        }
    }

    // Write the WFDB-format record if requested (-w option).
    if (wflag)
        write_wfdb_record();

    long long order[NLEADS] = { leadI, leadII, leadIII, aVR, aVF, aVL,
                                V1, V2, V3, V4, V5, V6 };

    // Write the ECG in text form if requested (-v option).
    if (vflag) {
        if (vflag > 1)
            std::fprintf(tfile,
                         "samp#      I     II    III    aVR    aVF    aVL"
                         "     V1     V2     V3     V4     V5     V6");
        for (uint64_t i = 0; i < nout; i++) {
            std::fprintf(tfile, "%5d", (int)i);
            for (int k = 0; k < NLEADS; k++)
                std::fprintf(tfile, "%7d", sample_at(order[k], i));
            std::fprintf(tfile, "\n");
        }
        std::fclose(tfile);
    }

    // Finally, output the ECG in vector (binary) form.
    // ** FIXME ** This assumes that the sampling frequency is 500 Hz, that
    // nsamp[leadII] >= 5000, and that nsamp[all other leads] >= 1250.
    std::string prolog = VERSION_STRING " signals\nRecord: " + recname +
        " (" + recdate + " " + rectime + ")\n";
    if (lflag) {
        prolog += "Low-pass filtered\n";
        lowpass();
    }
    constexpr size_t PROLOGLEN = 512;           // length of the text prolog
    constexpr size_t LEADIILEN = 5000;          // samples of lead II (10 s)
    constexpr size_t SEGLEN = LEADIILEN / 4;    // samples of the others (2.5 s)
    prolog.resize(PROLOGLEN, '\0');
    std::fwrite(prolog.data(), 1, PROLOGLEN, efile);
    long long rows[3][4] = { { leadI, aVR, V1, V4 },
                             { leadII, aVL, V2, V5 },
                             { leadIII, aVF, V3, V6 } };
    for (auto &row : rows)
        for (int k = 0; k < 4; k++)
            write_samples(efile, sigr(row[k]), SEGLEN * k, SEGLEN);
    write_samples(efile, sigr(leadII), 0, LEADIILEN);
    std::fclose(efile);

    return 1;
}

static void help()
{
    std::fprintf(stderr, "usage: %s -o RECORD [OPTIONS ...] <SCPFILE\n",
                 pname);
    std::fprintf(stderr, "  where RECORD is the name (<= 11 alphanumeric"
                 " characters) of this case,\n"
                 "  SCPFILE is the name of a file containing ECG"
                 " data in SCP-ECG format, and\n"
                 "  OPTIONS may include:\n"
                 "   -a    anonymize and copy stdin"
                 " to stdout (suppresses other output).\n"
                 "   -f    force parsing of a file with CRC"
                 " errors.\n"
                 "   -h    print brief help\n"
                 "   -l    low-pass filter (smooth) the"
                 " output waveforms.\n"
                 "   -v    option to print a (very) detailed analysis"
                 " of SCPFILE.\n"
                 "   -w    produce a WFDB-format record\n"
                 "   -z    zero-mean the input\n\n"
                 "  Additional options for debugging only:\n"
                 "   -b    show baseline (residuals);  suppress templates\n"
                 "   -s N  shift templates by N samples before adding\n"
                 "   -S N  skip parsing of section N\n"
                 "   -t    show templates; suppress baseline\n"
                 "   -x    show hex dumps (implies -v)\n");
}

// ---- sections ----

static void hexdump(long long p, long long len)
{
    std::printf("Hex dump of data area:\n\n");
    for (long long i = 0; i < len; i++) {
        if (i % 16 == 0) std::printf("\n%4d:  ", (int)i);
        std::printf(" %2x", b(p + i));
    }
    std::printf("\n\n");
}

static int section0(long long p, long long len)
{
    static const char id[] = "SCPECG";
    bool match = true;
    for (int k = 0; k < 6; k++)
        if (b(p + 10 + k) != (unsigned char)id[k]) {
            match = false;
            break;
        }
    if (!match)
        if (vflag)
            std::printf(" Warning: SCPECG identifier is missing in header\n");
    p += 16;
    len -= 16; // move to data area
    if (len < 10) {
        if (vflag) std::printf(" Error: section 0 contains no data\n");
        return 0;
    }

    while (len > 0) {
        unsigned sec_id = get16(p);
        uint64_t sec_len = get32(p + 2);
        uint64_t sec_index = get32(p + 6);
        if (vflag)
            std::printf("  Section %2d:%6lld bytes beginning at byte %6lld\n",
                        (int)sec_id, (long long)sec_len,
                        (long long)sec_index);
        len -= 10;
        p += 10;
    }
    if (len < 0) {
        if (vflag) std::printf(" Error: section 0 overlaps the next section\n");
        return 0;
    }
    return 1;
}

static void censor(long long p, unsigned short len, unsigned char c)
{
    while (--len) {
        if (p >= 0 && (uint64_t)p < data.size()) data[(size_t)p] = c;
        p++;
    }
    if (p >= 0 && (uint64_t)p < data.size()) data[(size_t)p] = 0;
}

static int section1(long long p, long long len)
{
    unsigned vlen;
    long long tpatid = -1, trefdr = -1, tcomments = -1, tdate = -1,
              ttime = -1, pyoa = -1, pyob = -1, firstname = -1,
              lastname = -1;
    enum { text, date, time_, b1, b2, b2b1, bn, mixed } vtype;
    long long p_save = p;
    long long len_save = len;

    p += 16;
    len -= 16; // move to data area
    if (len < 3) {
        if (vflag) std::printf(" Error: section 1 contains no data\n");
        return 0;
    }

    while (len > 2) {
        unsigned tag = b(p);
        if (tag == 255) break; // tag 255 is the terminator
        vlen = get16(p + 1);
        if (vlen > len) {
            if (vflag)
                std::printf(" Error: tagged field overlaps next section\n");
            return 0;
        }
        switch (tag) {
        case 0: if (vflag) std::printf("\n  Last name\n");
            vtype = text; lastname = p + 3;
            if (aflag) censor(lastname, (unsigned short)vlen, 'x');
            break;
        case 1: if (vflag) std::printf("\n  First name\n");
            vtype = text; firstname = p + 3;
            if (aflag) censor(firstname, (unsigned short)vlen, 'x');
            break;
        case 2: if (vflag) std::printf("\n  Patient ID number\n");
            vtype = text; tpatid = p + 3;
            if (aflag) censor(tpatid, (unsigned short)vlen, '0');
            break;
        case 3: if (vflag) std::printf("\n  Second last name\n");
            vtype = text;
            if (aflag) censor(p + 3, (unsigned short)vlen, 'x');
            break;
        case 4: if (vflag) std::printf("\n  Age\n");
            vtype = b2b1; age = (int)get16(p + 3); // FIXME
            if (aflag && age > MAXAGE)
                put16(MAXAGE, p + 3); // censor age if over 90
            break;
        case 5: if (vflag) std::printf("\n  Date of birth\n");
            vtype = date;
            if (aflag) {
                pyob = p + 3;      // save pointer to year of birth
                put16(257, p + 5); // censor month and day (257 => 1 Jan)
            }
            break;
        case 6: if (vflag) std::printf("\n  Height\n");
            vtype = b2b1; break;
        case 7: if (vflag) std::printf("\n  Weight\n");
            vtype = b2b1; break;
        case 8: if (vflag) std::printf("\n  Sex\n");
            vtype = b1; sex = (int)b(p + 3); break;
        case 9: if (vflag) std::printf("\n  Race\n");
            vtype = b1; break;
        case 10: if (vflag) std::printf("\n  Drug\n");
            vtype = mixed; break;
        case 11: if (vflag) std::printf("\n  Systolic blood pressure\n");
            vtype = b2; break;
        case 12: if (vflag) std::printf("\n  Diastolic blood pressure\n");
            vtype = b2; break;
        case 13:
            if (vflag) std::printf("\n  Diagnosis or referral indication\n");
            vtype = text; break;
        case 14: if (vflag) std::printf("\n  ID of the acquiring device\n");
            tdevid = (int)get16(p + 7);
            tinst = (int)get16(p + 3); // institution #
            tdept = (int)get16(p + 5); // department #
            if (vflag) {
                long long q;
                unsigned c;

                std::printf("   Institution number: %d\n", (int)get16(p + 3));
                std::printf("   Department number: %d\n", (int)get16(p + 5));
                std::printf("   Device ID: %d\n", (int)get16(p + 7));
                c = b(p + 9);
                std::printf("   Device type: %d (%s)\n", (int)c,
                            (c == 0 ? "cart" :
                             (c == 1 ? "system or host" : "<error>")));
                std::printf("   Manufacturer code: %d\n", (int)b(p + 10));
                std::printf("   Text model description: [%d]",
                            (int)b(p + 11));
                std::printf("   SCP-ECG protocol revision number: %g\n",
                            (double)b(p + 17) / 10.0);
                std::printf("   SCP-ECG protocol compatibility level: %d\n",
                            (int)b(p + 18));
                std::printf("   Language support code: %d\n", (int)b(p + 19));
                std::printf("   Device capabilities: %d\n", (int)b(p + 20));
                c = b(p + 21);
                std::printf("   AC mains frequency environment: %d ", (int)c);
                switch (c) {
                case 0: std::printf("(unspecified)\n"); break;
                case 1: std::printf("(50 Hz)\n"); break;
                case 2: std::printf("(60 Hz)\n"); break;
                default: std::printf("<error>"); break;
                }
                static const char *labels[5] = {
                    "Analyzing program revision number",
                    "Serial number of acquisition device",
                    "Acquisition device system software ID",
                    "Acquisition device SCP implementation ID",
                    "Manufacturer of acquisition device"
                };
                q = p + 39;
                for (int k = 0; k < 5; k++) {
                    std::string s = cstr(q);
                    std::printf("   %s: [%s]\n", labels[k], s.c_str());
                    q += (long long)s.size() + 1;
                }
            }
            vtype = mixed; break;
        case 15: if (vflag) std::printf("\n  ID of the analyzing device\n");
            vtype = mixed; break;
        case 16: if (vflag) std::printf("\n  Acquiring institution\n");
            vtype = text; inst = p + 3;
            if (aflag) censor(p + 3, (unsigned short)vlen, 'x');
            break;
        case 17: if (vflag) std::printf("\n  Analyzing institution\n");
            vtype = text;
            if (aflag) censor(p + 3, (unsigned short)vlen, 'x');
            break;
        case 18: if (vflag) std::printf("\n  Acquiring department\n");
            vtype = text;
            if (aflag) censor(p + 3, (unsigned short)vlen, 'x');
            dept = p + 3; break;
        case 19: if (vflag) std::printf("\n  Analyzing department\n");
            vtype = text;
            if (aflag) censor(p + 3, (unsigned short)vlen, 'x');
            break;
        case 20: if (vflag) std::printf("\n  Referring physician\n");
            vtype = text;
            if (aflag) censor(p + 3, (unsigned short)vlen, 'x');
            trefdr = p + 3; break;
        case 21: if (vflag) std::printf("\n  Latest confirming physician\n");
            vtype = text;
            if (aflag) censor(p + 3, (unsigned short)vlen, 'x');
            break;
        case 22: if (vflag) std::printf("\n  Technician\n");
            vtype = text;
            if (aflag) censor(p + 3, (unsigned short)vlen, 'x');
            break;
        case 23: if (vflag) std::printf("\n  Room\n");
            vtype = text;
            if (aflag) censor(p + 3, (unsigned short)vlen, 'x');
            break;
        case 24: if (vflag) std::printf("\n  Stat code (urgency)\n");
            vtype = b1; break;
        case 25: if (vflag) std::printf("\n  Date of acquisition\n");
            tdate = p + 3;
            if (aflag) {
                pyoa = p + 3;      // save pointer to year of acquisition
                put16(257, p + 5); // censor month and day (257 => 1 Jan)
            }
            vtype = date; break;
        case 26: if (vflag) std::printf("\n  Time of acquisition\n");
            ttime = p + 3;
            vtype = time_; break;
        case 27: if (vflag) std::printf("\n  Baseline filter\n");
            vtype = b2; blfilt = (int)get16(p + 3); break;
        case 28: if (vflag) std::printf("\n  Low-pass filter\n");
            vtype = b2; lpfilt = (int)get16(p + 3); break;
        case 29: if (vflag) std::printf("\n  Filter bit map\n");
            vtype = b1; filter_bit = (int)b(p + 3); break;
        case 30: if (vflag) std::printf("\n  Free text field (comments)\n");
            tcomments = p + 3;
            vtype = text; break;
        case 31: if (vflag) std::printf("\n  Sequence number\n");
            vtype = text; break;
        case 32: if (vflag) std::printf("\n  Medical history codes\n");
            vtype = bn; break;
        case 33: if (vflag) std::printf("\n  Electrode configuration code\n");
            vtype = b2; break;
        case 34: if (vflag) std::printf("\n  Time zone\n");
            vtype = mixed; break;
        case 35: if (vflag) std::printf("\n  Free text medical history\n");
            vtype = text; break;
        default: if (vflag) std::printf("\n  <Undefined tag>\n");
            vtype = mixed; break;
        }
        if (vflag) std::printf("   Tag%3d (%2d bytes): ", (int)tag, (int)vlen);
        p += 3;
        len -= vlen + 3;
        if (vlen == 0) {
            if (vflag) std::printf("<not defined>\n");
        } else switch (vtype) {
        case text:
            if (vflag)
                std::printf("[%*s]", (int)vlen - 1, cstr(p).c_str());
            p += vlen;
            break;
        case date:
            if (vlen != 4) {
                if (vflag)
                    std::printf("  Error: incorrect date format (%d bytes)\n",
                                (int)vlen);
            } else {
                if (vflag)
                    std::printf("%4d/%02d/%02d", (int)get16(p), (int)b(p + 2),
                                (int)b(p + 3));
            }
            p += vlen;
            break;
        case time_:
            if (vlen != 3) {
                if (vflag)
                    std::printf("  Error: incorrect time format (%d bytes)\n",
                                (int)vlen);
            } else if (vflag)
                std::printf("%02d:%02d:%02d", (int)b(p), (int)b(p + 1),
                            (int)b(p + 2));
            p += vlen;
            break;
        case b1:
            if (vlen != 1) {
                if (vflag)
                    std::printf("  Error: incorrect format (%d bytes instead"
                                " of 1)\n", (int)vlen);
            } else if (vflag)
                std::printf("%d", (int)b(p));
            p += vlen;
            break;
        case b2:
            if (vlen != 2) {
                if (vflag)
                    std::printf("  Error: incorrect format (%d bytes instead"
                                " of 2)\n", (int)vlen);
            } else if (vflag)
                std::printf("%d", (int)get16(p));
            p += vlen;
            break;
        case b2b1:
            if (vlen != 3) {
                if (vflag)
                    std::printf("  Error: incorrect format (%d bytes instead"
                                " of 3)\n", (int)vlen);
            } else if (vflag)
                std::printf("%d (code %d)", (int)get16(p), (int)b(p + 2));
            p += vlen;
            break;
        case bn:
            while (vlen-- > 0) {
                if (vflag) std::printf("%d, ", (int)b(p));
                p++;
            }
            break;
        case mixed:
            if (vflag) {
                while (vlen-- > 0) {
                    unsigned c = b(p);
                    if (isprint_c(c)) std::putchar((int)c);
                    else std::printf("\\%03o", c);
                    p++;
                }
                std::printf("\n");
            } else
                p += vlen;
            break;
        }
    }

    // (tdate and ttime are pointers to signed char)
    if (tdate >= 0) {
        int mon = (signed char)b(tdate + 2) - 1;
        char buf[64];
        std::snprintf(buf, sizeof(buf), "%d %s %d", (signed char)b(tdate + 3),
                      (0 <= mon && mon < 12) ? month[mon] : "???",
                      (int)get16(tdate));
        recdate = buf;
    }
    if (ttime >= 0) {
        char buf[64];
        std::snprintf(buf, sizeof(buf), "%02d:%02d:%02d",
                      (signed char)b(ttime), (signed char)b(ttime + 1),
                      (signed char)b(ttime + 2));
        rectime = buf;
    }
    std::string slast = lastname < 0 ? std::string("<last name missing>")
                                     : cstr(lastname);
    std::string sfirst = firstname < 0 ? std::string("<first name missing>")
                                       : cstr(firstname);
    if (slast.size() + sfirst.size() < 100 - 3)
        patient_name = slast + ", " + sfirst;
    else {
        std::fprintf(stderr, "Patient name (%s, %s) is too long\n",
                     slast.c_str(), sfirst.c_str());
        patient_name = "Name not available -- too long";
    }
    patient_id = (tpatid < 0 ? std::string("<patient ID missing>")
                             : cstr(tpatid)).substr(0, 30);
    referring_dr = (trefdr < 0 ? std::string("<referring physician missing>")
                               : cstr(trefdr)).substr(0, 100);
    comments = (tcomments < 0 ? std::string("<comments missing>")
                              : cstr(tcomments)).substr(0, 200);

    if (b(p) != 255)
        if (vflag)
            std::printf(" Error: header terminator (tag 255) is missing\n");
    // (tpatid cannot be NULL here, so that error is never reported)
    if (tdevid == -1 || tinst == -1 || tdept == -1)
        if (vflag)
            std::printf(" Error: device ID number (tag 14) is missing\n");
    if (tdate < 0)
        if (vflag)
            std::printf(" Error: date of acquisition (tag 25) is missing\n");
    if (ttime < 0)
        if (vflag)
            std::printf(" Error: time of acquisition (tag 26) is missing\n");

    if (aflag && pyob >= 0) {
        // (the censored year of birth is computed but never stored)
        (void)pyoa;
        // Recalculate the CRC for this section.
        unsigned short crc = getcrc(p_save + 2, len_save - 2);
        put16(crc, p_save);
    }

    if (b(p) != 255 || tdevid == -1 || tdate < 0 || ttime < 0)
        return 0;
    return 1;
}

static int section2(long long p, long long len)
{
    unsigned ntables;

    p += 16;
    len -= 16; // move to data area
    if (len < 2) {
        if (vflag) std::printf("  Error: section 2 contains no data\n");
        return 0;
    }

    ntables = get16(p);
    if (ntables == 19999) {
        if (vflag) std::printf("  Using standard Huffman table only\n");
    } else {
        if (vflag)
            std::printf("  Number of Huffman tables defined: %d\n",
                        (int)get16(p));
        if (vflag)
            std::printf("  Number of code structures in table 1: %d\n",
                        (int)get16(p + 2));
        // ** more to do here **
    }
    return 1;
}

static int section3(long long p, long long len)
{
    int i = 0, nsmax = 0;

    p += 16;
    len -= 16; // move to data area

    if (len < 2) {
        if (vflag) std::printf("  Error: section3 contains no data\n");
        return 0;
    }

    nleads = (int)b(p++);
    if (vflag) std::printf("  Number of leads: %d\n", nleads);
    len--;

    nsamp.assign((size_t)nleads + 4, 0);

    if (vflag) std::printf("  Flag byte: %xH\n", b(p));
    len--;
    if (b(p) & 1) {
        if (vflag)
            std::printf("   Reference beat subtraction used for compression\n");
    } else if (vflag)
        std::printf("   Reference beat subtraction not used for compression\n");
    if (b(p) & 4) {
        if (vflag) std::printf("   All leads recorded simultaneously\n");
    } else if (vflag)
        std::printf("   %d leads recorded simultaneously\n",
                    (int)((b(p) >> 3) & 0xf));
    p++;

    while (len > 8) {
        int j = (int)b(p + 8);
        if (j < NLEADNAMES) {
            if (vflag) std::printf("  %s", leadname[j]);
            const char *ln = leadname[j];
            if (std::strcmp("I", ln) == 0) leadI = (short)i;
            else if (std::strcmp("II", ln) == 0) leadII = (short)i;
            else if (std::strcmp("III", ln) == 0) leadIII = (short)i;
            else if (std::strcmp("aVR", ln) == 0) aVR = (short)i;
            else if (std::strcmp("aVF", ln) == 0) aVF = (short)i;
            else if (std::strcmp("aVL", ln) == 0) aVL = (short)i;
            else if (std::strcmp("V1", ln) == 0) V1 = (short)i;
            else if (std::strcmp("V2", ln) == 0) V2 = (short)i;
            else if (std::strcmp("V3", ln) == 0) V3 = (short)i;
            else if (std::strcmp("V4", ln) == 0) V4 = (short)i;
            else if (std::strcmp("V5", ln) == 0) V5 = (short)i;
            else if (std::strcmp("V6", ln) == 0) V6 = (short)i;
        } else if (j < 100) {
            if (vflag) std::printf("  <Reserved lead>");
        } else if (vflag)
            std::printf("  <Manufacturer-defined lead>");
        if (vflag)
            std::printf(": ID %d, samples %llu to %llu\n", j,
                        (unsigned long long)get32(p),
                        (unsigned long long)get32(p + 4));
        uint64_t ns = get32(p + 4) - get32(p) + 1;
        if ((size_t)i < nsamp.size()) nsamp[(size_t)i] = ns;
        else nsamp.push_back(ns);
        i++;
        p += 9;
        len -= 9;
    }

    // allocate space for 4 extra signals that will be calculated later, and
    // for a NULL pointer to signal the end of the array
    ecg.clear();
    ecg.resize((size_t)nleads + 5);
    have_ecg = true;

    for (i = 0; i < nleads + 4; i++) {
        if (i >= nleads) nsamp[i] = (uint64_t)(long long)nsmax;
        else if (nsamp[i] > (uint64_t)(long long)nsmax)
            nsmax = i32u(nsamp[i]);
        if (nsamp[i] < 1) nsamp[i] = 1;
        if (!(ecg[i] = newsig(nsamp[i]))) {
            if (vflag) std::printf("  Error: too many (%d) leads\n", nleads);
            return 0;
        }
    }

    if (len < 0) return 0;
    return 1;
}

static int section4(long long p, long long len)
{
    int stat = 1;

    p += 16;
    len -= 16; // move to data area
    if (len < 6) {
        if (vflag) std::printf("  Error: section 4 contains no data\n");
        return 0;
    }
    rblenms = get16(p);
    fcM = (int)get16(p + 2);
    nqrs = (int)get16(p + 4);
    if (vflag) {
        std::printf("  Length of reference beat type 0 data: %lld msec\n",
                    rblenms);
        std::printf("  Sample # of fiducial relative to start of ref beat"
                    " type 0: %d\n", fcM);
        std::printf("  Number of QRS complexes in the entire record: %d\n",
                    nqrs);
    }

    if (nqrs < 1)
        return 0; // no beats -- nothing else to do here

    p += 6;
    len -= 6;
    subz.clear();
    subz.resize((size_t)nqrs);

    if (len >= (long long)nqrs * 14) {
        if (vflag) std::printf("  Reference beat subtraction zones:\n");
        for (int i = 0; i < nqrs && len >= 14; i++) {
            subz[i] = std::make_unique<subzone>();
            subzone &z = *subz[i];
            z.type = (short)get16(p);
            z.t0 = (long long)get32(p + 2);
            z.t1 = (long long)get32(p + 6);
            z.t2 = (long long)get32(p + 10);
            if (z.type == 0 && z.t2 == 0)
                z.type = 9;

            if (vflag) {
                std::printf("   %2d  Type: %2d  start: %7lld"
                            "  fiducial: %7lld  end: %7lld\n",
                            i + 1, z.type, z.t0, z.t1, z.t2);
                if (z.type != 0 && (z.t0 != 0 || z.t2 != 0))
                    std::printf("  Error: start and end should be zero for"
                                " beats of non-zero types\n");
            }
            p += 14;
            len -= 14;
        }
    } else {
        if (vflag)
            std::printf("  Error: reference beat subtraction zones are"
                        " missing\n");
        stat = 0;
    }
    if (len >= (long long)nqrs * 8) {
        if (vflag) std::printf("  QRS locations:\n");
        for (int i = 0; i < nqrs; i++) {
            if (vflag)
                std::printf("   %2d  start: %7llu  end: %7llu\n", i + 1,
                            (unsigned long long)get32(p),
                            (unsigned long long)get32(p + 4));
            p += 8;
            len -= 8;
        }
    } else {
        if (vflag) std::printf("  Error: QRS locations are missing\n");
        stat = 0;
    }
    return stat;
}

static int Huffdecode(long long p, long long len, int section);

static int section5(long long p, long long len)
{
    p += 16;
    len -= 16; // move to data area

    if (len <= 0) {
        if (vflag) std::printf(" Error: section 5 contains no data\n");
        return 0;
    }

    // Calculate length of template in samples
    unsigned d = get16(p + 2);
    double x = rblenms * 1000.0;
    if (d) x /= d;
    else x = (x == 0) ? NAN : INFINITY;
    rblen = d2l(x);

    refbeat.clear();
    refbeat.resize((size_t)std::max(nleads + 1, 0));

    for (int i = 0; i < nleads; i++) {
        if (rblen < 0 || (uint64_t)rblen > MAXALLOC) {
            std::fprintf(stderr, "  Error: too many (%d) leads\n", nleads);
            return 0;
        }
        refbeat[i] = std::make_unique<Sig>((size_t)rblen, 0);
    }

    return Huffdecode(p, len, 5);
}

// The default (SCP standard) Huffman table.
struct htentry {
    unsigned short pattern;
    unsigned short suffixbits;
    short basevalue;
};
static const htentry htdefaultentries[] = {
    {     0,  0,  0 },
    {     4,  0,  1 },
    {     5,  0, -1 },
    {   0xc,  0,  2 },
    {   0xd,  0, -2 },
    {  0x1c,  0,  3 },
    {  0x1d,  0, -3 },
    {  0x3c,  0,  4 },
    {  0x3d,  0, -4 },
    {  0x7c,  0,  5 },
    {  0x7d,  0, -5 },
    {  0xfc,  0,  6 },
    {  0xfd,  0, -6 },
    { 0x1fc,  0,  7 },
    { 0x1fd,  0, -7 },
    { 0x3fc,  0,  8 },
    { 0x3fd,  0, -8 },
    { 0x3fe,  8,  0 },
    { 0x3ff, 16,  0 }
};
static const int htnpatterns = 19;

// This function reads bits from the input buffer, beginning 'ibits' bits
// from the MSB of *p, until it recognizes a Huffman-encoded value.  The
// decoded value is then stored into x, and the function returns the number
// of bits it has read.
static uint64_t getbits(short *x, long long p, uint64_t ibits)
{
    unsigned short bitbuffer = 0;
    static unsigned char w;
    unsigned int nbits = 0; // number of bits read on this call to getbits
    int i, j;
    short v;

    do {
        bitbuffer = (unsigned short)(bitbuffer << 1); // make room for a bit

        if ((ibits & 7) == 0)              // once every 8 bits ...
            w = (unsigned char)b(p + (long long)(ibits / 8)); // ... get 8
        // copy next bit from w into bitbuffer ...
        if (w & 0x80) bitbuffer |= 1;
        // ... and discard it from w
        w = (unsigned char)(w << 1);

        ibits++;
        nbits++;

        // check bitbuffer against all of the Huffman table entries
        for (i = 0; i < htnpatterns; i++) {
            if (bitbuffer == htdefaultentries[i].pattern) {
                // we have a match
                if ((j = htdefaultentries[i].suffixbits) == 0)
                    *x = htdefaultentries[i].basevalue;
                else { // j is the number of additional bits we need
                    // as above, get 8 more bits if needed
                    if ((ibits & 7) == 0)
                        w = (unsigned char)b(p + (long long)(ibits / 8));
                    // Get the first (most significant) bit of the value;  if
                    // it's a 1, sign-extend it.
                    if (w & 0x80) {
                        int jj = j;
                        for (v = 1; jj < 16; jj++) {
                            v = (short)(v << 1); // make room for another bit
                            v |= 1;              // shift in another 1
                        }
                    } else
                        v = 0;
                    w = (unsigned char)(w << 1);
                    ibits++;
                    nbits++;
                    for (j--; j > 0; j--, ibits++, nbits++) {
                        v = (short)(v << 1);
                        if ((ibits & 7) == 0)
                            w = (unsigned char)b(p + (long long)(ibits / 8));
                        if (w & 0x80) v |= 1;
                        w = (unsigned char)(w << 1);
                    }
                    *x = v;
                }
                return nbits;
            }
        }
    } while (nbits < 64 - 1);
    if (vflag) std::printf("Huffman encoding error\n");
    return 1000000;
}

static int section6(long long p, long long len)
{
    p += 16;
    len -= 16; // move to data area

    if (len <= 6) {
        if (vflag) std::printf(" Error: section 6 contains no data\n");
        return 0;
    }
    return Huffdecode(p, len, 6);
}

static int Huffdecode(long long p, long long len, int section)
{
    int i, enctype = 2, sampint;
    uint64_t ibits, tbits, tleadlen = 0;
    double g = get16(p);

    if (section == 5) gref = g / NV_PER_ADU;
    else gres = g / NV_PER_ADU;
    if (vflag)
        std::printf("  Amplitude value multiplier: %g nanovolts per unit\n",
                    g);
    sampint = (int)get16(p + 2);
    if (vflag)
        std::printf("  Sample time interval: %d microseconds\n", sampint);
    if (sampint > 0) {
        if (sfreq > 0 && sfreq != 1.0e6 / sampint)
            std::printf("Warning: section 5 and 6 sample intervals don't"
                        " match");
        // FIXME: If this ever happens, we need to redo the reconstruction
        // code in main()
        sfreq = 1.0e6 / sampint;
    } else if (wfdbx_get_legacy()) {    // wfdb-x: as in the C program
        std::printf("Error: sampling frequency not specified;  assuming"
                    " 500 Hz\n");
        sfreq = SCP_FREQ;
    } else  // wfdb-x: the C program assumed 500 Hz
        std::printf("Error: sampling frequency not specified\n");
    // (the encoding type is read from the high byte of the sample interval)
    if (vflag) std::printf("  Encoding type: %d ", (int)b(p + 3));
    switch (b(p + 3)) {
    case 0: if (vflag) std::printf("(amplitudes)\n"); enctype = 0; break;
    case 1: if (vflag) std::printf("(first differences)\n"); enctype = 1;
        break;
    case 2: if (vflag) std::printf("(second differences)\n"); enctype = 2;
        break;
    default:
        if (vflag) std::printf("<undefined, assuming second differences>\n");
        enctype = 2;
        break;
    }
    if (section == 6) {
        if (vflag) std::printf("  Compression type: %d ", (int)b(p + 4));
        switch (b(p + 4)) {
        case 0: if (vflag) std::printf("(non-bimodal)\n"); break;
        case 1: if (vflag) std::printf("(bimodal)\n"); break;
        default: if (vflag) std::printf("<undefined, assuming bimodal>\n");
            break;
        }
    }
    p += 6;
    len -= 6;

    if (nleads < 0) {
        if (vflag)
            std::printf("  Error: number of leads undefined -- section 3"
                        " missing or out of order\n");
        return 0;
    }
    if (nleads == 0) {
        if (vflag) std::printf("  Error: no leads recorded\n");
        return 0;
    }
    std::vector<uint64_t> leadlen((size_t)nleads);

    for (i = 0; i < nleads; i++, p += 2, len -= 2) {
        tleadlen += leadlen[i] = get16(p);
        if (vflag)
            std::printf("  Lead %d:%5llu bytes\n", i,
                        (unsigned long long)leadlen[i]);
    }

    uint64_t ulen = (uint64_t)len;
    if (ulen < tleadlen) {
        if (vflag)
            std::printf("  Error: %llu data byte%s missing from section %d\n",
                        (unsigned long long)(tleadlen - ulen),
                        (tleadlen - ulen == 1) ? "" : "s", section);
        return 0;
    } else if (ulen > ((tleadlen + 1) & ~(uint64_t)1))
        // the expression above rounds tleadlen up to an even number
        if (vflag)
            std::printf("  Warning: %llu extra byte%s in section %d\n",
                        (unsigned long long)(ulen - tleadlen),
                        (ulen - tleadlen == 1) ? "" : "s", section);

    for (i = 0; i < nleads; i++) {
        int explen, j;
        static short dx, x, xx, xxx, xout;
        Sig *dest;
        double gain;

        if (vflag) std::printf("  Lead %d data\n", i);
        for (j = 0; j < 10; j++)
            if (vflag) std::printf(" %02x", b(p + j));
        if (vflag) std::printf("\n");
        xxx = xx = 0;
        if (section == 6) {
            explen = i32u(nsamp[(size_t)i]);
            dest = sigp(i);
            gain = gres;
        } else {
            explen = i32(rblen);
            dest = refbeat[(size_t)i].get();
            gain = gref;
        }
        for (j = 0, ibits = 0, tbits = leadlen[i] * 8;
             j < explen && ibits < tbits; j++) {
            ibits += getbits(&x, p, ibits);
            if (j == 0) xxx = xx = x;
            else if (j == 1) {
                dx = i16(x - xxx);
                xxx = x;
                xx = i16(xx + x);
            } else {
                dx = i16(dx + x);
                xxx = i16(xxx + dx);
                xx = i16(xx + x);
            }
            switch (enctype) {
            case 0: xout = x; break;
            case 1: xout = xx; break;
            case 2: xout = xxx; break;
            }
            if (dest != nullptr && (size_t)j < dest->size())
                (*dest)[(size_t)j] = d2s(xout * gain);
            if (vflag > 1)
                std::printf("   %5d %5d %5d %5d\n", j, x, xx, xxx);
        }
        if (j < explen)
            if (vflag)
                std::printf("   Error: %lld sample%s missing in lead %d\n",
                            (long long)(leadlen[i] - (uint64_t)(long long)j),
                            (leadlen[i] - (uint64_t)(long long)j == 1)
                                ? "" : "s", i);
        if (ibits < tbits)
            if (vflag)
                std::printf("   Warning: %lld extra bit%s in lead %d\n",
                            (long long)(tbits - ibits),
                            (tbits - ibits == 1) ? "" : "s", i);
        p += (long long)leadlen[i];
        if (vflag) std::printf("\n");
    }
    return 1;
}

static int section7(long long p, long long len)
{
    unsigned nmb, nps, sec7qrs;
    long long q, r;
    short i, n, sec7qrs_offset;

    p += 16;
    len -= 16; // move to data area

    if (len <= 0) {
        if (vflag) std::printf(" Error: section 7 contains no data\n");
        return 0;
    }

    if (xflag && vflag) hexdump(p, len);

    if (len < 20) { // there isn't enough room left for measurements
        if (vflag)
            std::printf(" Error: section 7 is too short (len = %lld)\n", len);
        return 0;
    }

    RRint = (int)get16(p + 2);

    // get P onset, etc from first measurement block
    q = p + 6;
    Pon = (int)get16(q);
    Pend = (int)get16(q + 2);
    QRSon = (int)get16(q + 4);
    QRSend = (int)get16(q + 6);
    Tend = (int)get16(q + 8);
    Paxis = (short)get16(q + 10);
    QRSaxis = (short)get16(q + 12);
    Taxis = (short)get16(q + 14);

    nmb = b(p);
    nps = b(p + 1);
    sec7qrs_offset = i16(6 + 16 * nmb + 10 * nps);
    if (sec7qrs_offset > len) sec7qrs_offset = i16(len);

    if (sec7qrs_offset > len) {
        if (vflag)
            std::printf(" Error: section 7 is too short (nmb = %d, nps = %d)\n",
                        (int)nmb, (int)nps);
        return 0;
    }

    sec7qrs = get16(p + sec7qrs_offset) & 0xff;

    if (vflag) {
        std::printf(" QRS complexes measured: %d\n", (int)sec7qrs);
        std::printf(" Measurement blocks: %d\n", (int)nmb);
        if (nmb == sec7qrs + 1)
            std::printf("  (First measurement block contains measurements for"
                        " reference beat type 0;\n"
                        "   Others contain measurements for each individual"
                        " beat)\n");
        else
            std::printf("  (Measurements for each reference beat type)\n");
        std::printf("  Number of measurement blocks: %d\n", (int)nmb);
        std::printf("  Number of pacemaker spikes: %d\n", (int)nps);
        std::printf("  Mean RR interval: %d ms\n", RRint);
        std::printf("  Mean PP interval: %d ms\n", (int)get16(p + 4));
        for (i = 0, q = p + 6; i < (int)nmb; i++, q += 16) {
            std::printf("   Block %d\n", i);
            std::printf("    P onset:   %d ms\n", (int)get16(q));
            std::printf("    P end:     %d ms\n", (int)get16(q + 2));
            std::printf("    QRS onset: %d ms\n", (int)get16(q + 4));
            std::printf("    QRS  end:  %d ms\n", (int)get16(q + 6));
            std::printf("    T end:     %d ms\n", (int)get16(q + 8));
            if ((n = (short)get16(q + 10)) == 999)
                std::printf("    P axis:    undefined\n");
            else std::printf("    P axis:    %d degrees\n", n);
            if ((n = (short)get16(q + 12)) == 999)
                std::printf("    QRS axis:  undefined\n");
            else std::printf("    QRS axis:  %d degrees\n", n);
            if ((n = (short)get16(q + 14)) == 999)
                std::printf("    T axis:    undefined\n");
            else std::printf("    T axis:    %d degrees\n", n);
        }

        if (nps > 0)
            std::printf(" Pacemaker spike measurement data\n");
        for (i = 0, r = q + nps * 4; i < (int)nps; i++, q += 4, r += 6) {
            std::printf("Spike %d: %u ms, %d microvolts ", i, get16(q),
                        (int)get16(q + 2));
            switch (b(r)) {
            case 0: std::printf("(unknown spike type, "); break;
            case 1: std::printf("(triggers neither P nor QRS, "); break;
            case 2: std::printf("(triggers a QRS, "); break;
            case 3: std::printf("(triggers a P, "); break;
            default: std::printf("(spike type %d, ", (int)b(r)); break;
            }
            switch (b(r + 1)) {
            case 0: std::printf("source unknown, "); break;
            case 1: std::printf("internal, "); break;
            case 2: std::printf("external, "); break;
            default: std::printf("source type %d, ", (int)b(r + 1)); break;
            }
            if ((n = (short)get16(r + 2)) == 0)
                std::printf(" not linked to a QRS, ");
            else
                std::printf(" linked to QRS #%d, ", n);
            if ((n = (short)get16(r + 4)) == 0)
                std::printf("width unknown)\n");
            else
                std::printf("%d microseconds\n)", n);
        }

        // The next part doesn't seem to be right ...
        std::printf(" <!> sec7qrs = <%d>\n", (int)sec7qrs);
        if (sec7qrs > 0)
            std::printf(" QRS type information (%d beats)\n", (int)get16(r));
        for (i = 0, q = r + 2; i < (int)sec7qrs; i++, q++)
            std::printf("  QRS %d: reference beat type %d\n", i, (int)b(q));

        std::printf("%lld bytes remaining in section 7\n", len - (q - p));
        while (q < p + len) {
            // get16(q) reads one byte past the end of the section at the
            // last iteration (read as 0 beyond the end of the data)
            std::printf(" %5d", (int)get16(q));
            std::printf(" [%3d]", (int)b(q));
            q++;
        }
        std::printf("\n");
    }

    // ** more to do here **
    return 1;
}

static int section8(long long p, long long len)
{
    int i, n;

    p += 16;
    len -= 16; // move to data area

    if (len <= 0) {
        if (vflag) std::printf(" Error: section 8 contains no data\n");
        return 0;
    }

    if (vflag) std::printf(" Status: %d ", (int)b(p));
    switch (b(p)) {
    case 0: if (vflag) std::printf("(original report, not confirmed)\n");
        break;
    case 1: if (vflag) std::printf("(confirmed report)\n"); break;
    case 2: if (vflag) std::printf("(overread report, but not confirmed)\n");
        break;
    default: if (vflag) std::printf("<undefined>\n"); break;
    }

    if (vflag)
        std::printf(" Date: %4d/%02d/%02d\n", (int)get16(p + 1),
                    (int)b(p + 3), (int)b(p + 4));
    if (vflag)
        std::printf(" Time: %02d:%02d:%02d\n", (int)b(p + 5), (int)b(p + 6),
                    (int)b(p + 7));
    n = (int)b(p + 8);
    stmnts = n;
    if (vflag) std::printf(" Number of statements: %d\n", n);
    p += 9;
    len -= 9;

    for (i = 0; i < n && len > 2; i++) {
        int slen;

        report[i] = p + 3;
        slen = (int)get16(p + 1);
        if (vflag)
            std::printf("  Statement %2d: (%d bytes)\n", (int)b(p), slen);
        if (vflag) std::printf("   [%*s]\n", slen, cstr(p + 3).c_str());
        p += slen + 3;
        len -= slen + 3;
    }

    if (i < n) {
        if (vflag) std::printf("  Error: data missing in section 8\n");
        return 0;
    }

    return 1;
}

static int section9(long long p, long long len)
{
    p += 16;
    len -= 16; // move to data area

    if (len <= 0) {
        if (vflag) std::printf(" Error: section 9 contains no data\n");
        return 0;
    }

    // FIXME: more to do here
    if (vflag) {
        std::printf("  Data:\n   ");
        while (len-- > 0) {
            unsigned c = b(p);
            if (isprint_c(c)) std::putchar((int)c);
            else std::printf("\\%03o", c);
            p++;
        }
        std::printf("\n");
    }

    return 1;
}

static int section10(long long p, long long len)
{
    p += 16;
    len -= 16; // move to data area

    if (len <= 0) {
        if (vflag) std::printf(" Error: section 10 contains no data\n");
        return 0;
    }

    // Section 10 data area begins with a 4-byte header.  The first 2 bytes
    // specify the number of leads for which measurements are stored.
    nsecleads = (int)get16(p);
    // FIXME:  the draft standard doesn't say what the next 2 bytes are --
    // so they are ignored here.

    // Fill the array of structures.
    ecgmeas.assign((size_t)nsecleads, ECGmeas());
    p += 4;
    for (int i = 0; i < nsecleads; i++) {
        ECGmeas &m = ecgmeas[(size_t)i];
        short *f[] = {
            &m.leadid, &m.vlen, &m.Pdur, &m.PRint, &m.QRSdur, &m.QTint,
            &m.Qdur, &m.Rdur, &m.Sdur, &m.Rpdur, &m.Spdur, &m.Qamp, &m.Ramp,
            &m.Samp, &m.Rpamp, &m.Spamp, &m.Jamp, &m.Ppamp, &m.Pnamp,
            &m.Tpamp, &m.Tnamp, &m.STslope, &m.Pmorph, &m.Tmorph, &m.isoI,
            &m.isoK, &m.tind, &m.qual, &m.st20, &m.st60, &m.st80, &m.strr16,
            &m.strr8
        };
        for (size_t k = 0; k < sizeof(f) / sizeof(f[0]); k++)
            *f[k] = (short)get16(p + 2 * (long long)k);
        p += m.vlen + 4;
    }

    if (vflag) {
        std::printf(" Results for %d leads\n", nsecleads);
        precgmeas(stdout);
    }
    return 1;
}

static int section11(long long p, long long len)
{
    (void)p;    // the data area (at p + 16) is not parsed
    len -= 16;  // length of the data area

    if (len <= 0) {
        if (vflag) std::printf(" Error: section 11 contains no data\n");
        return 0;
    }

    // ** more to do here **
    return 1;
}

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

// C atoi() (strtol truncated to a 32-bit int)
static int c_atoi(const char *s)
{
    return i32(std::strtoll(s, nullptr, 10));
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    unsigned short crc;
    unsigned sec_id;
    uint64_t bytesread, length, sec_len;
    unsigned char header[6];
    long long p;
    int i, k;

    pname = prog_name(argv[0]);
    for (k = 0; k < 1200; k++) report[k] = -1;

    for (i = 1; i < argc; i++) {
        if (argv[i][0] == '-') switch (argv[i][1]) {
            case 'a': // write an anonymized version of stdin to stdout
                aflag = 1;
                xflag = vflag = 0; // incompatible with -v and -x
                break;
            case 'b': // show baseline (residuals);  suppress templates
                bflag = 1;
                tflag = 0;
                break;
            case 'f': // force parsing even if CRC error(s) found
                fflag = 1;
                break;
            case 'h': // print a usage summary
                help();
                std::exit(1);
            case 'l': // low-pass filter the output waveforms
                lflag = 1;
                break;
            case 'o': // record name follows
                if (++i < argc && std::strlen(argv[i]) <= 11)
                    recname = argv[i];
                else {
                    std::fprintf(stderr, "%s: a record name of 11 or fewer"
                                 " alphanumericcharacters must\n follow -o\n",
                                 pname);
                    std::exit(1);
                }
                break;
            case 's': // shift templates by N samples
                if (++i < argc)
                    shift = c_atoi(argv[i]);
                else {
                    std::fprintf(stderr, "%s: number of samples to shift"
                                 " templates must follow -s\n", pname);
                    std::exit(1);
                }
                break;
            case 'S': // skip a section (may be repeated)
                if (++i < argc) {
                    if (argv[i][0] == '-')
                        for (k = 0; k < NSECTIONS; k++) skip[k] = 1;
                    else {
                        int index = c_atoi(argv[i]);
                        if (0 <= index && index < NSECTIONS)
                            skip[index] = 1 - skip[index];
                    }
                } else {
                    std::fprintf(stderr, "%s: number of section to skip, or"
                                 " '-', must follow -S\n", pname);
                    std::exit(1);
                }
                break;
            case 't': // show templates;  suppress baseline
                tflag = 1;
                bflag = 0;
                break;
            case 'v': // print a detailed analysis of the record contents
                vflag++;
                aflag = 0; // incompatible with -a
                break;
            case 'w': // create a WFDB-format record
                wflag++;
                break;
            case 'x': // print a hex dump (implies -v)
                xflag = vflag = 1;
                aflag = 0;
                break;
            case 'z': // suppress final transients and zero-mean the ECGs
                zflag++;
                break;
            default:
                std::fprintf(stderr, "%s: unrecognized option '%s'\n", pname,
                             argv[i]);
                help();
                std::exit(1);
            }
        else {
            std::fprintf(stderr, "%s: unrecognized argument '%s'\n", pname,
                         argv[i]);
            help();
            std::exit(1);
        }
    }

#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif

    bytesread = std::fread(header, 1, 6, stdin);
    if (bytesread != 6) {
        std::fprintf(stderr, "%s: input too short (only %llu bytes)\n",
                     pname, (unsigned long long)bytesread);
        std::exit(1);
    }
    data.assign(header, header + 6);
    crc = (unsigned short)get16(0);
    length = get32(2);
    if (vflag)
        std::printf("CRC = %d, expected length = %lld bytes\n", crc,
                    (long long)length);
    if (length > (uint64_t)LLONG_MAX) {
        std::fprintf(stderr, "%s: insufficient memory (%lld bytes needed)\n",
                     pname, (long long)length);
        std::exit(2);
    }
    while (bytesread < length) {
        unsigned char buf[65536];
        uint64_t want = length - bytesread;
        if (want > sizeof(buf)) want = sizeof(buf);
        size_t n = std::fread(buf, 1, (size_t)want, stdin);
        if (n == 0) break;
        data.insert(data.end(), buf, buf + n);
        bytesread += n;
    }
    if (bytesread < length) {
        uint64_t d = length - bytesread;
        std::fprintf(stderr, "%s: input too short (%llu byte%s missing)\n",
                     pname, (unsigned long long)d, (d == 1) ? "" : "s");
        std::exit(3);
    }
    if (vflag) std::printf("Record length: %lld bytes\n", (long long)length);
    crcok(2, (long long)length - 2, crc, "Top-level CRC");

    // Now check the sections.
    p = 6; // skip the record header -- p points to section 0

    while ((uint64_t)p < length) { // true if there is at least 1 more section
        char desc[32];

        crc = (unsigned short)get16(p);
        sec_id = get16(p + 2);
        sec_len = get32(p + 4);
        if (vflag)
            std::printf("\nSection %d length: %lld bytes\n", (int)sec_id,
                        (long long)sec_len);
        if (sec_len < 8) {
            if (vflag)
                std::printf(" Warning: section length too short (must be at"
                            " least 8 bytes)\n"
                            "  Remaining data (%llu bytes) following short"
                            " section will not be read\n",
                            (unsigned long long)(length - (uint64_t)(p + 8)));
            sec_len = 8;
        }
        if (sec_len > length - (uint64_t)p) {
            if (vflag)
                std::printf(" Warning: section length exceeds amount of"
                            " remaining data\n"
                            "  This section will not be parsed\n");
            break;
        }
        std::snprintf(desc, sizeof(desc), " Section %d CRC", (int)sec_id);
        crcok(p + 2, (long long)sec_len - 2, crc, desc);
        if (vflag) std::printf(" Section version number: %d\n", (int)b(p + 8));
        if (vflag)
            std::printf(" Protocol version number: %d\n", (int)b(p + 9));
        if (vflag) std::printf(" Contents: ");
        long long sl = (long long)sec_len;
        switch (sec_id) {
        case 0: if (vflag) std::printf(" Pointers to data areas in the"
                                       " record\n");
            if (skip[0]) std::printf("  [skipped]\n");
            else section0(p, sl);
            break;
        case 1: if (vflag) std::printf(" Header information - Patient"
                                       " data/ECG acquisition data\n");
            if (skip[1]) std::printf("  [skipped]\n");
            else section1(p, sl);
            break;
        case 2: if (vflag) std::printf(" Huffman tables used in encoding of"
                                       " ECG data\n");
            if (skip[2]) std::printf("  [skipped]\n");
            else section2(p, sl);
            break;
        case 3: if (vflag) std::printf(" ECG lead definition\n");
            if (skip[3]) std::printf("  [skipped]\n");
            else section3(p, sl);
            break;
        case 4: if (vflag) std::printf(" QRS locations\n");
            if (skip[4]) std::printf("  [skipped]\n");
            else section4(p, sl);
            break;
        case 5: if (vflag) std::printf(" Encoded reference beat data\n");
            if (skip[5]) std::printf("  [skipped]\n");
            else section5(p, sl);
            break;
        case 6: if (vflag) std::printf(" Residual signal after reference beat"
                                       " subtraction (if reference beats\n"
                                       "  are stored);  otherwise, encoded"
                                       " rhythm data\n");
            if (skip[6]) std::printf("  [skipped]\n");
            else section6(p, sl);
            break;
        case 7: if (vflag) std::printf(" Global measurements\n");
            if (skip[7]) std::printf("  [skipped]\n");
            else section7(p, sl);
            break;
        case 8: if (vflag) std::printf(" Textual diagnosis from the"
                                       " interpretive device\n");
            if (skip[8]) std::printf("  [skipped]\n");
            else section8(p, sl);
            break;
        case 9: if (vflag) std::printf(" Manufacturer specific diagnostic and"
                                       " overreading data\n");
            if (skip[9]) std::printf("  [skipped]\n");
            else section9(p, sl);
            break;
        case 10: if (vflag) std::printf(" Lead measurement results\n");
            if (skip[10]) std::printf("  [skipped]\n");
            else section10(p, sl);
            break;
        case 11: if (vflag) std::printf(" Universal statement codes resulting"
                                        " from the interpretation\n");
            if (skip[11]) std::printf("  [skipped]\n");
            else section11(p, sl);
            break;
        default:
            if (vflag)
                std::printf(" Manufacturer-defined (non-standard) section"
                            " %d\n", (int)sec_id);
            break;
        }
        p += sl;
    }

    // Low-pass filter the residuals.
    for (i = 0; i < nleads; i++) {
        Sig *inp = sigp(i);
        if (inp == nullptr) continue;
        uint64_t n = nsampk(i);
        SigP outp = newsig(n);
        if (!outp) {
            std::fprintf(stderr, "Insufficient memory for filtering\n");
            break;
        }
        Sig &in = *inp, &out = *outp;
        if (tflag == 0) { // true unless -t debugging option was given
            uint64_t jj;
            out[0] = in[0];
            for (jj = 1; jj + 1 < n; jj++) {
                int v = in[jj - 1] + in[jj] + in[jj + 1];
                if (v > 0) out[jj] = (short)((v + 2) / 3);
                else if (v < 0) out[jj] = (short)((v - 2) / 3);
                else out[jj] = 0;
            }
            out[jj] = in[jj];
            for (k = 0; k < nqrs; k++) {
                subzone *z = subz[(size_t)k].get();
                if (z != nullptr && z->type == 0) {
                    // restore unfiltered samples within protected zones and
                    // adjacent samples on either end of protected zones
                    long long j0 = std::max(z->t0 - 1, 0LL);
                    long long j1 = std::min(z->t2 + 2, (long long)out.size());
                    for (long long jx = j0; jx < j1; jx++)
                        out[(size_t)jx] = in[(size_t)jx];
                }
            }
        }
        ecg[(size_t)i] = std::move(outp);
    }

    // Add the reference beats back into the residuals to obtain the raw ECG
    if (bflag == 0) { // true unless -b debugging option was given
        for (k = 0; k < nqrs; k++) {
            subzone *z = subz[(size_t)k].get();
            for (i = 0; z != nullptr && z->type == 0 && i < nleads; i++) {
                int m;
                if (z->t2 - z->t0 + 1 > rblen ||
                    (m = i32(fcM - z->t1 + z->t0 - 1)) < 0) {
                    std::fprintf(stderr, "error: subtraction zone is larger"
                                 " than template\n");
                    std::exit(1);
                }
                Sig *sig = sigp(i);
                Sig *ref = ((size_t)i < refbeat.size())
                    ? refbeat[(size_t)i].get() : nullptr;
                if (sig == nullptr || ref == nullptr) continue;
                long long jlo = z->t0 - 1 + shift, jhi = z->t2 - 1 + shift;
                long long mm = m;
                if (jlo < 0) { // skip samples before the start of the signal
                    mm += -jlo;
                    jlo = 0;
                }
                for (long long jx = jlo; jx <= jhi; jx++, mm++) {
                    if ((uint64_t)jx >= sig->size() ||
                        (uint64_t)mm >= ref->size())
                        break;
                    (*sig)[(size_t)jx] =
                        i16((*sig)[(size_t)jx] + (*ref)[(size_t)mm]);
                }
            }
        }
    }

    // wfdb-x: signals that could not be allocated (undefined behavior in C)
    // are read as zeros, and so are samples beyond the end of a signal
    // shorter than lead 0.
    uint64_t n0 = 0;
    if (have_ecg) {
        n0 = !nsamp.empty() ? nsamp[0] : 0;
        nout = n0 = (n0 <= MAXALLOC) ? n0 : 0;
        for (auto &sig : ecg) {
            if (!sig) sig = newsig(0);
            if (sig->size() < n0) sig->resize((size_t)n0, 0);
        }
    }

    // Now calculate the missing leads.  Normally the input contains only two
    // of the three limb leads (I, II, and III) and the missing one (usually
    // III) must be calculated from the other two, using the relationship:
    //          lead III = lead II - lead I
    if (leadIII < 0) { // we need to calculate lead III
        if (leadI >= 0 && leadII >= 0) {
            if (vflag) std::printf(" Calculating lead III\n");
            leadIII = (short)nleads++;
            nsamp[(size_t)leadIII] = std::min(nsampk(leadI), nsampk(leadII));
            Sig &l1 = srcsig(leadI), &l2 = srcsig(leadII),
                &l3 = srcsig(leadIII);
            uint64_t ne = std::min({ nsamp[(size_t)leadIII],
                                     (uint64_t)l1.size(), (uint64_t)l2.size(),
                                     (uint64_t)l3.size() });
            for (uint64_t jx = 0; jx < ne; jx++)
                l3[(size_t)jx] = i16(l2[(size_t)jx] - l1[(size_t)jx]);
        } else if (leadI < 0) {
            if (leadII < 0)
                std::fprintf(stderr, "Leads I, II, and III are missing\n");
            else
                std::fprintf(stderr, "Leads I and III are missing\n");
        } else
            std::fprintf(stderr, "Leads II and III are missing\n");
    } else if (leadII < 0) { // we need to calculate lead II
        if (leadI >= 0) {
            if (vflag) std::printf(" Calculating lead II\n");
            leadII = (short)nleads++;
            nsamp[(size_t)leadII] = std::min(nsampk(leadI), nsampk(leadIII));
            Sig &l1 = srcsig(leadI), &l2 = srcsig(leadII),
                &l3 = srcsig(leadIII);
            for (uint64_t jx = 0; jx < n0; jx++)
                l2[(size_t)jx] = i16(l1[(size_t)jx] + l3[(size_t)jx]);
        } else
            std::fprintf(stderr, "Leads I and II are missing\n");
    } else if (leadI < 0) { // we need to calculate lead I
        if (vflag) std::printf(" Calculating lead I\n");
        leadI = (short)nleads++;
        nsamp[(size_t)leadI] = std::min(nsampk(leadII), nsampk(leadIII));
        Sig &l1 = srcsig(leadI), &l2 = srcsig(leadII),
            &l3 = srcsig(leadIII);
        for (uint64_t jx = 0; jx < n0; jx++)
            l1[(size_t)jx] = i16(l2[(size_t)jx] - l3[(size_t)jx]);
    }

    // We need both lead I and lead II to derive aVR.
    if (aVR < 0) {
        if (leadI >= 0 && leadII >= 0) {
            if (vflag) std::printf(" Calculating lead aVR\n");
            aVR = (short)nleads++;
            nsamp[(size_t)aVR] = std::min(nsampk(leadI), nsampk(leadII));
            Sig &l1 = srcsig(leadI), &l2 = srcsig(leadII),
                &out = srcsig(aVR);
            for (uint64_t jx = 0; jx < n0; jx++)
                out[(size_t)jx] = i16(-cdiv2(l1[(size_t)jx] + l2[(size_t)jx]));
        } else
            std::fprintf(stderr, "Lead aVR cannot be derived\n");
    }

    // We need both lead II and lead III to derive aVL.
    if (aVL < 0) {
        if (leadII >= 0 && leadIII >= 0) {
            if (vflag) std::printf(" Calculating lead aVL\n");
            aVL = (short)nleads++;
            nsamp[(size_t)aVL] = std::min(nsampk(leadII), nsampk(leadIII));
            Sig &l2 = srcsig(leadII), &l3 = srcsig(leadIII),
                &out = srcsig(aVL);
            for (uint64_t jx = 0; jx < n0; jx++)
                out[(size_t)jx] = i16(cdiv2(l2[(size_t)jx]) - l3[(size_t)jx]);
        } else
            std::fprintf(stderr, "Lead aVL cannot be derived\n");
    }

    // We need both lead I and lead III to derive aVF.
    if (aVF < 0) {
        if (leadI >= 0 && leadII >= 0) {
            if (vflag) std::printf(" Calculating lead aVF\n");
            aVF = (short)nleads++;
            nsamp[(size_t)aVF] = std::min(nsampk(leadI), nsampk(leadIII));
            Sig &l1 = srcsig(leadI), &l3 = srcsig(leadIII),
                &out = srcsig(aVF);
            for (uint64_t jx = 0; jx < n0; jx++)
                out[(size_t)jx] = i16(cdiv2(l1[(size_t)jx]) + l3[(size_t)jx]);
        } else
            std::fprintf(stderr, "Lead aVF cannot be derived\n");
    }

    if (V1 < 0) std::fprintf(stderr, "Lead V1 is missing\n");
    if (V2 < 0) std::fprintf(stderr, "Lead V2 is missing\n");
    if (V3 < 0) std::fprintf(stderr, "Lead V3 is missing\n");
    if (V4 < 0) std::fprintf(stderr, "Lead V4 is missing\n");
    if (V5 < 0) std::fprintf(stderr, "Lead V5 is missing\n");
    if (V6 < 0) std::fprintf(stderr, "Lead V6 is missing\n");

    if (nleads > 0 && (leadI < 0 || leadII < 0 || leadIII < 0 ||
                       aVR < 0 || aVF < 0 || aVL < 0 ||
                       V1 < 0 || V2 < 0 || V3 < 0 ||
                       V4 < 0 || V5 < 0 || V6 < 0)) {
        // Use an array of zero samples for the missing lead(s).
        if (!ecg[(size_t)nleads]) ecg[(size_t)nleads] = newsig(0);
        short nl = (short)nleads;
        if (leadI < 0) leadI = nl;
        if (leadII < 0) leadII = nl;
        if (leadIII < 0) leadIII = nl;
        if (aVR < 0) aVR = nl;
        if (aVF < 0) aVF = nl;
        if (aVL < 0) aVL = nl;
        if (V1 < 0) V1 = nl;
        if (V2 < 0) V2 = nl;
        if (V3 < 0) V3 = nl;
        if (V4 < 0) V4 = nl;
        if (V5 < 0) V5 = nl;
        if (V6 < 0) V6 = nl;
    }

    if (aflag) {
        // Recalculate the top-level CRC.
        crc = getcrc(2, (long long)bytesread - 2);
        put16(crc, 0);
        std::fwrite(data.data(), 1, (size_t)bytesread, stdout);
    } else if (nleads > 0) {
        write_output();
    }

    std::exit(0);
}
