// signal.cpp: signal I/O functions of the WFDB library
// (C++ port of lib/signal.c, WFDB 10.7.0)
//
// This file contains the functions that read header files (including EDF
// headers), read and write signal files in every WFDB storage format
// (0, 8, 16, 61, 80, 160, 212, 310, 311, 24, 32, and the FLAC formats 508,
// 516, and 524), handle multi-segment and multi-frequency records, write
// header and info files, and convert times, dates, and amplitudes.  The
// global state of the C library (the open record and signals) is kept, so
// that the behavior of the C library is reproduced exactly.
//
// FLAC signal files are decoded and encoded by flac.cpp, wfdb-x's own codec
// (the C library uses libFLAC); the functions that connect it to the signal
// functions (flac_isopen, flac_getsamp, ...) port the FLAC support of
// signal.c.
//
// Copyright (C) 1989-2013 George B. Moody (original C implementation,
// lib/signal.c; revised 2011-2022 by Benjamin Moody, including FLAC support,
// 2020).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md. The original behavior
// remains available with --legacy (see docs/DIVERGENCES.md).
// Design decision (Reza Sameni, Oct 2026): the signal files and segments
// named in a header are in the directory of that header (on disk or at its
// URL), or below it; nothing is searched (the C library searched the WFDB
// path), because a search can silently open the wrong file, and a header must
// not make the library read other local files or contact other servers. The
// original behavior remains available with --legacy (see docs/DIVERGENCES.md).
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

#include "wfdblib.hpp"
#include "flac.hpp"

#include <algorithm>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <limits>
#include <sys/stat.h>
#include <sys/types.h>

#if defined(_WIN32)
#include <io.h>         // wfdb-x: for file_id
#include <windows.h>
#endif

namespace wfdbx {
namespace detail {

namespace {

constexpr int WFDB_BUFSIZ = 8192;   // BUFSIZ of the reference platform
constexpr int BUFLN = 4096;         // size of the sample() buffer (power of 2)

// Value ranges of the N-bit two's complement samples stored by the signal
// formats.  The smallest value of each range marks an invalid sample in the
// file (getvec returns WFDB_INVALID_SAMPLE instead).
constexpr int SAMP8_MIN = -0x80, SAMP8_MAX = 0x7f;              // 80, 508; 8
constexpr int SAMP10_MIN = -0x200, SAMP10_MAX = 0x1ff;          // 310, 311
constexpr int SAMP12_MIN = -0x800, SAMP12_MAX = 0x7ff;          // 212
constexpr int SAMP16_MIN = -0x8000, SAMP16_MAX = 0x7fff;        // 16, 61, 160, 516
constexpr int SAMP24_MIN = -0x800000, SAMP24_MAX = 0x7fffff;    // 24, 524

// The FLAC formats are numbered FLAC_FMT_BASE + bits per sample (508, 516,
// 524); the C library reserves 500 to 532 for them.
constexpr int FLAC_FMT_BASE = 500;
constexpr int FLAC_FMT_MAXBITS = 32;

constexpr size_t FLAC_READ_CHUNK = 65536;   // bytes read at a time by flac_decode

// EDF headers: a fixed part of EDF_HDR_RECORD bytes, followed by
// EDF_HDR_RECORD bytes per signal; no field is longer than EDF_MAXFIELD.
constexpr int EDF_HDR_RECORD = 256;
constexpr int EDF_MAXFIELD = 80;

// ---------------------------------------------------------------------------
// C arithmetic helpers (32-bit wrap-around, x86 conversions)

inline int iadd(int a, int b)
{
    return static_cast<int>(static_cast<unsigned>(a) + static_cast<unsigned>(b));
}

inline int isub(int a, int b)
{
    return static_cast<int>(static_cast<unsigned>(a) - static_cast<unsigned>(b));
}

inline int ishl(int a, int n)
{
    return static_cast<int>(static_cast<unsigned>(a) << n);
}

// Conversion of a double to int as on x86 (INT_MIN if out of range).
inline int d2i(double x)
{
    if (!(x > -2147483649.0 && x < 2147483648.0)) return INT_MIN;
    return static_cast<int>(x);
}

// strtok() with an explicit state pointer (same semantics as glibc).
char *xstrtok(char *s, const char *delim, char **save)
{
    if (s == nullptr) s = *save;
    if (s == nullptr) return nullptr;
    s += std::strspn(s, delim);
    if (*s == '\0') {
        *save = s;
        return nullptr;
    }
    char *e = s + std::strcspn(s, delim);
    if (*e) {
        *e = '\0';
        *save = e + 1;
    } else
        *save = e;
    return s;
}

// Apply strtok(s, delim) to a string in place: returns the first token (if
// any) and leaves `s` as strtok leaves it (truncated after the token).
std::optional<std::string> strtok_inplace(std::string &s, const char *delim)
{
    std::string c(s.c_str());
    size_t i = c.find_first_not_of(delim);
    if (i == std::string::npos) return std::nullopt;
    size_t j = c.find_first_of(delim, i);
    if (j == std::string::npos) j = c.size();
    std::string tok = c.substr(i, j - i);
    s = c.substr(0, j);
    return tok;
}

// ---------------------------------------------------------------------------
// Data structures

struct HSData {             // signal information from a header
    WFDB_Siginfo info;
    long start = 0;         // signal file byte offset to sample 0
    int skew = 0;           // intersignal skew (in frames)
};

struct ISData {             // unique for each input signal
    WFDB_Siginfo info;
    WFDB_Sample samp = 0;   // most recent sample read
    int skew = 0;           // intersignal skew (in frames)
    int gvindex = 0;        // current high-resolution sample number
    int gvcount = 0;        // counter for updating gvindex
};

// Decoded FLAC input (one signal group)
struct FlacIn {
    int nsig = 0;           // number of signals in the group
    int datb = 0;           // resolution of the group (8, 16, or 24)
    int spf = 0;            // samples per signal per frame
    bool decoded = false;   // the stream has been decoded
    bool failed = false;    // decoding failed
    std::vector<std::vector<int32_t>> chans;
    long long total = 0;    // samples per channel
    // Position in frame order: frame f, channel c, sample k within frame,
    // relative to sample number `base` of each channel.
    long long base = 0, nfr = 0, leftover = 0, f = 0;
    size_t c = 0;
    int k = 0;
    bool md5_check = false;
    bool has_md5 = false;
    unsigned char md5[16] = {};
    bool have_decoded_md5 = false;
    unsigned char decoded_md5[16] = {};
    bool seeked = false;
    // State of the libFLAC decoder of the C library, which decodes one FLAC
    // block at a time: the end of each block (in samples per channel), the
    // end of the blocks decoded so far, whether the buffered samples were
    // discarded by a failed seek, and whether decoding was aborted (after a
    // failed seek, iflac_samples() aborts the decoding of the next block,
    // and libFLAC then refuses to seek).
    std::vector<long long> block_ends;
    long long dec_end = 0;
    bool discarded = false;
    bool aborted = false;
};

struct IGData {             // shared by all signals in a group (file)
    int data = 0;           // raw data read by r*()
    int datb = 0;           // more raw data used for bit-packed formats
    FilePtr fp;             // file pointer for an input signal group
    long start = 0;         // signal file byte offset to sample 0
    int bsize = 0;          // if non-zero, all reads are in multiples of bsize
    std::vector<char> buf;  // input buffer
    char *bp = nullptr;     // next location in buf
    char *be = nullptr;     // input buffer endpoint
    std::unique_ptr<FlacIn> flac;
    int count = 0;          // input counter for bit-packed signal
    int seek = 0;           // 0: do not seek on file, 1: seeks permitted
    int initial_skip = 0;   // 1 if isgsetframe is needed before reading
    int stat = 0;           // signal file status flag
};

struct OSData {             // unique for each output signal
    WFDB_Siginfo info;
    WFDB_Sample samp = 0;   // most recent sample written
    int skew = 0;           // skew to be written by setheader()
};

struct FlacOut {
    flac::Encoder enc;
    long header_pos = 0;
    std::string pending;
    FlacOut(int nsig, int bps, int spf) : enc(nsig, bps, spf) {}
};

struct OGData {             // shared by all signals in a group (file)
    int data = 0;           // raw data to be written by w*()
    int datb = 0;           // more raw data used for bit-packed formats
    FilePtr fp;             // file pointer for output signal
    long start = 0;         // byte offset to be written by setheader()
    int bsize = 0;          // if non-zero, all writes are in multiples of bsize
    std::vector<char> buf;  // output buffer
    char *bp = nullptr;     // next location in buf
    char *be = nullptr;     // output buffer endpoint
    std::unique_ptr<FlacOut> flac;
    int count = 0;          // output counter for bit-packed signal
    int seek = 0;           // 1: seek works, -1: seek doesn't work, 0: unknown
    int force_flush = 0;    // flush even if seek doesn't work
    int nrewind = 0;        // number of bytes to seek backwards after flushing
};

struct SigMapInfo {
    std::string desc;
    double gain = 0, scale = 0, offset = 0;
    WFDB_Sample sample_offset = 0;
    WFDB_Sample baseline = 0;
    int index = 0;
    int spf = 0;
};

// ---------------------------------------------------------------------------
// Shared local data (the file-scope variables of signal.c)

// wfdb-x: legacy mode.  By default, the library has no built-in signal
// parameters (see docs/DIVERGENCES.md).  In legacy mode (wfdbx_set_legacy(1),
// or --legacy as the first argument of a tool, see wfdbx_legacy_args), it
// behaves exactly as the original WFDB library 10.7.0, with its built-in
// defaults: WFDB_DEFFREQ for a header without a sampling frequency, an ADC
// resolution inferred from the format or WFDB_DEFRES, 1 sample per second in
// the time conversion functions, and WFDB_DEFGAIN (and a baseline of 0 for
// invalid signal numbers) in the unit conversion functions.  It exists for
// compatibility only.
bool legacy_mode = false;

// wfdb-x: files named in a header.  In normal mode, the signal files named in
// a header, and the segments (and layout header) named in the header of a
// multi-segment record, are in the directory of that header, or below it:
// "a.dat" is <header directory>/a.dat; a name that is absolute, begins with
// '~', is a URL, or contains a ".." component is refused (except "~" as a
// segment, a null segment, and "-" as a signal file, the standard input).
// See wfdbx_open_in.
std::optional<std::string> hdr_dir;     // directory of the header read last
                                        // by readheader (see wfdbx_dirname;
                                        // nullopt for the standard input)
std::optional<std::string> msrec_dir;   // directory and name of the header
std::optional<std::string> msrec_name;  // of the current multi-segment
                                        // record (msrec_name: if any)
bool user_segments = false;
bool checksum_quiet = false;            // see wfdbx_set_checksum_quiet             // true while setmsheader reads the
                                        // headers of the segments it was given

// Set by readheader
std::vector<HSData> hsd;            // signals described in the header
FilePtr hheader;                    // header file
std::string linebuf;                // header line buffer

WFDB_Frequency ffreq;   // frame rate (frames/second)
WFDB_Frequency ifreq;   // samples/second/signal returned by getvec
WFDB_Frequency sfreq;   // samples/second/signal read by getvec
WFDB_Frequency cfreq;   // counter frequency (ticks/second)
int spfmax;             // max number of samples per frame
long btime;             // base time (milliseconds since midnight)
WFDB_Date bdate;        // base date (Julian date)
WFDB_Time nsamples;     // duration of signals (in samples)
double bcount;          // base count (counter value at sample 0)
long prolog_bytes;      // length of prolog, as told to wfdbsetstart

// Multi-segment records
int segments;           // number of segments found by readheader()
int in_msrec;           // current input record is multi-segment
long msbtime;           // base time for multi-segment record
WFDB_Date msbdate;      // base date for multi-segment record
WFDB_Time msnsamples;   // duration of multi-segment record
std::vector<WFDB_Seginfo> segarray;
bool have_segarray;     // segarray != NULL
int segp = -1, segend = -1;     // current and last segments (indices)

// Open input signals
std::vector<std::unique_ptr<ISData>> isd;   // size is maxisig
std::vector<std::unique_ptr<IGData>> igd;   // size is maxigroup
unsigned nisig;         // number of open input signals
unsigned nigroup;       // number of open input signal groups
unsigned ispfmax;       // max number of samples of any open signal per frame
std::vector<WFDB_Sample> tvector;   // getvec workspace
std::vector<WFDB_Sample> uvector;   // isgsettime workspace
std::vector<WFDB_Sample> vvector;   // tnextvec workspace
int tuvlen;             // lengths of tvector and uvector in samples
WFDB_Time istime;       // time of next input sample
int ibsize;             // default input buffer size
unsigned skewmax;       // max skew (frames) between any 2 signals
std::vector<WFDB_Sample> dsbuf;     // deskewing buffer
bool have_dsbuf;        // dsbuf != NULL
int dsbi;               // index to oldest sample in dsbuf
unsigned dsblen;        // capacity of dsbuf, in samples
unsigned framelen;      // total number of samples per frame
int gvmode = DEFWFDBGVMODE;     // getvec mode
int gvc;                // getvec sample-within-frame counter
int isedf;              // if non-zero, record is stored as EDF/EDF+
std::vector<WFDB_Sample> sbuf;  // buffer used by sample()
bool have_sbuf;
int sample_vflag;       // if non-zero, last value returned by sample() valid

// Output signals
std::vector<std::unique_ptr<OSData>> osd;   // size is maxosig
std::vector<std::unique_ptr<OGData>> ogd;   // size is maxogroup
unsigned nosig;         // number of open output signals
unsigned nogroup;       // number of open output signal groups
FilePtr oheader;        // output header file
FilePtr outinfo_file;   // output info file (if not the header file)
WFDBFile *outinfo;      // output info file (oheader or outinfo_file)
WFDB_Time ostime;       // time of next output sample
int obsize;             // default output buffer size

// Info strings
std::vector<std::string> pinfo;
bool have_pinfo;        // pinfo != NULL
int ninfo;              // number of info strings read
int info_i;             // index of the next info string

// Variable-layout multi-segment records
int need_sigmap, nvsig, tspf, vspfmax;
std::vector<std::unique_ptr<ISData>> vsd;   // size is maxvsig
std::vector<WFDB_Sample> ovec;
std::vector<SigMapInfo> smi;

// getvec resampling (setifreq)
long mticks, nticks, mnticks;
int rgvstat;
WFDB_Time rgvtime, gvtime;
std::vector<WFDB_Sample> gv0, gv1;
int rgetvec_stat;

// Time and date strings
char date_string[37];
char time_string[62];
WFDB_Date pdays = -1;

// sample()
WFDB_Sample sample_v;
WFDB_Time sample_tt;

// Forward declarations
std::string ftimstr(WFDB_Time t, WFDB_Frequency f);
const char *fmstimstr(WFDB_Time t, WFDB_Frequency f);
WFDB_Time fstrtim(const char *string, WFDB_Frequency f);
int rgetvec(WFDB_Sample *vector);

// ---------------------------------------------------------------------------
// Workspace allocation

unsigned allocisig(unsigned n)
{
    while (isd.size() < n) isd.push_back(std::make_unique<ISData>());
    return static_cast<unsigned>(isd.size());
}

unsigned allocigroup(unsigned n)
{
    while (igd.size() < n) igd.push_back(std::make_unique<IGData>());
    return static_cast<unsigned>(igd.size());
}

unsigned allocosig(unsigned n)
{
    while (osd.size() < n) osd.push_back(std::make_unique<OSData>());
    return static_cast<unsigned>(osd.size());
}

unsigned allocogroup(unsigned n)
{
    while (ogd.size() < n) ogd.push_back(std::make_unique<OGData>());
    return static_cast<unsigned>(ogd.size());
}

bool isfmt(int f)
{
    for (int i = 0; i < WFDB_NFMTS; i++)
        if (f == WFDB_FMT_LIST[i]) return true;
    return false;
}

bool isflacfmt(int f)
{
    return f >= FLAC_FMT_BASE && f <= FLAC_FMT_BASE + FLAC_FMT_MAXBITS;
}

const char *cstr(const std::optional<std::string> &s)
{
    return s ? s->c_str() : nullptr;
}

const char *cstr_or_null(const std::optional<std::string> &s)
{
    return s ? s->c_str() : "(null)";
}

// ---------------------------------------------------------------------------
// Variable-layout multi-segment records (see signal.c for a description)

void sigmap_cleanup()
{
    need_sigmap = nvsig = tspf = vspfmax = 0;
    ovec.clear();
    smi.clear();
    vsd.clear();
}

int make_vsd()
{
    if (nvsig != static_cast<int>(nisig)) {
        wfdb_error("make_vsd: oops! nvsig = %d, nisig = %d\n", nvsig, nisig);
        return -1;
    }
    for (auto &v : vsd) {
        v->info.fname.reset();
        v->info.desc.reset();
        v->info.units.reset();
    }
    while (static_cast<int>(vsd.size()) < nvsig)
        vsd.push_back(std::make_unique<ISData>());
    for (int i = 0; i < nvsig; i++) {
        vsd[i]->info = isd[i]->info;
        vsd[i]->skew = isd[i]->skew;
    }
    return nvsig;
}

std::string segname()
{
    if (have_segarray && segp >= 0 && segp < static_cast<int>(segarray.size()))
        return segarray[segp].recname;
    return std::string();
}

int sigmap_init(int first_segment)
{
    if (in_msrec && first_segment && have_segarray && !segarray.empty() &&
        segarray[0].nsamp == 0) {
        // This is the layout segment: set up the output side of the map.
        need_sigmap = 1;
        nvsig = static_cast<int>(nisig);
        vspfmax = static_cast<int>(ispfmax);
        tspf = 0;
        for (unsigned s = 0; s < nisig; s++) tspf += isd[s]->info.spf;
        smi.assign(tspf, SigMapInfo());
        for (unsigned i = 0, s = 0; i < nisig; i++) {
            smi[s].desc = isd[i]->info.desc.value_or("");
            smi[s].gain = isd[i]->info.gain;
            smi[s].baseline = isd[i]->info.baseline;
            int k = smi[s].spf = isd[i]->info.spf;
            for (int j = 1; j < k; j++) smi[s + j] = smi[s];
            s += k;
        }
        ovec.assign(tspf, 0);
        return make_vsd();
    } else if (need_sigmap) {   // set up the input side of the map
        for (int s = 0; s < tspf; s++) {
            smi[s].index = 0;
            smi[s].scale = 0.;
            smi[s].offset = 0.;
            smi[s].sample_offset = WFDB_INVALID_SAMPLE;
        }
        ispfmax = vspfmax;

        if (isd[0]->info.fmt == 0 && nisig == 1)
            return 0;   // the current segment is a null record

        int j = 0;
        for (unsigned i = 0; i < nisig; j += isd[i++]->info.spf) {
            const WFDB_Siginfo &ii = isd[i]->info;
            for (int s = 0; s < tspf; s += smi[s].spf) {
                if (smi[s].desc == ii.desc.value_or("")) {
                    int kmax = smi[s].spf;
                    if (kmax != ii.spf) {
                        wfdb_error("sigmap_init: unexpected spf for signal %d "
                                   "in segment %s\n", i, segname().c_str());
                        if (kmax > ii.spf) kmax = ii.spf;
                    }
                    for (int k = 0; k < kmax; k++) {
                        SigMapInfo *ps = &smi[s + k];
                        ps->index = j + k;
                        ps->scale = ps->gain / ii.gain;
                        if (ps->scale < 1.0)
                            wfdb_error("sigmap_init: loss of precision in "
                                       "signal %d in segment %s\n", i,
                                       segname().c_str());
                        ps->offset = ps->baseline - ps->scale * ii.baseline + 0.5;

                        // If it is possible to add an additional offset
                        // such that all possible output values will fit
                        // into a positive signed integer, the "fast" case
                        // can be used in sigmap.
                        int ivmin, ivmax;
                        switch (ii.fmt) {
                        case 508:
                        case 80: ivmin = SAMP8_MIN; ivmax = SAMP8_MAX; break;
                        case 310:
                        case 311: ivmin = SAMP10_MIN; ivmax = SAMP10_MAX; break;
                        case 212: ivmin = SAMP12_MIN; ivmax = SAMP12_MAX; break;
                        case 16:
                        case 61:
                        case 516:
                        case 160: ivmin = SAMP16_MIN; ivmax = SAMP16_MAX; break;
                        case 524:
                        case 24: ivmin = SAMP24_MIN; ivmax = SAMP24_MAX; break;
                        default:
                            ivmin = WFDB_SAMPLE_MIN;
                            ivmax = WFDB_SAMPLE_MAX;
                            break;
                        }
                        double ovmin = ivmin * ps->scale + ps->offset;
                        double ovmax = ivmax * ps->scale + ps->offset;
                        if (ovmin < ovmax &&
                            ovmin >= WFDB_SAMPLE_MIN + 1.0 &&
                            ovmax <= WFDB_SAMPLE_MAX &&
                            ovmax - ovmin + 1 < WFDB_SAMPLE_MAX) {
                            ps->sample_offset = d2i(ovmin - 1);
                            ps->offset -= ps->sample_offset;
                        } else {
                            ps->sample_offset = 0;
                        }
                    }
                    break;
                }
            }
        }
        if (j > tspf) {
            wfdb_error("sigmap_init: frame size too large in segment %s\n",
                       segname().c_str());
            return -1;
        }
    } else if (in_msrec && !first_segment && framelen == 0) {
        // opening a new segment of a fixed-layout multisegment record
        ispfmax = vspfmax;
        if (static_cast<int>(nisig) > nvsig) {
            wfdb_error("sigmap_init: wrong number of signals in segment %s\n",
                       segname().c_str());
            return -1;
        }
        for (unsigned i = 0; i < nisig; i++) {
            if (isd[i]->info.spf != vsd[i]->info.spf) {
                wfdb_error("sigmap_init: wrong spf for signal %d in segment "
                           "%s\n", i, segname().c_str());
                return -1;
            }
        }
    } else {    // normal record, or multisegment record without a layout
        nvsig = static_cast<int>(nisig);
        vspfmax = static_cast<int>(ispfmax);
        tspf = 0;
        for (unsigned s = 0; s < nisig; s++) tspf += isd[s]->info.spf;
        return make_vsd();
    }
    return 0;
}

void sigmap(WFDB_Sample *vector, const WFDB_Sample *ivec)
{
    for (int i = 0; i < tspf; i++) {
        const SigMapInfo &m = smi[i];
        WFDB_Sample x = ivec[m.index];
        if (x == WFDB_INVALID_SAMPLE)
            vector[i] = WFDB_INVALID_SAMPLE;
        else {
            // Scale the input sample and round it to the nearest integer
            // (halfway cases are rounded up; m.offset includes 0.5).
            double v = x * m.scale + m.offset;
            if (m.sample_offset) {
                vector[i] = iadd(d2i(v), m.sample_offset);
            } else if (v >= 0) {
                if (v <= WFDB_SAMPLE_MAX)
                    vector[i] = static_cast<WFDB_Sample>(v);
                else
                    vector[i] = WFDB_SAMPLE_MAX;
            } else {
                if (v >= WFDB_SAMPLE_MIN) {
                    vector[i] = static_cast<WFDB_Sample>(v);
                    if (vector[i] > v) vector[i]--;
                } else {
                    vector[i] = WFDB_SAMPLE_MIN;
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Header files

// Read a fixed-size character field and remove trailing spaces.
void read_edf_str(char *buf, int size, WFDBFile *ifile)
{
    if (ifile->read(buf, 1, size) != static_cast<size_t>(size)) {
        *buf = 0;
    } else {
        while (size > 0 && buf[size - 1] == ' ') size--;
        buf[size] = 0;
    }
}

// wfdb-x: open the header (of type s: "hea", or nullptr for a file name) of a
// record, or of a segment named in the header of the current multi-segment
// record, and note its directory (see hdr_dir).
FilePtr open_header(const char *s, const char *record)
{
    if (legacy_mode) return wfdb_open(s, record, WFDB_READ);
    if (!in_msrec) {
        msrec_dir.reset();
        msrec_name.reset();
    }
    FilePtr f = (in_msrec && msrec_name && !user_segments)
        ? wfdbx_open_in(msrec_dir, s, record, msrec_name->c_str())
        : wfdb_open(s, record, WFDB_READ);
    hdr_dir.reset();
    if (f && !f->is_std()) hdr_dir = wfdbx_dirname(wfdb_filename());
    return f;
}

// Get header information from an EDF file.
int edfparse(WFDBFile *ifile)
{
    char buf[EDF_MAXFIELD + 1] = {};
    double spr, baseline;
    int format, nsig = 0, offset = 0, day = 0, month = 0, year = 0, hour = 0,
        minute = 0, second = 0;
    long adcrange, nframes = 0;

    std::string fnamebuf = wfdb_filename();
    const char *edf_fname = fnamebuf.c_str();

    // Read the first 8 bytes and check for the magic string.
    ifile->read(buf, 1, 8);
    if (std::strncmp(buf, "0       ", 8) == 0)
        format = 16;    // EDF or EDF+
    else if (std::strncmp(buf + 1, "BIOSEMI", 7) == 0)
        format = 24;    // BDF
    else {
        wfdb_error("init: '%s' is not EDF or EDF+\n", edf_fname);
        return -2;
    }

    // Read the remainder of the fixed-size section of the header.
    read_edf_str(buf, 80, ifile);       // patient ID (ignored)
    read_edf_str(buf, 80, ifile);       // recording ID (ignored)
    read_edf_str(buf, 8, ifile);        // recording date
    std::sscanf(buf, "%d%*c%d%*c%d", &day, &month, &year);
    year += 1900;                       // EDF has only two-digit years
    if (year < 1985) year += 100;      // (as in C: fix this before 2085!)
    read_edf_str(buf, 8, ifile);        // recording time
    std::sscanf(buf, "%d%*c%d%*c%d", &hour, &minute, &second);
    read_edf_str(buf, 8, ifile);        // number of bytes in header
    std::sscanf(buf, "%d", &offset);
    read_edf_str(buf, 44, ifile);       // free space (ignored)
    read_edf_str(buf, 8, ifile);        // number of frames (EDF blocks)
    std::sscanf(buf, "%ld", &nframes);
    if (nframes < 0) nframes = 0;
    nsamples = nframes;
    spr = 0.0;
    read_edf_str(buf, 8, ifile);        // data record duration (seconds)
    std::sscanf(buf, "%lf", &spr);
    if (spr <= 0.0) spr = 1.0;
    ifile->read(buf + 4, 1, 4);         // number of signals
    std::sscanf(buf + 4, "%d", &nsig);

    if (nsig < 1 || (nsig + 1) * EDF_HDR_RECORD != offset) {
        wfdb_error("init: '%s' is not EDF or EDF+\n", edf_fname);
        return -2;
    }

    // Allocate workspace.
    if (hsd.size() < static_cast<size_t>(nsig)) hsd.resize(nsig);
    std::vector<long> dmax(nsig, 0), dmin(nsig, 0);
    std::vector<double> pmax(nsig, 0.0), pmin(nsig, 0.0);

    // Strip off any path info from the EDF file name.
    const char *p = edf_fname + std::strlen(edf_fname) - 4;
    while (--p > edf_fname)
        if (*p == '/') edf_fname = p + 1;

    // Read the variable-size section of the header.
    for (int s = 0; s < nsig; s++) {
        hsd[s].start = offset;
        hsd[s].skew = 0;
        hsd[s].info.fname = std::string(edf_fname);
        hsd[s].info.group = 0;
        hsd[s].info.bsize = hsd[s].info.cksum = 0;
        hsd[s].info.fmt = format;
        hsd[s].info.nsamp = nframes;
        read_edf_str(buf, 16, ifile);   // signal type
        hsd[s].info.desc = std::string(buf);
    }
    for (int s = 0; s < nsig; s++)
        read_edf_str(buf, 80, ifile);   // transducer type (ignored)
    for (int s = 0; s < nsig; s++) {
        read_edf_str(buf, 8, ifile);    // signal units
        hsd[s].info.units = std::string(buf);
    }
    for (int s = 0; s < nsig; s++) {
        read_edf_str(buf, 8, ifile);    // physical minimum
        std::sscanf(buf, "%lf", &pmin[s]);
    }
    for (int s = 0; s < nsig; s++) {
        read_edf_str(buf, 8, ifile);    // physical maximum
        std::sscanf(buf, "%lf", &pmax[s]);
    }
    for (int s = 0; s < nsig; s++) {
        read_edf_str(buf, 8, ifile);    // digital minimum
        std::sscanf(buf, "%ld", &dmin[s]);
    }
    for (int s = 0; s < nsig; s++) {
        read_edf_str(buf, 8, ifile);    // digital maximum
        std::sscanf(buf, "%ld", &dmax[s]);
        hsd[s].info.initval = hsd[s].info.adczero =
            static_cast<int>((dmax[s] + 1 + dmin[s]) / 2);
        adcrange = dmax[s] - dmin[s];
        int i;
        for (i = 0; adcrange > 0; i++) adcrange /= 2;
        hsd[s].info.adcres = i;
        if (pmax[s] != pmin[s]) {
            hsd[s].info.gain = (dmax[s] - dmin[s]) / (pmax[s] - pmin[s]);
            baseline = dmax[s] - pmax[s] * hsd[s].info.gain;
            if (baseline >= 0.0)
                hsd[s].info.baseline = d2i(baseline + 0.5);
            else
                hsd[s].info.baseline = d2i(baseline - 0.5);
        } else {    // gain is undefined
            hsd[s].info.gain = 0;
            hsd[s].info.baseline = 0;
        }
    }
    for (int s = 0; s < nsig; s++)
        read_edf_str(buf, 80, ifile);   // filtering information (ignored)
    for (int s = 0; s < nsig; s++) {
        int n = 0;
        read_edf_str(buf, 8, ifile);    // samples per frame (EDF block)
        std::sscanf(buf, "%d", &n);
        if ((hsd[s].info.spf = n) > spfmax) spfmax = n;
    }

    // Close the file (don't bother reading nsig*32 bytes of free space);
    // getinfo must not try to read the EDF file.
    hheader.reset();

    ffreq = 1.0 / spr;  // frame frequency = 1/(seconds per EDF block)
    cfreq = ffreq;      // set sampling and counter frequencies to match
    sfreq = ffreq * spfmax;
    if (getafreq() == 0.0) setafreq(sfreq);
    gvmode |= WFDB_HIGHRES;
    std::snprintf(buf, sizeof(buf), "%02d:%02d:%02d %02d/%02d/%04d",
                  hour, minute, second, day, month, year);
    setbasetime(buf);

    isedf = 1;
    return nsig;
}

int readheader(const char *record)
{
    static const char sep[] = " \t\n\r";
    char *p, *q, *save = nullptr;
    WFDB_Frequency f;
    WFDB_Time ns;
    unsigned int i, nsig;
    WFDB_Signal s;

    // If another input header file was opened, close it.
    hheader.reset();

    spfmax = 1;
    sfreq = ffreq;
    isedf = 0;
    if (std::strcmp(record, "~") == 0) {
        if (in_msrec && !vsd.empty()) {
            hsd.assign(1, HSData());
            hsd[0].info.desc = std::string("~");
            hsd[0].info.spf = 1;
            hsd[0].info.fmt = 0;
            hsd[0].info.nsamp = nsamples = segarray[segp].nsamp;
            return 1;
        }
        return 0;
    }

    // If the final component of the record name includes a '.', assume it
    // is a file name.
    const char *qq = record + std::strlen(record) - 1;
    while (qq > record && *qq != '.' && *qq != '/' && *qq != ':' && *qq != '\\')
        qq--;
    if (*qq == '.') {
        if ((hheader = open_header(nullptr, record)) == nullptr) {
            wfdb_error("init: can't open %s\n", record);
            return -1;
        } else if (std::strcmp(qq + 1, "hea"))  // assume EDF if not '.hea'
            return edfparse(hheader.get());
    }
    // Otherwise, assume the file name is record.hea.
    else if ((hheader = open_header("hea", record)) == nullptr) {
        wfdb_error("init: can't open header for record %s\n", record);
        return -1;
    }

    // Read the first line and check for a magic string.
    if (hheader->getline(linebuf) == 0) {
        wfdb_error("init: record %s header is empty\n", record);
        return -2;
    }
    if (std::strncmp("#wfdb", linebuf.c_str(), 5) == 0) {
        int n, major = 0, minor = 0, release = 0;
        n = std::sscanf(linebuf.c_str() + 5, "%d.%d.%d", &major, &minor,
                        &release);
        if ((n > 0 && major > WFDB_MAJOR) ||
            (n > 1 && major == WFDB_MAJOR && minor > WFDB_MINOR) ||
            (n > 2 && major == WFDB_MAJOR && minor == WFDB_MINOR &&
             release > WFDB_RELEASE)) {
            wfdb_error("init: reading record %s requires WFDB library "
                       "version %d.%d.%d or later\n"
                       "  (the most recent version is always available from "
                       "http://physionet.org)\n",
                       record, major, minor, release);
            return -1;
        }
    }

    // Get the first token (the record name) from the first non-empty,
    // non-comment line.
    while ((p = xstrtok(&linebuf[0], sep, &save)) == nullptr || *p == '#') {
        if (hheader->getline(linebuf) == 0) {
            wfdb_error("init: can't find record name in record %s header\n",
                       record);
            return -2;
        }
    }

    for (q = p + 1; *q && *q != '/'; q++)
        ;
    if (*q == '/') {
        if (in_msrec) {
            wfdb_error("init: record %s cannot be nested in another "
                       "multi-segment record\n", record);
            return -2;
        }
        segments = static_cast<int>(std::strtol(q + 1, nullptr, 10));
        *q = '\0';
    }

    // For local files, be sure that the name (p) within the header file
    // matches the name (record) provided as an argument to this function.
    if (hheader->type() == WFDB_LOCAL && !hheader->is_std() &&
        std::strncmp(p, record, std::strlen(p)) != 0) {
        // If there is a mismatch, check to see if the record argument
        // includes a directory separator; if so, compare only the final
        // portion of the argument against the name in the header file.
        const char *r = record, *q2, *s2;
        for (q2 = s2 = r + std::strlen(r) - 1; r != s2; s2--)
            if (*s2 == '/' || *s2 == '\\' || *s2 == ':') break;
        if (q2 > s2 && (r > s2 || std::strcmp(p, s2 + 1) != 0)) {
            wfdb_error("init: record name in record %s header is incorrect\n",
                       record);
            return -2;
        }
    }

    // Identify which type of header file is being read by trying to get
    // another token from the line which contains the record name.
    if ((p = xstrtok(nullptr, sep, &save)) == nullptr) {
        wfdb_error("init: obsolete format in record %s header\n", record);
        return -2;
    }

    // The second token specifies the number of signals.
    nsig = static_cast<unsigned>(std::strtol(p, nullptr, 10));

    // Determine the frame rate, if present and not set already.
    if ((p = xstrtok(nullptr, sep, &save)) != nullptr) {
        if ((f = std::strtod(p, nullptr)) <= 0.) {
            wfdb_error("init: sampling frequency in record %s header is "
                       "incorrect\n", record);
            return -2;
        }
        if (ffreq > 0. && f != ffreq) {
            wfdb_error("warning (init):\n");
            wfdb_error(" record %s sampling frequency differs", record);
            wfdb_error(" from that of previously opened record\n");
        } else
            ffreq = f;
    }
    // wfdb-x: if the header does not specify the sampling frequency (and the
    // caller has not set one with setsampfreq), it remains unspecified (0);
    // the C library assumed WFDB_DEFFREQ (250 Hz), as legacy mode does.
    else if (legacy_mode && ffreq == 0.)
        ffreq = WFDB_DEFFREQ;

    // Set the sampling rate to the frame rate for now.
    sfreq = ffreq;

    // Determine the counter frequency and the base counter value.
    cfreq = bcount = 0.0;
    if (p) {
        for (; *p && *p != '/'; p++)
            ;
        if (*p == '/') {
            cfreq = std::strtod(++p, nullptr);
            for (; *p && *p != '('; p++)
                ;
            if (*p == '(') bcount = std::strtod(++p, nullptr);
        }
    }
    if (cfreq <= 0.0) cfreq = ffreq;

    // Determine the number of samples per signal, if present and not set
    // already.
    if ((p = xstrtok(nullptr, sep, &save)) != nullptr) {
        if ((ns = std::strtoll(p, nullptr, 10)) < 0) {
            wfdb_error("init: number of samples in record %s header is "
                       "incorrect\n", record);
            return -2;
        }
        if (nsamples == 0)
            nsamples = ns;
        else if (ns > 0 && ns != nsamples && !in_msrec) {
            wfdb_error("warning (init):\n");
            wfdb_error(" record %s duration differs", record);
            wfdb_error(" from that of previously opened record\n");
            // nsamples must match the shortest record duration.
            if (nsamples > ns) nsamples = ns;
        }
    } else
        ns = 0;

    // Determine the base time and date, if present and not set already.
    if ((p = xstrtok(nullptr, "\n\r", &save)) != nullptr && btime == 0L &&
        setbasetime(p) < 0)
        return -2;  // error message will come from setbasetime

    // Special processing for master header of a multi-segment record.
    if (segments && !in_msrec) {
        // wfdb-x: the segments are in the directory of this header
        if (!legacy_mode) {
            msrec_dir = hdr_dir;
            msrec_name = std::string(record);
        }
        msbtime = btime;
        msbdate = bdate;
        msnsamples = nsamples;
        // Read the names and lengths of the segment records.
        segarray.clear();
        have_segarray = true;
        ns = 0;
        for (i = 0; i < static_cast<unsigned>(segments); i++) {
            WFDB_Seginfo seg;
            // Get next segment spec, skip empty lines and comments.
            do {
                if (hheader->getline(linebuf) == 0) {
                    wfdb_error("init: unexpected EOF in header file for "
                               "record %s\n", record);
                    segarray.clear();
                    have_segarray = false;
                    segments = 0;
                    return -2;
                }
            } while ((p = xstrtok(&linebuf[0], sep, &save)) == nullptr ||
                     *p == '#');
            if (*p == '+') {
                wfdb_error("init: `%s' is not a valid segment name in record "
                           "%s\n", p, record);
                segarray.clear();
                have_segarray = false;
                segments = 0;
                return -2;
            }
            if (std::strlen(p) > WFDB_MAXRNL) {
                wfdb_error("init: `%s' is too long for a segment name in "
                           "record %s\n", p, record);
                segarray.clear();
                have_segarray = false;
                segments = 0;
                return -2;
            }
            std::strcpy(seg.recname, p);
            if ((p = xstrtok(nullptr, sep, &save)) == nullptr ||
                (seg.nsamp = std::strtoll(p, nullptr, 10)) < 0) {
                wfdb_error("init: length must be specified for segment %s in "
                           "record %s\n", seg.recname, record);
                segarray.clear();
                have_segarray = false;
                segments = 0;
                return -2;
            }
            seg.samp0 = ns;
            ns += seg.nsamp;
            segarray.push_back(seg);
        }
        segend = static_cast<int>(segarray.size()) - 1;
        segp = 0;
        if (msnsamples == 0)
            msnsamples = ns;
        else if (ns != msnsamples) {
            wfdb_error("warning (init): in record %s, "
                       "stated record length (%lld)\n", record, msnsamples);
            wfdb_error(" does not match sum of segment lengths (%lld)\n", ns);
        }
        return 0;
    }

    // Now get information for each signal.
    for (s = 0; s < nsig; s++) {
        if (hsd.size() <= s) hsd.resize(s + 1);
        HSData *hs = &hsd[s];
        HSData *hp = s ? &hsd[s - 1] : nullptr;
        int nobaseline;

        // Get the first token (the signal file name) from the next
        // non-empty, non-comment line.
        do {
            if (hheader->getline(linebuf) == 0) {
                wfdb_error("init: unexpected EOF in header file for record "
                           "%s\n", record);
                return -2;
            }
        } while ((p = xstrtok(&linebuf[0], sep, &save)) == nullptr ||
                 *p == '#');

        // Determine the signal group number.
        if (s == 0 || std::strcmp(p, cstr_or_null(hp->info.fname))) {
            hs->info.group = (s == 0) ? 0 : hp->info.group + 1;
            hs->info.fname = std::string(p);
        } else {
            hs->info.group = hp->info.group;
            hs->info.fname = hp->info.fname;
        }

        // Determine the signal format.
        if ((p = xstrtok(nullptr, sep, &save)) == nullptr ||
            !isfmt(hs->info.fmt = static_cast<int>(std::strtol(p, nullptr, 10)))) {
            wfdb_error("init: illegal format for signal %d, record %s\n",
                       s, record);
            return -2;
        }
        hs->info.spf = 1;
        hs->skew = 0;
        hs->start = 0;
        // Parse the optional "xSPF", ":SKEW", and "+START" suffixes.  (If
        // the token ends with one of the prefix characters, C reads past its
        // end; the suffix is ignored here.)
        while (*(++p)) {
            if (*p == 'x') {
                if (*(++p)) {
                    if ((hs->info.spf = static_cast<int>(std::strtol(p, nullptr, 10))) < 1)
                        hs->info.spf = 1;
                } else
                    break;
            }
            if (*p == ':') {
                if (*(++p)) {
                    if ((hs->skew = static_cast<int>(std::strtol(p, nullptr, 10))) < 0)
                        hs->skew = 0;
                } else
                    break;
            }
            if (*p == '+') {
                if (*(++p)) {
                    if ((hs->start = std::strtol(p, nullptr, 10)) < 0L)
                        hs->start = 0L;
                } else
                    break;
            }
        }
        if (hs->info.spf > spfmax) spfmax = hs->info.spf;
        // The skew in samples (given in the header) is converted to skew in
        // frames here.
        hs->skew = static_cast<int>((static_cast<double>(hs->skew)) /
                                    hs->info.spf + 0.5);

        // Determine the gain in ADC units per physical unit.
        if ((p = xstrtok(nullptr, sep, &save)) != nullptr)
            hs->info.gain = std::strtod(p, nullptr);
        else
            hs->info.gain = 0.;

        // Determine the baseline if specified, and the physical units.
        nobaseline = 1;
        if (p) {
            for (; *p && *p != '(' && *p != '/'; p++)
                ;
            if (*p == '(') {
                hs->info.baseline = static_cast<int>(std::strtol(++p, nullptr, 10));
                nobaseline = 0;
            }
            while (*p)
                if (*p++ == '/' && *p) break;
        }
        if (p && *p)
            hs->info.units = std::string(p, strnlen(p, WFDB_MAXUSL));
        else
            hs->info.units.reset();

        // Determine the ADC resolution in bits.  wfdb-x: if this number is
        // missing, it is unspecified (0); the C library inferred it from the
        // format or assumed WFDB_DEFRES (12 bits), as legacy mode does.
        if ((p = xstrtok(nullptr, sep, &save)) != nullptr)
            i = static_cast<unsigned>(std::strtol(p, nullptr, 10));
        else if (legacy_mode) switch (hs->info.fmt) {
            case 80: i = 8; break;
            case 160: i = 16; break;
            case 212: i = 12; break;
            case 310: i = 10; break;
            case 311: i = 10; break;
            default: i = WFDB_DEFRES; break;
        }
        else
            i = 0;
        hs->info.adcres = static_cast<int>(i);

        // Determine the ADC zero (assumed to be zero if missing).
        hs->info.adczero = (p = xstrtok(nullptr, sep, &save)) != nullptr ?
            static_cast<int>(std::strtol(p, nullptr, 10)) : 0;

        // Set the baseline to adczero if no baseline field was found.
        if (nobaseline) hs->info.baseline = hs->info.adczero;

        // Determine the initial value.
        hs->info.initval = (p = xstrtok(nullptr, sep, &save)) != nullptr ?
            static_cast<int>(std::strtol(p, nullptr, 10)) : hs->info.adczero;

        // Determine the checksum (assumed to be zero if missing).
        if ((p = xstrtok(nullptr, sep, &save)) != nullptr) {
            hs->info.cksum = static_cast<int>(std::strtol(p, nullptr, 10));
            hs->info.nsamp = (ns > LONG_MAX ? 0 : static_cast<long>(ns));
        } else {
            hs->info.cksum = 0;
            hs->info.nsamp = 0;
        }

        // Determine the block size (assumed to be zero if missing).
        hs->info.bsize = (p = xstrtok(nullptr, sep, &save)) != nullptr ?
            static_cast<int>(std::strtol(p, nullptr, 10)) : 0;

        // Check that formats and block sizes match for signals belonging to
        // the same group.
        if (s && (hp == nullptr || (hs->info.group == hp->info.group &&
                                    (hs->info.fmt != hp->info.fmt ||
                                     hs->info.bsize != hp->info.bsize)))) {
            wfdb_error("init: error in specification of signal %d or %d\n",
                       s - 1, s);
            return -2;
        }

        // Get the signal description.
        if ((p = xstrtok(nullptr, "\n\r", &save)) != nullptr)
            hs->info.desc = std::string(p, strnlen(p, WFDB_MAXDSL));
        else
            hs->info.desc = strprintf("record %s, signal %d", record, s);
    }
    setgvmode(gvmode);  // Reset sfreq if appropriate.
    return static_cast<int>(s);
}

void hsdfree()
{
    hsd.clear();
}

// ---------------------------------------------------------------------------
// FLAC input (glue to flac.cpp; ports of the functions of _flac.py)

void flac_pack(FlacIn &fi, long long base)
{
    fi.base = base;
    fi.nfr = (fi.total - base) / fi.spf;
    fi.leftover = (fi.total - base) - fi.nfr * fi.spf;
    fi.f = 0;
    fi.c = 0;
    fi.k = 0;
}

void flac_decode(IGData *ig)
{
    FlacIn &fi = *ig->flac;
    fi.decoded = true;
    std::vector<unsigned char> data;
    if (ig->fp) {
        unsigned char tmp[FLAC_READ_CHUNK];
        size_t n;
        while ((n = ig->fp->read(tmp, 1, sizeof(tmp))) > 0)
            data.insert(data.end(), tmp, tmp + n);
    }
    flac::Decoded d = flac::decode(data.data(), data.size(), fi.nsig, fi.datb);
    switch (d.status) {
    case flac::Status::ok:
        break;
    case flac::Status::sync:
        wfdb_error("getvec: unable to decode FLAC (lost sync)\n");
        break;
    case flac::Status::header:
        wfdb_error("getvec: unable to decode FLAC (invalid header)\n");
        break;
    case flac::Status::crc:
        wfdb_error("getvec: unable to decode FLAC (CRC mismatch)\n");
        break;
    case flac::Status::unparseable:
        wfdb_error("getvec: unable to decode FLAC (unsupported format)\n");
        break;
    case flac::Status::eof:
        wfdb_error("getvec: unable to decode FLAC\n");
        break;
    case flac::Status::meta:
        wfdb_error("getvec: unexpected FLAC decoding error\n");
        break;
    case flac::Status::wfdb:
        break;      // reported by the decoder
    }
    if (d.status != flac::Status::ok) {
        fi.failed = true;
        return;
    }
    fi.chans = std::move(d.chans);
    fi.block_ends = std::move(d.block_ends);
    fi.total = fi.chans.empty() ? 0 : static_cast<long long>(fi.chans[0].size());
    fi.has_md5 = d.has_md5;
    std::memcpy(fi.md5, d.md5, sizeof(fi.md5));
    if (fi.md5_check && fi.total) {
        flac::samples_md5(fi.chans, d.bps, fi.decoded_md5);
        fi.have_decoded_md5 = true;
    }
    flac_pack(fi, 0);
}

// The end of the FLAC block that contains sample n - 1 (n > 0): the number
// of samples (per channel) decoded once sample n - 1 is.
static long long flac_block_end(const FlacIn &fi, long long n)
{
    auto it = std::lower_bound(fi.block_ends.begin(), fi.block_ends.end(), n);
    return it != fi.block_ends.end() ? *it : fi.total;
}

// Decoding a block after a failed seek (ig->stat < 0): iflac_samples()
// aborts the decoder, and flac_getsamp() reports the error.
static int flac_abort(IGData *ig)
{
    ig->flac->aborted = true;
    if (ig->stat != -2) {
        wfdb_error("getvec: unexpected FLAC decoding error\n");
        ig->stat = -2;
    }
    return 0;
}

int flac_getsamp(IGData *ig)
{
    FlacIn &fi = *ig->flac;
    if (!fi.decoded) flac_decode(ig);
    if (fi.failed) {
        ig->stat = -2;
        return 0;
    }
    if (fi.aborted)
        return 0;       // (the decoder does nothing; ig->stat is negative)
    if (fi.f < fi.nfr) {
        // The frame of the next sample must have been decoded.
        long long need = fi.base + (fi.f + 1) * fi.spf;
        if (fi.discarded || need > fi.dec_end) {
            if (ig->stat < 0)
                return fi.dec_end < fi.total ? flac_abort(ig) : 0;
            fi.dec_end = flac_block_end(fi, need);
        }
        int v = fi.chans[fi.c][fi.base + fi.f * fi.spf + fi.k];
        if (++fi.k == fi.spf) {
            fi.k = 0;
            if (++fi.c == fi.chans.size()) {
                fi.c = 0;
                fi.f++;
            }
        }
        return v;
    }
    if (fi.discarded && fi.dec_end < fi.total)
        return flac_abort(ig);
    if (ig->stat < 0)
        return 0;
    fi.dec_end = fi.total;
    if (fi.leftover) {
        wfdb_error("getvec: warning: %d samples left over at end of file\n",
                   static_cast<int>(fi.leftover));
        fi.leftover = 0;
    }
    ig->stat = 0;
    return 0;
}

int flac_isopen(IGData *ig, const HSData *hs, unsigned ns)
{
    if (ns > static_cast<unsigned>(flac::MAX_CHANNELS)) {
        wfdb_error("isigopen: cannot store %u signals in a single FLAC file\n",
                   ns);
        return -1;
    }
    for (unsigned i = 1; i < ns; i++) {
        if (hs[i].info.spf != hs[0].info.spf) {
            wfdb_error("isigopen: every signal in a FLAC file must have\n"
                       "  the same sampling frequency\n");
            return -1;
        }
    }
    ig->flac = std::make_unique<FlacIn>();
    FlacIn &fi = *ig->flac;
    fi.nsig = static_cast<int>(ns);
    fi.datb = hs[0].info.fmt - FLAC_FMT_BASE;
    fi.spf = hs[0].info.spf;
    const char *p = std::getenv("WFDB_FLAC_CHECK_MD5");
    fi.md5_check = p && *p;
    ig->count = 0;
    return 0;
}

int flac_isclose(IGData *ig)
{
    FlacIn &fi = *ig->flac;
    if (fi.md5_check && fi.has_md5 && fi.have_decoded_md5 && !fi.seeked) {
        bool nonzero = false;
        for (unsigned char b : fi.md5)
            if (b) nonzero = true;
        if (nonzero && std::memcmp(fi.md5, fi.decoded_md5, 16) != 0) {
            wfdb_error("isigclose: warning: incorrect MD5 hash in FLAC "
                       "input\n");
            return -1;
        }
    }
    return 0;
}

int flac_isseek(IGData *ig, WFDB_Time t)
{
    FlacIn &fi = *ig->flac;
    if (!fi.decoded) flac_decode(ig);
    ig->stat = 1;
    ig->count = 0;
    fi.seeked = true;
    if (fi.failed) {
        ig->stat = -1;
        return -1;
    }
    WFDB_Time tt = t * fi.spf + ig->start;
    if (fi.aborted || tt > fi.total || tt < 0) {
        // (libFLAC refuses to seek once decoding was aborted, or past the
        // end of the stream; the buffered samples are discarded anyway)
        fi.discarded = true;
        ig->stat = -1;
        return -1;
    }
    flac_pack(fi, tt);
    fi.discarded = false;
    // The seek decodes the block that contains sample tt - 1 (sample 0 if
    // tt is 0): libFLAC seeks to it, and the first sample is skipped.
    fi.dec_end = flac_block_end(fi, tt > 1 ? tt : 1);
    return ig->stat;
}

// ---------------------------------------------------------------------------
// FLAC output

int flac_putsamp(WFDB_Sample v, int fmt, OGData *g)
{
    switch (fmt) {
    case 508: v = static_cast<int8_t>(static_cast<uint8_t>(v)); break;
    case 516: v = static_cast<int16_t>(static_cast<uint16_t>(v)); break;
    case 524: v = static_cast<int>(static_cast<unsigned>(v) << 8) >> 8; break;
    }
    FlacOut &fo = *g->flac;
    fo.pending.clear();
    fo.enc.put(v, fo.pending);
    if (!fo.pending.empty() && g->fp)
        g->fp->write(fo.pending.data(), 1, fo.pending.size());
    return 0;
}

int flac_osinit(OGData *og, const WFDB_Siginfo *si, unsigned ns)
{
    if (ns > static_cast<unsigned>(flac::MAX_CHANNELS)) {
        wfdb_error("osigfopen: cannot store %u signals in a single FLAC "
                   "file\n", ns);
        return -1;
    }
    for (unsigned i = 1; i < ns; i++) {
        if (si[i].spf != si[0].spf) {
            wfdb_error("osigfopen: every signal in a FLAC file must have\n"
                       "  the same sampling frequency\n");
            return -1;
        }
    }
    int spf = si[0].spf < 1 ? 1 : si[0].spf;
    og->flac = std::make_unique<FlacOut>(static_cast<int>(ns), si[0].fmt - FLAC_FMT_BASE,
                                         spf);
    // Make the buffer exactly large enough to hold a single frame (a
    // non-zero bsize also prevents wfdb_osflush from flushing it).
    og->bsize = static_cast<int>(ns) * si[0].spf * 4;
    return 0;
}

int flac_osopen(OGData *og)
{
    FlacOut &fo = *og->flac;
    std::string hdr = fo.enc.header();
    fo.header_pos = og->fp ? og->fp->tell() : 0;
    if (og->fp) og->fp->write(hdr.data(), 1, hdr.size());
    return 0;
}

int flac_osclose(OGData *og)
{
    FlacOut &fo = *og->flac;
    fo.pending.clear();
    fo.enc.finish(fo.pending);
    if (og->fp) {
        if (!fo.pending.empty())
            og->fp->write(fo.pending.data(), 1, fo.pending.size());
        if (og->fp->seek(fo.header_pos + 8, SEEK_SET) == 0) {
            std::string si = fo.enc.streaminfo();
            og->fp->write(si.data(), 1, si.size());
            og->fp->seek(0, SEEK_END);
        }
    }
    og->flac.reset();
    og->bp = og->be = og->buf.data();
    return 0;
}

// ---------------------------------------------------------------------------
// Closing signals

void isigclose()
{
    if (have_sbuf && !in_msrec) {
        sbuf.clear();
        have_sbuf = false;
        sample_vflag = 0;
    }
    isd.clear();
    nisig = 0;
    framelen = 0;

    while (!igd.empty()) {
        IGData *ig = igd.back().get();
        if (ig->flac) flac_isclose(ig);
        ig->fp.reset();
        igd.pop_back();
    }
    nigroup = 0;

    istime = 0L;
    gvc = 1;
    ispfmax = 1;
    hheader.reset();
    linebuf.clear();
    linebuf.shrink_to_fit();
    if (nosig == 0 && !hsd.empty()) hsdfree();
}

int osigclose()
{
    int stat = 0;

    for (unsigned g = 0; g < nogroup && g < ogd.size(); g++)
        ogd[g]->force_flush = 1;

    wfdb_osflush();

    osd.clear();
    nosig = 0;

    while (!ogd.empty()) {
        OGData *og = ogd.back().get();
        unsigned maxogroup = static_cast<unsigned>(ogd.size()) - 1;
        if (og->fp) {
            if (og->flac) flac_osclose(og);

            // If a block size has been defined, null-pad the buffer.
            if (og->bsize)
                while (og->bp != og->be) *(og->bp++) = '\0';
            // Flush the last block unless it's empty.
            if (og->bp != og->buf.data())
                og->fp->write(og->buf.data(), 1, og->bp - og->buf.data());
            if (og->fp->is_std()) og->fp->flush();
            int errflag = og->fp->error();
            // Close the file (except stdout, which is closed on exit).
            if (!og->fp->is_std()) {
                if (og->fp->close()) errflag = 1;
            }
            og->fp.reset();
            if (errflag) {
                wfdb_error("osigclose: write error in signal group %d\n",
                           maxogroup);
                stat = -4;
            }
        }
        ogd.pop_back();
    }
    nogroup = 0;

    ostime = 0L;
    if (oheader) {
        int errflag = oheader->error();
        if (oheader->close()) errflag = 1;
        if (errflag) {
            wfdb_error("osigclose: write error in header file\n");
            stat = -4;
        }
        if (outinfo == oheader.get()) outinfo = nullptr;
        oheader.reset();
    }
    if (nisig == 0 && !hsd.empty()) hsdfree();

    return stat;
}

// ---------------------------------------------------------------------------
// Low-level I/O routines.  The input routines each get a single argument
// (the signal group).  The output routines get two arguments (the value to
// be written and the signal group).

int r8_fill(IGData *g)
{
    int n = (g->bsize > 0) ? g->bsize : ibsize;
    n = static_cast<int>(g->fp->read(g->buf.data(), 1, n));
    g->stat = n;
    g->bp = g->buf.data();
    g->be = g->bp + n;
    return static_cast<signed char>(*(g->bp++));
}

inline int r8(IGData *g)
{
    if (g->bp < g->be) return static_cast<signed char>(*(g->bp++));
    return r8_fill(g);
}

inline int r16(IGData *g)
{
    if (g->be - g->bp >= 2) {
        const unsigned char *b = reinterpret_cast<const unsigned char *>(g->bp);
        g->bp += 2;
        return static_cast<int16_t>(static_cast<uint16_t>(b[0] | (b[1] << 8)));
    }
    int l = r8(g);
    int h = r8(g);
    return static_cast<int16_t>(static_cast<uint16_t>((h << 8) | (l & 0xff)));
}

inline int r61(IGData *g)
{
    if (g->be - g->bp >= 2) {
        const unsigned char *b = reinterpret_cast<const unsigned char *>(g->bp);
        g->bp += 2;
        return static_cast<int16_t>(static_cast<uint16_t>((b[0] << 8) | b[1]));
    }
    int h = r8(g);
    int l = r8(g);
    return static_cast<int16_t>(static_cast<uint16_t>((l & 0xff) | (h << 8)));
}

inline int r24(IGData *g)
{
    if (g->be - g->bp >= 3) {
        const unsigned char *b = reinterpret_cast<const unsigned char *>(g->bp);
        g->bp += 3;
        unsigned v = b[0] | (b[1] << 8) | (static_cast<unsigned>(b[2]) << 16);
        return static_cast<int>(v << 8) >> 8;
    }
    int lw = r16(g);
    int h = r8(g);
    return static_cast<int>((static_cast<unsigned>(h) << 16) |
                            (static_cast<unsigned>(lw) & 0xffff));
}

inline int r32(IGData *g)
{
    if (g->be - g->bp >= 4) {
        const unsigned char *b = reinterpret_cast<const unsigned char *>(g->bp);
        g->bp += 4;
        return static_cast<int>(b[0] | (b[1] << 8) | (b[2] << 16) |
                                (static_cast<unsigned>(b[3]) << 24));
    }
    int lw = r16(g);
    int h = r16(g);
    return static_cast<int>((static_cast<unsigned>(h) << 16) |
                            (static_cast<unsigned>(lw) & 0xffff));
}

inline int r80(IGData *g)
{
    return (r8(g) & 0xff) - (1 << 7);
}

inline int r160(IGData *g)
{
    return (r16(g) & 0xffff) - (1 << 15);
}

// r212: read the next sample from a format 212 signal file
// (2 12-bit samples bit-packed in 3 bytes)
inline int r212(IGData *g)
{
    int v;
    // Obtain the next 12-bit value right-justified in v.
    if (g->count++ == 0) {
        v = g->data = r16(g);
    } else {
        g->count = 0;
        v = ((g->data >> 4) & 0xf00) | (r8(g) & 0xff);
    }
    // Sign-extend from the twelfth bit.
    if (v & 0x800) v |= ~(0xfff);
    else v &= 0xfff;
    return v;
}

// r310: read the next sample from a format 310 signal file
// (3 10-bit samples bit-packed in 4 bytes)
inline int r310(IGData *g)
{
    int v;
    switch (g->count++) {
    case 0: v = (g->data = r16(g)) >> 1; break;
    case 1: v = (g->datb = r16(g)) >> 1; break;
    case 2:
    default:
        g->count = 0;
        v = ((g->data & 0xf800) >> 11) | ((g->datb & 0xf800) >> 6);
        break;
    }
    // Sign-extend from the tenth bit.
    if (v & 0x200) v |= ~(0x3ff);
    else v &= 0x3ff;
    return v;
}

// r311: read the next sample from a format 311 signal file
inline int r311(IGData *g)
{
    int v;
    switch (g->count++) {
    case 0: v = (g->data = r16(g)); break;
    case 1:
        g->datb = (r8(g) & 0xff);
        v = ((g->data & 0xfc00) >> 10) | ((g->datb & 0xf) << 6);
        break;
    case 2:
    default:
        g->count = 0;
        g->datb |= ishl(r8(g), 8);
        v = g->datb >> 4;
        break;
    }
    // Sign-extend from the tenth bit.
    if (v & 0x200) v |= ~(0x3ff);
    else v &= 0x3ff;
    return v;
}

void w8_flush(OGData *g)
{
    int n = (g->bsize > 0) ? g->bsize : obsize;
    g->bp = g->buf.data();
    if (g->fp) g->fp->write(g->bp, 1, n);
}

inline void w8(int v, OGData *g)
{
    *(g->bp++) = static_cast<char>(v);
    if (g->bp == g->be) w8_flush(g);
}

inline void w16(int v, OGData *g)
{
    w8(v, g);
    w8(v >> 8, g);
}

inline void w61(int v, OGData *g)
{
    w8(v >> 8, g);
    w8(v, g);
}

inline void w24(int v, OGData *g)
{
    w16(v, g);
    w8(v >> 16, g);
}

inline void w32(int v, OGData *g)
{
    w16(v, g);
    w16(v >> 16, g);
}

inline void w80(int v, OGData *g)
{
    w8((v & 0xff) + (1 << 7), g);
}

inline void w160(int v, OGData *g)
{
    w16((v & 0xffff) + (1 << 15), g);
}

// w212: write the next sample to a format 212 signal file
void w212(WFDB_Sample v, OGData *g)
{
    // Samples are buffered here and written in pairs, as three bytes.
    switch (g->count++) {
    case 0: g->data = v & 0xfff; break;
    case 1:
        g->count = 0;
        g->data |= ishl(v, 4) & 0xf000;
        w16(g->data, g);
        w8(v, g);
        break;
    }
}

// f212: flush output to a format 212 signal file
void f212(OGData *g)
{
    // If we have one leftover sample, write it as two bytes.
    if (g->count == 1) {
        w16(g->data, g);
        g->nrewind = 2;
    }
}

// w310: write the next sample to a format 310 signal file
void w310(WFDB_Sample v, OGData *g)
{
    // Samples are buffered here and written in groups of three, as two
    // left-justified 15-bit words.
    switch (g->count++) {
    case 0: g->data = ishl(v, 1) & 0x7fe; break;
    case 1: g->datb = ishl(v, 1) & 0x7fe; break;
    case 2:
    default:
        g->count = 0;
        g->data |= ishl(v, 11);
        w16(g->data, g);
        g->datb |= (ishl(v, 6) & ~0x7fe);
        w16(g->datb, g);
        break;
    }
}

// f310: flush output to a format 310 signal file
void f310(OGData *g)
{
    switch (g->count) {
    case 0: break;
    // If we have one leftover sample, write it as two bytes.
    case 1:
        w16(g->data, g);
        g->nrewind = 2;
        break;
    // If we have two leftover samples, write them as four bytes.  In this
    // case, the file will appear to have an extra (zero) sample at the end.
    case 2:
    default:
        w16(g->data, g);
        w16(g->datb, g);
        g->nrewind = 4;
        break;
    }
}

// w311: write the next sample to a format 311 signal file
void w311(WFDB_Sample v, OGData *g)
{
    // Samples are buffered here and written in groups of three, bit-packed
    // into the 30 low bits of a 32-bit word.
    switch (g->count++) {
    case 0: g->data = v & 0x3ff; break;
    case 1:
        g->data |= ishl(v, 10);
        w16(g->data, g);
        g->datb = (v >> 6) & 0xf;
        break;
    case 2:
    default:
        g->count = 0;
        g->datb |= ishl(v, 4);
        g->datb &= 0x3fff;
        w16(g->datb, g);
        break;
    }
}

// f311: flush output to a format 311 signal file
void f311(OGData *g)
{
    switch (g->count) {
    case 0: break;
    // If we have one leftover sample, write it as two bytes.
    case 1:
        w16(g->data, g);
        g->nrewind = 2;
        break;
    // If we have two leftover samples, write them as four bytes (the first
    // two bytes have been written by w311() already).
    case 2:
    default:
        w16(g->datb, g);
        g->nrewind = 2;
        break;
    }
}

// ---------------------------------------------------------------------------
// Input positioning and reading

int isgsetframe(WFDB_Group g, WFDB_Time t)
{
    int i, trem = 0;
    long nb, tt;
    IGData *ig;
    WFDB_Signal s;
    unsigned int b, d = 1, n, nn, j;

    // Do nothing if there is no more than one input signal group and the
    // input pointer is correct already.
    if (nigroup < 2 && istime == t && gvc == static_cast<int>(ispfmax) &&
        g < igd.size() && igd[g]->start == 0)
        return 0;

    // Find the first signal that belongs to group g.
    for (s = 0; s < nisig && g != isd[s]->info.group; s++)
        ;
    if (s == nisig) {
        wfdb_error("isgsettime: incorrect signal group number %d\n", g);
        return -2;
    }

    // If the current record contains multiple segments, locate the segment
    // containing the desired sample.
    if (in_msrec) {
        int tseg = segp;

        if (t >= msnsamples) {
            wfdb_error("isigsettime: improper seek on signal group %d\n", g);
            return -1;
        }
        while (t < segarray[tseg].samp0) tseg--;
        while (t >= segarray[tseg].samp0 + segarray[tseg].nsamp &&
               tseg < segend)
            tseg++;
        if (segp != tseg) {
            segp = tseg;
            std::string name = segarray[segp].recname;
            if (isigopen(name.c_str(), nullptr, nvsig) <= 0) {
                wfdb_error("isigsettime: can't open segment %s\n",
                           name.c_str());
                return -1;
            }
            // Following isigopen(), nigroup may have changed: seek on all
            // non-zero groups (regardless of g), but on group 0 only if g
            // is 0.
            for (WFDB_Group h = 1; h < nigroup; h++)
                if ((i = isgsetframe(h, t)) != 0) return i;
            if (g == 0)
                return isgsetframe(0, t);
            else
                return 0;
        }
        t -= segarray[segp].samp0;
    }

    ig = igd[g].get();
    ig->initial_skip = 0;
    // Determine the number of samples per frame for signals in the group.
    for (n = nn = 0; s + n < nisig && isd[s + n]->info.group == g; n++)
        nn += isd[s + n]->info.spf;
    // Determine the number of bytes per sample interval in the file.
    switch (isd[s]->info.fmt) {
    case 0:
        if (t < nsamples) {
            gvc = ispfmax;
            if (s == 0) istime = in_msrec ? t + segarray[segp].samp0 : t;
            isd[s]->info.nsamp = static_cast<long>(nsamples - t);
            ig->stat = 1;
            return 0;
        } else {
            if (s == 0) istime = in_msrec ? msnsamples : nsamples;
            isd[s]->info.nsamp = 0L;
            return -1;
        }

    case 508:
    case 516:
    case 524:
        if (flac_isseek(ig, t) < 0) {
            wfdb_error("isigsettime: improper seek on signal group %d\n", g);
            return -1;
        }
        // Reset the getvec sample-within-frame counter.
        gvc = ispfmax;
        // Reset the time (if signal 0 belongs to the group) and disable
        // checksum testing.
        if (s == 0) istime = in_msrec ? t + segarray[segp].samp0 : t;
        while (n-- != 0) isd[s + n]->info.nsamp = 0L;
        return 0;

    case 8:
    case 80:
    default: b = nn; break;
    case 16:
    case 61:
    case 160:
        if (nn > UINT_MAX / 2) {
            wfdb_error("isigsettime: overflow in signal group %d\n", g);
            return -1;
        }
        b = 2 * nn;
        break;
    case 212:
        if (nn > UINT_MAX / 3) {
            wfdb_error("isigsettime: overflow in signal group %d\n", g);
            return -1;
        }
        // Reset the input counter.
        ig->count = 0;
        // If the desired sample does not lie on a byte boundary, seek to the
        // previous sample and then read ahead.
        if ((nn & 1) && (t & 1)) {
            if (in_msrec) t += segarray[segp].samp0;   // absolute time
            if ((i = isgsetframe(g, t - 1)) != 0) return i;
            for (j = 0; j < nn; j++) (void)r212(ig);
            istime++;
            for (n = 0; s + n < nisig && isd[s + n]->info.group == g; n++)
                isd[s + n]->info.nsamp = 0L;
            return 0;
        }
        b = 3 * nn;
        d = 2;
        break;
    case 310:
        if (nn > UINT_MAX / 4) {
            wfdb_error("isigsettime: overflow in signal group %d\n", g);
            return -1;
        }
        ig->count = 0;
        // If the desired sample does not lie on a byte boundary, seek to the
        // closest previous sample that does, then read ahead.
        if ((nn % 3) && (trem = static_cast<int>(t % 3))) {
            if (in_msrec) t += segarray[segp].samp0;
            if ((i = isgsetframe(g, t - trem)) != 0) return i;
            for (j = nn * trem; j > 0; j--) (void)r310(ig);
            istime += trem;
            for (n = 0; s + n < nisig && isd[s + n]->info.group == g; n++)
                isd[s + n]->info.nsamp = 0L;
            return 0;
        }
        b = 4 * nn;
        d = 3;
        break;
    case 311:
        if (nn > UINT_MAX / 4) {
            wfdb_error("isigsettime: overflow in signal group %d\n", g);
            return -1;
        }
        ig->count = 0;
        if ((nn % 3) && (trem = static_cast<int>(t % 3))) {
            if (in_msrec) t += segarray[segp].samp0;
            if ((i = isgsetframe(g, t - trem)) != 0) return i;
            for (j = nn * trem; j > 0; j--) (void)r311(ig);
            istime += trem;
            for (n = 0; s + n < nisig && isd[s + n]->info.group == g; n++)
                isd[s + n]->info.nsamp = 0L;
            return 0;
        }
        b = 4 * nn;
        d = 3;
        break;
    case 24:
        if (nn > UINT_MAX / 3) {
            wfdb_error("isigsettime: overflow in signal group %d\n", g);
            return -1;
        }
        b = 3 * nn;
        break;
    case 32:
        if (nn > UINT_MAX / 4) {
            wfdb_error("isigsettime: overflow in signal group %d\n", g);
            return -1;
        }
        b = 4 * nn;
        break;
    }

    if (b == 0 || t > (LONG_MAX / static_cast<long>(b)) ||
        (static_cast<long>(t * b)) / static_cast<long>(d) >
        (LONG_MAX - ig->start)) {
        wfdb_error("isigsettime: improper seek on signal group %d\n", g);
        return -1;
    }

    // Seek to the beginning of the block which contains the desired sample.
    // For normal files, use fseek() to do so.
    if (ig->seek) {
        tt = static_cast<long>(t * b);
        nb = tt / static_cast<long>(d) + ig->start;
        if ((i = ig->bsize) == 0) i = ibsize;
        // Seek to a position such that the next block read will contain the
        // desired sample.
        tt = nb / i;
        if (!ig->fp || ig->fp->seek(tt * i, 0)) {
            wfdb_error("isigsettime: improper seek on signal group %d\n", g);
            return -1;
        }
        nb %= i;
    }
    // For special files, rewind if necessary and then read ahead.
    else {
        WFDB_Time t0, t1;

        // Get the time of the earliest buffered sample ...
        t0 = istime - (ig->bp - ig->buf.data()) / static_cast<long>(b);
        // ... and that of the earliest unread sample.
        t1 = t0 + (ig->be - ig->buf.data()) / static_cast<long>(b);
        // Either the desired sample has been read and has passed out of the
        // buffer, requiring a rewind ...
        if (t < t0) {
            if (ig->fp->seek(0L, 0)) {
                wfdb_error("isigsettime: improper seek on signal group %d\n",
                           g);
                return -1;
            }
            tt = static_cast<long>(t * b);
            nb = tt / static_cast<long>(d) + ig->start;
        }
        // ... or it is in the buffer already ...
        else if (t < t1) {
            tt = static_cast<long>((t - t0) * b);
            ig->bp = ig->buf.data() + tt / static_cast<long>(d);
            return 0;
        }
        // ... or it has not yet been read.
        else {
            tt = static_cast<long>((t - t1) * b);
            nb = tt / static_cast<long>(d);
        }
        while (nb > ig->bsize && !ig->fp->eof())
            nb -= static_cast<long>(ig->fp->read(ig->buf.data(), 1, ig->bsize));
    }

    // Reset the block pointer to indicate nothing has been read in the
    // current block.
    ig->bp = ig->be;
    ig->stat = 1;
    // Read any bytes in the current block that precede the desired sample.
    while (nb-- > 0 && ig->stat > 0) i = r8(ig);
    if (ig->stat <= 0) return -1;

    // Reset the getvec sample-within-frame counter.
    gvc = ispfmax;

    // Reset the time (if signal 0 belongs to the group) and disable checksum
    // testing (by setting the number of samples remaining to 0).
    if (s == 0) istime = in_msrec ? t + segarray[segp].samp0 : t;
    while (n-- != 0) isd[s + n]->info.nsamp = 0L;
    return 0;
}

int getskewedframe(WFDB_Sample *vector)
{
    int stat;
    WFDB_Sample *vecstart = vector;

    if ((stat = static_cast<int>(nisig)) == 0) return nvsig > 0 ? -1 : 0;
    if (istime == 0L) {
        for (unsigned s = 0; s < nisig; s++)
            isd[s]->samp = isd[s]->info.initval;
    }
    for (unsigned g = nigroup; g;) {
        // Go through groups in reverse order since seeking on group 0
        // should always be done last.
        if (igd[--g]->initial_skip)
            isgsetframe(g, in_msrec ? segarray[segp].samp0 : 0);
    }

    // If the vector needs to be rearranged (variable-layout record), then
    // read samples into a temporary buffer.
    if (need_sigmap) vector = ovec.data();

    const bool pad = (gvmode & WFDB_GVPAD) != 0;
    for (unsigned s = 0; s < nisig; s++) {
        ISData *is = isd[s].get();
        IGData *ig = igd[is->info.group].get();
        const int fmt = is->info.fmt;
        const int spf = is->info.spf;
        int cksum = is->info.cksum;
        for (int c = 0; c < spf; c++, vector++) {
            WFDB_Sample v;
            int inval;
            switch (fmt) {
            case 0:     // null signal: return sample tagged as invalid
                *vector = v = pad ? is->samp : WFDB_INVALID_SAMPLE;
                if (is->info.nsamp == 0) ig->stat = -1;
                goto check;
            case 8:     // 8-bit first differences
            default:
                *vector = v = is->samp = iadd(is->samp, r8(ig));
                goto check;
            case 16: v = r16(ig); inval = SAMP16_MIN; break;
            case 61: v = r61(ig); inval = SAMP16_MIN; break;
            case 80: v = r80(ig); inval = SAMP8_MIN; break;
            case 160: v = r160(ig); inval = SAMP16_MIN; break;
            case 212: v = r212(ig); inval = SAMP12_MIN; break;
            case 310: v = r310(ig); inval = SAMP10_MIN; break;
            case 311: v = r311(ig); inval = SAMP10_MIN; break;
            case 24: v = r24(ig); inval = SAMP24_MIN; break;
            case 32: v = r32(ig); inval = INT_MIN; break;
            case 508: v = flac_getsamp(ig); inval = SAMP8_MIN; break;
            case 516: v = flac_getsamp(ig); inval = SAMP16_MIN; break;
            case 524: v = flac_getsamp(ig); inval = SAMP24_MIN; break;
            }
            if (v == inval)
                *vector = pad ? is->samp : WFDB_INVALID_SAMPLE;
            else
                *vector = is->samp = v;
        check:
            if (ig->stat <= 0) {
                // End of file -- reset input counter.
                ig->count = 0;
                if (ig->stat == -2) {
                    // error in decoding compressed data
                    stat = -3;
                } else if (is->info.nsamp > 0L) {
                    wfdb_error("getvec: unexpected EOF in signal %d\n", s);
                    stat = -3;
                } else if (in_msrec && have_segarray && segp >= 0 &&
                           segp < segend) {
                    is->info.cksum = cksum;
                    segp++;
                    std::string name = segarray[segp].recname;
                    if (isigopen(name.c_str(), nullptr, nvsig) <= 0) {
                        wfdb_error("getvec: error opening segment %s\n",
                                   name.c_str());
                        stat = -3;
                        return stat;    // avoid looping if segment is bad
                    } else {
                        istime = segarray[segp].samp0;
                        return getskewedframe(vecstart);
                    }
                } else
                    stat = -1;
            }
            cksum = isub(cksum, v);
        }
        is->info.cksum = cksum;
        // At the end of the signal, check its (16-bit) checksum.
        if (is->info.nsamp >= 0 && --is->info.nsamp == 0 &&
            (is->info.cksum & 0xffff) && !in_msrec && !isedf &&
            is->info.fmt != 0) {
            // wfdb-x: recorded but not printed during a high-level read
            // (which reports the checksum error itself)
            bool print = checksum_quiet ? wfdb_set_error_print(false) : true;
            wfdb_error("getvec: checksum error in signal %d\n", s);
            if (checksum_quiet) wfdb_set_error_print(print);
            stat = -4;
        }
    }

    if (need_sigmap)
        sigmap(vecstart, ovec.data());
    else if (static_cast<int>(framelen) != tspf)
        for (int s = static_cast<int>(framelen); s < tspf; s++)
            vecstart[s] = WFDB_INVALID_SAMPLE;

    return stat;
}

// meansamp: calculate the mean of n sample values, rounded to the nearest
// integer (halfway cases rounded up).
WFDB_Sample meansamp(const WFDB_Sample *s, int n)
{
    long long sum = n / 2;
    for (int i = 0; i < n; i++) {
        if (*s == WFDB_INVALID_SAMPLE) return WFDB_INVALID_SAMPLE;
        sum += *s++;
    }
    if (n & (n - 1)) {      // if n is not a power of two
        return static_cast<WFDB_Sample>((sum + (sum < 0)) / n - (sum < 0));
    } else {
        while ((n /= 2) != 0) sum = (sum - (sum < 0)) / 2;
        return static_cast<WFDB_Sample>(sum);
    }
}

int rgetvec(WFDB_Sample *vector)
{
    WFDB_Sample *tp;

    if (ispfmax < 2)    // all signals at the same frequency
        return getframe(vector);

    if ((gvmode & WFDB_HIGHRES) != WFDB_HIGHRES) {
        // return one sample per frame, decimating by averaging if necessary
        rgetvec_stat = getframe(tvector.data());
        tp = tvector.data();
        for (int s = 0; s < nvsig; s++) {
            int sf = vsd[s]->info.spf;
            *vector++ = meansamp(tp, sf);
            tp += sf;
        }
    } else {
        // return ispfmax samples per frame, using zero-order interpolation
        // if necessary
        if (gvc >= static_cast<int>(ispfmax)) {
            rgetvec_stat = getframe(tvector.data());
            gvc = 0;
        }
        tp = tvector.data();
        for (int s = 0; s < nvsig; s++) {
            ISData *v = vsd[s].get();
            int sf = v->info.spf;
            if (gvc == 0) {
                v->gvindex = 0;
                v->gvcount = -static_cast<int>(ispfmax);
            } else {
                v->gvcount += sf;
                if (v->gvcount >= 0) {
                    v->gvindex++;
                    v->gvcount -= ispfmax;
                }
            }
            *vector++ = tp[v->gvindex];
            tp += sf;
        }
        gvc++;
    }
    return rgetvec_stat;
}

// ---------------------------------------------------------------------------
// Opening output signals

// wfdb-x: an output signal file is never one of the input files.  In normal
// mode, openosig refuses to create (and so to truncate) an output signal file
// that is the same file as a signal file of the open input record: a signal
// file open for input, or a signal file of any segment of the open
// multi-segment record (read from the segment's header; segments are opened
// later, as they are reached).  "The same file" is decided by the files
// themselves, not by their names: device and inode numbers on POSIX, volume
// serial number and file index on MS-Windows.  Decided by Reza Sameni, Oct
// 2026: e.g., "xform -i vlay -o fmt16", fmt16 being a segment of vlay,
// truncated fmt16.dat while reading it, with a platform-dependent result and
// the input destroyed.  Legacy mode: no check (the original behavior).
struct FileId {
#if defined(_WIN32)
    DWORD vol = 0, hi = 0, lo = 0;
    bool operator==(const FileId &o) const
        { return vol == o.vol && hi == o.hi && lo == o.lo; }
#else
    dev_t dev = 0;
    ino_t ino = 0;
    bool operator==(const FileId &o) const
        { return dev == o.dev && ino == o.ino; }
#endif
};

// The identity of the open local file fp, if it can be found.
std::optional<FileId> file_id(std::FILE *fp)
{
    FileId id;
#if defined(_WIN32)
    BY_HANDLE_FILE_INFORMATION info;
    HANDLE h = reinterpret_cast<HANDLE>(_get_osfhandle(_fileno(fp)));
    if (h == INVALID_HANDLE_VALUE || !GetFileInformationByHandle(h, &info))
        return std::nullopt;
    id.vol = info.dwVolumeSerialNumber;
    id.hi = info.nFileIndexHigh;
    id.lo = info.nFileIndexLow;
#else
    struct stat st;
    if (fstat(fileno(fp), &st) != 0) return std::nullopt;
    id.dev = st.st_dev;
    id.ino = st.st_ino;
#endif
    return id;
}

// True if f is a local file (not the standard input, not a URL) whose
// identity is id.
bool is_file(const WFDBFile *f, const FileId &id)
{
    if (!f || f->type() != WFDB_LOCAL || f->is_std() || !f->fp()) return false;
    std::optional<FileId> fid = file_id(f->fp());
    return fid && *fid == id;
}

bool is_url_name(const std::string &s)
{
    return s.compare(0, 7, "http://") == 0 || s.compare(0, 8, "https://") == 0;
}

// True if one of the signal files named in the header of segment seg (of the
// open multi-segment record) is the file id.  The header and the signal files
// are located as isigopen locates them in normal mode; a header or signal
// file that cannot be found (or is at a URL) is not the file id.  No message
// is printed.
bool segment_has_file(const std::string &seg, const FileId &id)
{
    if (seg == "~" || !wfdbx_in_header_dir(seg) ||
        (msrec_dir && is_url_name(*msrec_dir)))
        return false;
    FilePtr hf = msrec_name
        ? wfdbx_open_in(msrec_dir, "hea", seg.c_str(), msrec_name->c_str())
        : wfdb_open("hea", seg.c_str(), WFDB_READ);
    if (!hf) return false;
    std::optional<std::string> dir;
    if (hf->type() == WFDB_LOCAL && !hf->is_std())
        dir = wfdbx_dirname(wfdb_filename());
    const char *sep = " \t\n\r";
    std::string line;
    int nsig = -1;
    while (nsig != 0 && hf->getline(line)) {
        char *save = nullptr;
        char *p = xstrtok(&line[0], sep, &save), *q;
        if (p == nullptr || *p == '#') continue;
        if (nsig < 0) {     // the record line
            if (std::strchr(p, '/') ||  // not a valid segment
                (q = xstrtok(nullptr, sep, &save)) == nullptr ||
                (nsig = static_cast<int>(std::strtol(q, nullptr, 10))) <= 0)
                break;
            continue;
        }
        nsig--;             // a signal line: file name, format, ...
        if ((q = xstrtok(nullptr, sep, &save)) == nullptr ||
            std::strtol(q, nullptr, 10) == 0 || std::strcmp(p, "-") == 0 ||
            !wfdbx_in_header_dir(p) || !dir || is_url_name(*dir))
            continue;
        if (FilePtr sf = wfdbx_open_in(dir, nullptr, p, seg.c_str()))
            if (is_file(sf.get(), id)) return true;
    }
    return false;
}

// True if the output signal file fname (as named in an output signal
// specification, created by wfdb_open(fname, nullptr, WFDB_WRITE)) exists
// and is one of the signal files of the open input record (see above).
bool is_input_file(const char *fname)
{
    std::optional<std::string> path = wfdbx_output_file(fname);
    if (!path) return false;
    std::optional<FileId> id;
#if defined(_WIN32)
    if (std::FILE *fp = std::fopen(path->c_str(), "rb")) {
        id = file_id(fp);
        std::fclose(fp);
    }
#else
    struct stat st;
    if (stat(path->c_str(), &st) == 0) {
        id = FileId();
        id->dev = st.st_dev;
        id->ino = st.st_ino;
    }
#endif
    if (!id) return false;  // it does not exist: it is not an input file
    for (WFDB_Group g = 0; g < nigroup; g++)
        if (g < igd.size() && igd[g] && is_file(igd[g]->fp.get(), *id))
            return true;
    if (in_msrec && have_segarray)
        for (int i = 0; i <= segend && i < static_cast<int>(segarray.size()); i++)
            if (segment_has_file(segarray[i].recname, *id)) return true;
    return false;
}

int openosig(const char *func, WFDB_Siginfo *si_out, const WFDB_Siginfo *si_in,
             unsigned int nsig)
{
    OSData *os, *op;
    OGData *og;
    WFDB_Signal s;
    unsigned int ga;

    if (nsig == 0) return 0;

    // Allocate workspace for output signals and signal groups.
    allocosig(nosig + nsig);
    allocogroup(nogroup + si_in[nsig - 1].group + 1);

    // Initialize local variables.
    if (obsize <= 0) obsize = WFDB_BUFSIZ;

    // Set the group number adjustment.
    ga = nogroup;

    // Open the signal files.  One signal is handled per iteration.
    for (s = 0, os = osd[nosig].get(); s < nsig; s++, nosig++, si_in++) {
        op = os;
        os = osd[nosig].get();

        // Copy signal information from the caller's array.
        os->info = *si_in;
        if (os->info.spf < 1) os->info.spf = 1;
        os->info.cksum = 0;
        os->info.nsamp = 0L;
        os->info.group += ga;
        if (si_out) {
            *si_out = os->info;
            si_out++;
        }

        // Check if this signal is in the same group as the previous one.
        if (s == 0 || os->info.group != op->info.group) {
            size_t obuflen;

            allocogroup(os->info.group + 1);
            og = ogd[os->info.group].get();
            og->bsize = os->info.bsize;
            if (isflacfmt(os->info.fmt)) {
                unsigned ns = 1;
                while (s + ns < nsig && si_in[ns].group == si_in[0].group)
                    ns++;
                if (flac_osinit(og, si_in, ns) < 0) {
                    osigclose();
                    return -3;
                }
            }

            obuflen = og->bsize ? og->bsize : obsize;
            // This is the first signal in a new group; allocate buffer.
            og->buf.assign(obuflen, 0);
            og->bp = og->buf.data();
            og->be = og->buf.data() + obuflen;
            if (os->info.fmt == 0) {
                // If the signal file name was NULL or "~", don't create a
                // signal file.
                if (!os->info.fname || *os->info.fname == "~")
                    og->fp.reset();
                // Otherwise, assume that the user wants to write a signal
                // file in the default format (16).
                else
                    os->info.fmt = 16;
            }
            if (os->info.fmt != 0) {
                // wfdb-x: never an input file (see is_input_file)
                if (!legacy_mode && is_input_file(cstr(os->info.fname))) {
                    wfdb_error("%s: output file %s is also an input file\n",
                               func, cstr_or_null(os->info.fname));
                    og->buf.clear();
                    osigclose();
                    return -3;
                }
                // An error in opening an output file is fatal.
                og->fp = wfdb_open(cstr(os->info.fname), nullptr, WFDB_WRITE);
                if (!og->fp) {
                    wfdb_error("%s: can't open %s\n", func,
                               cstr_or_null(os->info.fname));
                    og->buf.clear();
                    osigclose();
                    return -3;
                }
            }
            if (isflacfmt(os->info.fmt) && og->flac && flac_osopen(og) < 0) {
                osigclose();
                return -3;
            }
            nogroup++;
        } else {
            // This signal belongs to the same group as the previous signal.
            if (os->info.fmt != op->info.fmt ||
                os->info.bsize != op->info.bsize) {
                wfdb_error("%s: error in specification of signal %d or %d\n",
                           func, s - 1, s);
                return -2;
            }
        }
    }
    return static_cast<int>(s);
}

} // namespace

// ---------------------------------------------------------------------------
// Private functions (for use by other WFDB library functions only)

bool wfdbx_set_checksum_quiet(bool on)
{
    bool previous = checksum_quiet;
    checksum_quiet = on;
    return previous;
}

void wfdb_sampquit()
{
    if (have_sbuf) {
        sbuf.clear();
        sbuf.shrink_to_fit();
        have_sbuf = false;
        sample_vflag = 0;
    }
}

void wfdb_sigclose()
{
    isigclose();
    osigclose();
    btime = 0;
    bdate = 0;
    nsamples = 0;
    msbtime = 0;
    msbdate = 0;
    msnsamples = 0;
    sfreq = ifreq = ffreq = 0;
    pdays = -1;
    segments = in_msrec = 0;
    skewmax = 0;
    msrec_dir.reset();  // wfdb-x
    msrec_name.reset();
    hdr_dir.reset();
    if (have_dsbuf) {
        dsbuf.clear();
        dsbuf.shrink_to_fit();
        have_dsbuf = false;
        dsbi = -1;
    }
    if (have_segarray) {
        segarray.clear();
        have_segarray = false;
        segp = segend = -1;
    }
    gv0.clear();
    gv1.clear();
    tvector.clear();
    uvector.clear();
    vvector.clear();
    tuvlen = 0;

    sigmap_cleanup();
}

void wfdb_osflush()
{
    if (osd.empty() || ogd.empty()) return;

    for (unsigned s = 0; s < nosig && s < osd.size(); s++) {
        OSData *os = osd[s].get();
        if (os->info.group >= ogd.size()) continue;
        OGData *og = ogd[os->info.group].get();
        if (og->nrewind == 0) {
            if (!og->force_flush && og->seek == 0) {
                if (og->bsize == 0 && og->fp && !og->fp->seek(0L, SEEK_CUR))
                    og->seek = 1;
                else
                    og->seek = -1;
            }
            if (og->force_flush || og->seek > 0) {
                // Either we are closing the file (osigclose() was called),
                // or the file is seekable: write out any partially-completed
                // sets of bit-packed samples.
                switch (os->info.fmt) {
                case 212: f212(og); break;
                case 310: f310(og); break;
                case 311: f311(og); break;
                default: break;
                }
            }
        }
    }

    for (unsigned g = 0; g < nogroup && g < ogd.size(); g++) {
        OGData *og = ogd[g].get();
        if (og->bsize == 0 && og->bp != og->buf.data()) {
            if (og->fp) og->fp->write(og->buf.data(), 1, og->bp - og->buf.data());
            og->bp = og->buf.data();
        }
        if (og->fp) {
            og->fp->flush();
            if (!og->force_flush && og->nrewind != 0) {
                // Rewind the file so that subsequent samples will be written
                // in the right place.
                og->fp->seek(-static_cast<long>(og->nrewind), SEEK_CUR);
                og->nrewind = 0;
            }
        }
    }
}

int wfdb_oinfoclose()
{
    int stat = 0;

    if (outinfo && outinfo != oheader.get()) {
        int errflag = outinfo->error();
        if (outinfo->close()) errflag = 1;
        if (errflag) {
            wfdb_error("setinfo: write error in info file\n");
            stat = -2;
        }
    }
    outinfo_file.reset();
    outinfo = nullptr;
    return stat;
}

} // namespace detail

using namespace detail;

// ---------------------------------------------------------------------------
// WFDB library functions

int isigopen(const char *record_arg, WFDB_Siginfo *siarray, int nsig)
{
    int navail, nn, spflimit;
    int first_segment = 0;
    WFDB_Signal s, si, sj;
    WFDB_Group g;

    if (record_arg == nullptr) record_arg = "";
    // Close previously opened input signals unless otherwise requested.
    if (*record_arg == '+')
        record_arg++;
    else
        isigclose();

    // Remove trailing .hea, if any, from record name.
    std::string recbuf = wfdb_striphea(record_arg);
    const char *record = recbuf.c_str();

    // Save the current record name.
    if (!in_msrec) wfdb_setirec(record);

    // Read the header and determine how many signals are available.
    if ((navail = readheader(record)) <= 0) {
        if (navail == 0 && segments) {  // this is a multi-segment record
            in_msrec = 1;
            first_segment = 1;
            // Open the first segment to get signal information.
            if (have_segarray && segp >= 0) {
                std::string name = segarray[segp].recname;
                if ((navail = readheader(name.c_str())) >= 0) {
                    if (msbtime == 0L) msbtime = btime;
                    if (msbdate == 0) msbdate = bdate;
                }
            }
            if (nsig <= 0) in_msrec = 0;
        }
        if (navail == 0 && nsig)
            wfdb_error("isigopen: record %s has no signals\n", record);
        if (navail <= 0) return navail;
    }

    // If nsig <= 0, isigopen fills in up to (-nsig) members of siarray based
    // on the contents of the header, but no signals are actually opened.
    if (nsig <= 0) {
        nsig = -nsig;
        if (navail < nsig) nsig = navail;
        if (siarray != nullptr)
            for (s = 0; s < static_cast<unsigned>(nsig); s++)
                siarray[s] = hsd[s].info;
        in_msrec = 0;   // necessary to avoid errors when reopening
        return navail;
    }

    // Determine how many new signals we should attempt to open.
    if (nsig > navail) nsig = navail;

    // Allocate input signals and signal group workspace.
    nn = static_cast<int>(nisig) + nsig;
    if (static_cast<int>(allocisig(nn)) != nn) return -1;
    nn = static_cast<int>(nigroup + hsd[navail - 1].info.group + 1);
    if (nn > static_cast<int>(nigroup) + nsig) nn = static_cast<int>(nigroup) + nsig;
    if (static_cast<int>(allocigroup(nn)) != nn) return -1;

    // Set default buffer size (if not set already by setibsize).
    if (ibsize <= 0) ibsize = WFDB_BUFSIZ;

    // Open the signal files.  One signal group is handled per iteration.  In
    // this loop, si counts through the entries that have been read from hsd,
    // and s counts the entries that have been added to isd.
    for (g = si = s = 0; si < static_cast<unsigned>(navail) &&
                         s < static_cast<unsigned>(nsig); si = sj) {
        HSData *hs = &hsd[si];
        ISData *is = isd[nisig + s].get();
        IGData *ig = igd[nigroup + g].get();

        // Find out how many signals are in this group.
        for (sj = si + 1; sj < static_cast<unsigned>(navail); sj++)
            if (hsd[sj].info.group != hs->info.group) break;

        // Skip this group if there are too few slots in the caller's array.
        if (sj - si > static_cast<unsigned>(nsig) - s) continue;

        // Set the buffer size and the seek capability flag.
        if (hs->info.bsize < 0) {
            ig->bsize = hs->info.bsize = -hs->info.bsize;
            ig->seek = 0;
        } else {
            if ((ig->bsize = hs->info.bsize) == 0) ig->bsize = ibsize;
            ig->seek = 1;
        }
        ig->buf.assign(ig->bsize, 0);
        ig->flac.reset();

        // Check that the signal file is readable.
        if (hs->info.fmt == 0)
            ig->fp.reset();     // Don't open a file for a null signal.
        else {
            // wfdb-x: in the directory of the header
            ig->fp = legacy_mode
                ? wfdb_open(cstr(hs->info.fname), nullptr, WFDB_READ)
                : wfdbx_open_in(hdr_dir, nullptr, cstr(hs->info.fname), record);
            // Skip this group if the signal file can't be opened.
            if (!ig->fp) {
                ig->buf.clear();
                continue;
            }
        }

        if (isflacfmt(hs->info.fmt)) {
            if (flac_isopen(ig, &hsd[si], sj - si) < 0) {
                ig->buf.clear();
                ig->fp.reset();
                ig->flac.reset();
                continue;
            }
        }

        // All tests passed -- fill in remaining data for this group.
        ig->be = ig->bp = ig->buf.data() + ig->bsize;
        ig->start = hs->start;
        ig->initial_skip = (ig->start > 0);
        ig->stat = 1;
        while (si < sj && s < static_cast<unsigned>(nsig)) {
            is->info = hs->info;
            is->info.group = nigroup + g;
            is->skew = hs->skew;
            ++s;
            if (++si < sj) {
                hs = &hsd[si];
                is = isd[nisig + s].get();
            }
        }
        g++;
    }

    // Produce a warning message if none of the requested signals could be
    // opened.
    if (s == 0 && nsig)
        wfdb_error("isigopen: none of the signals for record %s is readable\n",
                   record);

    // Check that the total number of samples per frame is less than or
    // equal to INT_MAX.
    spflimit = INT_MAX - static_cast<int>(framelen);
    for (si = 0; si < s; si++) {
        spflimit -= isd[nisig + si]->info.spf;
        if (spflimit < 0) {
            wfdb_error("isigopen: total frame size too large in record %s\n",
                       record);
            isigclose();
            return -3;
        }
    }

    // Copy the WFDB_Siginfo structures to the caller's array.  Use these data
    // to construct the initial sample vector, and to determine the maximum
    // number of samples per signal per frame and the maximum skew.
    for (si = 0; si < s; si++) {
        ISData *is = isd[nisig + si].get();
        if (siarray) siarray[si] = is->info;
        is->samp = is->info.initval;
        if (ispfmax < static_cast<unsigned>(is->info.spf)) ispfmax = is->info.spf;
        if (skewmax < static_cast<unsigned>(is->skew)) skewmax = is->skew;
    }
    nisig += s;         // Update the count of open input signals.
    nigroup += g;       // Update the count of open input signal groups.
    if (sigmap_init(first_segment) < 0) {
        isigclose();
        return -3;
    }
    spfmax = static_cast<int>(ispfmax);
    setgvmode(gvmode);  // Reset sfreq if appropriate.
    gvc = static_cast<int>(ispfmax);    // Initialize getvec's counter.

    // Determine the total number of samples per frame.
    for (si = framelen = 0; si < nisig; si++) framelen += isd[si]->info.spf;

    // Allocate workspace for getvec, isgsettime, and tnextvec.
    if (tspf > tuvlen) {
        tvector.assign(tspf, 0);
        uvector.assign(tspf, 0);
        vvector.assign(tspf, 0);
        tuvlen = tspf;
    }

    // If deskewing is required, allocate the deskewing buffer (unless this
    // is a multi-segment record and dsbuf has been allocated already).
    if (skewmax != 0 && (!in_msrec || !have_dsbuf)) {
        if (tspf > static_cast<int>(INT_MAX / (skewmax + 1))) {
            wfdb_error("isigopen: maximum skew too large in record %s\n",
                       record);
            isigclose();
            return -3;
        }
        dsbi = -1;      // mark buffer contents as invalid
        dsblen = tspf * (skewmax + 1);
        dsbuf.assign(dsblen, 0);
        have_dsbuf = true;
    }
    return static_cast<int>(s);
}

int osigopen(const char *record_arg, WFDB_Siginfo *siarray, unsigned int nsig)
{
    int n;

    if (record_arg == nullptr) record_arg = "";
    // Close previously opened output signals unless otherwise requested.
    if (*record_arg == '+')
        record_arg++;
    else
        osigclose();

    // Remove trailing .hea, if any, from record name.
    std::string recbuf = wfdb_striphea(record_arg);
    const char *record = recbuf.c_str();

    if ((n = readheader(record)) < 0) return n;
    if (n < static_cast<int>(nsig)) {
        wfdb_error("osigopen: record %s has fewer signals than needed\n",
                   record);
        return -3;
    }

    std::vector<WFDB_Siginfo> hsi(nsig);
    for (unsigned s = 0; s < nsig; s++) hsi[s] = hsd[s].info;
    return openosig("osigopen", siarray, hsi.data(), nsig);
}

int osigfopen(const WFDB_Siginfo *siarray, unsigned int nsig)
{
    int stat;
    const WFDB_Siginfo *si;
    unsigned s;

    // Close any open output signals.
    stat = osigclose();

    // Do nothing further if there are no signals to open.
    if (siarray == nullptr || nsig == 0) return stat;

    if (obsize <= 0) obsize = WFDB_BUFSIZ;

    // Prescan siarray to check the signal specifications and to determine
    // the number of signal groups.
    for (s = 0, si = siarray; s < nsig; s++, si++) {
        // (As in C, the file name and description may total 200 bytes.)
        size_t lf = si->fname ? std::strlen(si->fname->c_str()) : 0;
        size_t ld = si->desc ? std::strlen(si->desc->c_str()) : 0;
        if (lf + ld > 200 || si->bsize < 0 || !isfmt(si->fmt)) {
            wfdb_error("osigfopen: error in specification of signal %d\n", s);
            return -2;
        }
        const char *f1 = si->fname ? si->fname->c_str() : "";
        const char *f0 = (s && (si - 1)->fname) ? (si - 1)->fname->c_str() : "";
        if (!((s == 0 && si->group == 0) ||
              (s && si->group == (si - 1)->group && std::strcmp(f1, f0) == 0) ||
              (s && si->group == (si - 1)->group + 1 &&
               std::strcmp(f1, f0) != 0))) {
            wfdb_error("osigfopen: incorrect file name or group for signal "
                       "%d\n", s);
            return -2;
        }
    }

    return openosig("osigfopen", nullptr, siarray, nsig);
}

// Function findsig finds an open input signal with the name specified by its
// (string) argument, and returns the associated signal number.
int findsig(const char *p)
{
    const char *q = p;
    int s;

    while ('0' <= *q && *q <= '9') q++;
    if (*q == 0) {  // all digits, probably a signal number
        s = static_cast<int>(std::strtol(p, nullptr, 10));
        if (static_cast<unsigned>(s) < nisig || s < nvsig) return s;
    }
    // Otherwise, p is either an integer too large to be a signal number or a
    // string containing a non-digit character.  Assume it's a signal name.
    if (need_sigmap) {
        for (s = 0; s < nvsig; s++)
            if (vsd[s]->info.desc && *vsd[s]->info.desc == p) return s;
    } else {
        for (s = 0; s < static_cast<int>(nisig); s++)
            if (isd[s]->info.desc && std::strcmp(p, isd[s]->info.desc->c_str()) == 0)
                return s;
    }
    // No match found.
    return -1;
}

int getspf()
{
    return (sfreq != ffreq) ? static_cast<int>(sfreq / ffreq + 0.5) : 1;
}

void setgvmode(int mode)
{
    if (mode < 0) {     // (re)set to default mode
        const char *p = std::getenv("WFDBGVMODE");
        if (p)
            mode = static_cast<int>(std::strtol(p, nullptr, 10));
        else
            mode = DEFWFDBGVMODE;
    }

    gvmode = mode & (WFDB_HIGHRES | WFDB_GVPAD);

    if ((mode & WFDB_HIGHRES) == WFDB_HIGHRES) {
        if (spfmax == 0) spfmax = 1;
        sfreq = ffreq * spfmax;
    } else {
        sfreq = ffreq;
    }
}

int getgvmode()
{
    return gvmode;
}

// An application can specify the input sampling frequency it prefers by
// calling setifreq after opening the input record.
int setifreq(WFDB_Frequency f)
{
    WFDB_Frequency error, g = sfreq;

    if (g <= 0.0) {
        ifreq = 0.0;
        if (nisig > 0 && !legacy_mode)  // wfdb-x: the frequency is unspecified
            wfdb_error("setifreq: sampling frequency is not specified\n");
        else
            wfdb_error("setifreq: no open input record\n");
        return -1;
    }
    if (f > 0.0) {
        size_t n = static_cast<size_t>(nvsig > static_cast<int>(nisig) ?
                                       nvsig : static_cast<int>(nisig));
        if (n < static_cast<size_t>(tspf)) n = tspf;
        if (n < 1) n = 1;
        if (gv0.size() < n) gv0.resize(n, 0);
        if (gv1.size() < n) gv1.resize(n, 0);
        setafreq(ifreq = f);
        // Euclid's algorithm for the GCD of sfreq and ifreq (in multiples of
        // 0.005 Hz, the maximum tolerable error in the resampling frequency).
        while ((error = f - g) > 0.005 || error < -0.005) {
            if (f > g)
                f -= g;
            else
                g -= f;
        }
        // f is now the GCD of sfreq and ifreq.  Each raw sampling interval
        // is divided into mticks subintervals.
        mticks = static_cast<long>(sfreq / f + 0.5);
        // Each resampled interval is divided into nticks subintervals.
        nticks = static_cast<long>(ifreq / f + 0.5);
        // Raw and resampled intervals begin simultaneously once every
        // mnticks subintervals (an epoch).
        mnticks = mticks * nticks;
        // gvtime is the number of subintervals from the beginning of the
        // current epoch to the next sample to be returned by getvec().
        gvtime = 0;
        rgvstat = rgetvec(gv0.data());
        rgvstat = rgetvec(gv1.data());
        // rgvtime is the number of subintervals from the beginning of the
        // current epoch to the most recent sample returned by rgetvec().
        rgvtime = nticks;
        return 0;
    } else {
        ifreq = 0.0;
        wfdb_error("setifreq: improper frequency %g (must be > 0)\n", f);
        return -1;
    }
}

WFDB_Frequency getifreq()
{
    return ifreq > 0 ? ifreq : sfreq;
}

int getvec(WFDB_Sample *vector)
{
    int i, nsig;

    if (ifreq == 0.0 || ifreq == sfreq)     // no resampling necessary
        return rgetvec(vector);

    // Resample the input.
    if (rgvtime > mnticks) {
        rgvtime -= mnticks;
        gvtime -= mnticks;
    }
    nsig = (nvsig > static_cast<int>(nisig)) ? nvsig : static_cast<int>(nisig);
    while (gvtime > rgvtime) {
        for (i = 0; i < nsig; i++) gv0[i] = gv1[i];
        rgvstat = rgetvec(gv1.data());
        rgvtime += nticks;
    }
    for (i = 0; i < nsig; i++) {
        vector[i] = static_cast<WFDB_Sample>(
            gv0[i] + (gvtime % nticks) *
                         static_cast<long long>(isub(gv1[i], gv0[i])) / nticks);
        gv0[i] = gv1[i];
    }
    gvtime += mticks;
    return rgvstat;
}

int getframe(WFDB_Sample *vector)
{
    int stat = -1;

    if (have_dsbuf) {   // signals must be deskewed
        int c, i, j, s;

        // First, obtain the samples needed.
        if (dsbi < 0) {     // dsbuf contents are invalid -- refill dsbuf
            for (dsbi = i = 0; i < static_cast<int>(dsblen); dsbi = i += tspf) {
                stat = getskewedframe(dsbuf.data() + dsbi);
                if (stat < 0) break;
            }
            dsbi = 0;
        } else {            // replace oldest frame in dsbuf only
            stat = getskewedframe(dsbuf.data() + dsbi);
            if ((dsbi += tspf) >= static_cast<int>(dsblen)) dsbi = 0;
        }

        // Assemble the deskewed frame from the data in dsbuf.
        for (j = s = 0; s < nvsig; s++) {
            if ((i = j + dsbi + vsd[s]->skew * tspf) >= static_cast<int>(dsblen))
                i %= dsblen;
            for (c = 0; c < vsd[s]->info.spf; c++) vector[j++] = dsbuf[i++];
        }
    } else      // no deskewing necessary
        stat = getskewedframe(vector);
    istime++;
    return stat;
}

long long getvecs(WFDB_Sample *out, long long n, int *status)
{
    long long k;
    int stat = 0;

    if (status) *status = 0;
    if (n <= 0) return 0;
    // Fast path: getvec is getframe, which is getskewedframe.
    if (!have_dsbuf && ispfmax < 2 && (ifreq == 0.0 || ifreq == sfreq)) {
        size_t stride = static_cast<size_t>(tspf);
        for (k = 0; k < n; k++) {
            stat = getskewedframe(out);
            istime++;
            if (stat < 0) break;
            out += stride;
        }
    } else {
        // getvec returns one sample per signal
        size_t stride = static_cast<size_t>(nvsig);
        if (ifreq != 0.0 && ifreq != sfreq && static_cast<int>(nisig) > nvsig)
            stride = nisig;
        for (k = 0; k < n; k++) {
            stat = getvec(out);
            if (stat < 0) break;
            out += stride;
        }
    }
    if (status) *status = stat;
    return (k == 0 && stat < 0) ? stat : k;
}

int putvec(const WFDB_Sample *vector)
{
    int c, dif, stat = static_cast<int>(nosig);
    WFDB_Sample samp;

    for (unsigned s = 0; s < nosig; s++) {
        OSData *os = osd[s].get();
        OGData *og = ogd[os->info.group].get();
        if (os->info.nsamp++ == 0L) os->info.initval = os->samp = *vector;
        for (c = 0; c < os->info.spf; c++, vector++) {
            // Replace invalid samples with lowest possible value for format.
            if ((samp = *vector) == WFDB_INVALID_SAMPLE) {
                switch (os->info.fmt) {
                case 0:
                case 8:
                case 16:
                case 61:
                case 160:
                case 516:
                default: samp = SAMP16_MIN; break;
                case 80:
                case 508: samp = SAMP8_MIN; break;
                case 212: samp = SAMP12_MIN; break;
                case 310:
                case 311: samp = SAMP10_MIN; break;
                case 24:
                case 524: samp = SAMP24_MIN; break;
                case 32: samp = INT_MIN; break;
                }
            }
            switch (os->info.fmt) {
            case 0:     // null signal (do not write)
                os->samp = samp;
                break;
            case 8:     // 8-bit first differences
            default:
                // Handle large slew rates sensibly.
                if ((dif = isub(samp, os->samp)) < SAMP8_MIN) {
                    dif = SAMP8_MIN;
                    stat = 0;
                } else if (dif > SAMP8_MAX) {
                    dif = SAMP8_MAX;
                    stat = 0;
                }
                os->samp = iadd(os->samp, dif);
                w8(dif, og);
                break;
            case 16: w16(samp, og); os->samp = samp; break;
            case 61: w61(samp, og); os->samp = samp; break;
            case 80: w80(samp, og); os->samp = samp; break;
            case 160: w160(samp, og); os->samp = samp; break;
            case 212: w212(samp, og); os->samp = samp; break;
            case 310: w310(samp, og); os->samp = samp; break;
            case 311: w311(samp, og); os->samp = samp; break;
            case 24: w24(samp, og); os->samp = samp; break;
            case 32: w32(samp, og); os->samp = samp; break;
            case 508:   // 8-bit compressed FLAC
            case 516:   // 16-bit compressed FLAC
            case 524:   // 24-bit compressed FLAC
                if (!og->flac || flac_putsamp(samp, os->info.fmt, og) < 0)
                    stat = -1;
                os->samp = samp;
                break;
            }
            if (og->fp && og->fp->error()) {
                wfdb_error("putvec: write error in signal %d\n", s);
                stat = -1;
            } else
                os->info.cksum = iadd(os->info.cksum, os->samp);
        }
    }
    ostime++;
    return stat;
}

int isigsettime(WFDB_Time t)
{
    WFDB_Time curtime;
    int stat = 0;

    // Return immediately if no seek is needed.
    if (nisig == 0) return 0;
    if (ifreq <= 0) {
        if (!(gvmode & WFDB_HIGHRES) || ispfmax < 2)
            curtime = istime;
        else
            curtime = (istime - 1) * ispfmax + gvc;
        if (t == curtime) return 0;
    }

    for (WFDB_Group g = 1; g < nigroup; g++)
        if ((stat = isgsettime(g, t)) < 0) break;
    // Seek on signal group 0 last (since doing so updates istime and would
    // confuse isgsettime if done first).
    if (stat == 0) stat = isgsettime(0, t);
    return stat;
}

int isgsettime(WFDB_Group g, WFDB_Time t)
{
    int stat, trem = 0;
    double tt;

    // Handle negative arguments as equivalent positive arguments.
    if (t < 0L) {
        if (t < -WFDB_TIME_MAX) {
            wfdb_error("isigsettime: improper seek on signal group %d\n", g);
            return -1;
        }
        t = -t;
    }

    // Convert t to raw sample intervals if we are resampling.
    if (ifreq > 0) {
        tt = t * sfreq / ifreq;
        if (tt > static_cast<double>(WFDB_TIME_MAX)) {
            wfdb_error("isigsettime: improper seek on signal group %d\n", g);
            return -1;
        }
        t = static_cast<WFDB_Time>(tt);
    }

    // If we're in WFDB_HIGHRES mode, convert t from samples to frames, and
    // save the remainder (if any) in trem.
    if (gvmode & WFDB_HIGHRES) {
        trem = static_cast<int>(t % static_cast<long long>(ispfmax));
        t /= static_cast<long long>(ispfmax);
    }

    // Mark the contents of the deskewing buffer (if any) as invalid.
    dsbi = -1;

    if ((stat = isgsetframe(g, t)) == 0 && g == 0) {
        while (trem-- > 0) {
            if (rgetvec(uvector.data()) < 0) {
                wfdb_error("isigsettime: improper seek on signal group %d\n",
                           g);
                return -1;
            }
        }
        if (ifreq > 0 && ifreq != sfreq) {
            gvtime = 0;
            rgvstat = rgetvec(gv0.data());
            rgvstat = rgetvec(gv1.data());
            rgvtime = nticks;
        }
    }

    return stat;
}

WFDB_Time tnextvec(WFDB_Signal s, WFDB_Time t)
{
    int stat = 0;
    WFDB_Time tf;

    if (in_msrec && need_sigmap) {  // variable-layout multi-segment record
        if (s >= static_cast<unsigned>(nvsig)) {
            wfdb_error("nextvect: illegal signal number %d\n", s);
            return -1;
        }
        // Go to the start (t) if not already there.
        if (t != istime && isigsettime(t) < 0) return -1;
        while (stat >= 0) {
            std::string p = vsd[s]->info.desc.value_or("");
            unsigned ss;

            tf = segarray[segp].samp0 + segarray[segp].nsamp;
            // Check if signal s is available in the current segment.
            for (ss = 0; ss < nisig; ss++)
                if (isd[ss]->info.desc && *isd[ss]->info.desc == p) break;
            if (ss < nisig) {
                // The current segment contains the desired signal.  Read
                // samples until we find a valid one or reach the end of the
                // segment.
                for (; t <= tf && (stat = getvec(vvector.data())) > 0; t++)
                    if (vvector[s] != WFDB_INVALID_SAMPLE) {
                        isigsettime(t);
                        return t;
                    }
                if (stat < 0) return -1;
            }
            // Go on to the next segment.
            if (t != tf) stat = isigsettime(t = tf);
        }
    } else {    // single-segment or fixed-layout multi-segment record
        // Go to the start (t) if not already there.
        if (t != istime && isigsettime(t) < 0) return -1;
        if (s >= nisig) {
            wfdb_error("nextvect: illegal signal number %d\n", s);
            return -1;
        }
        for (; (stat = getvec(vvector.data())) > 0; t++)
            // Read samples until we find a valid one or reach the end of the
            // record.
            if (vvector[s] != WFDB_INVALID_SAMPLE) {
                isigsettime(t);
                return t;
            }
    }
    // Error or end of record without finding another sample of signal s.
    return stat;
}

int setibsize(int n)
{
    if (nisig) {
        wfdb_error("setibsize: can't change buffer size after isigopen\n");
        return -1;
    }
    if (n < 0) {
        wfdb_error("setibsize: illegal buffer size %d\n", n);
        return -2;
    }
    if (n == 0) n = WFDB_BUFSIZ;
    return ibsize = n;
}

int setobsize(int n)
{
    if (nosig) {
        wfdb_error("setobsize: can't change buffer size after osig[f]open\n");
        return -1;
    }
    if (n < 0) {
        wfdb_error("setobsize: illegal buffer size %d\n", n);
        return -2;
    }
    if (n == 0) n = WFDB_BUFSIZ;
    return obsize = n;
}

int newheader(const char *record)
{
    // Remove trailing .hea, if any, from record name.
    std::string rec = wfdb_striphea(record);
    std::vector<WFDB_Siginfo> osi(nosig);
    for (unsigned s = 0; s < nosig; s++) osi[s] = osd[s]->info;
    return setheader(rec.c_str(), osi.data(), nosig);
}

int setheader(const char *record_arg, WFDB_Siginfo *siarray, unsigned int nsig)
{
    // If another output header file was opened, close it.
    if (oheader) {
        oheader->close();
        if (outinfo == oheader.get()) outinfo = nullptr;
        oheader.reset();
    }

    // Remove trailing .hea, if any, from record name.
    std::string recbuf = wfdb_striphea(record_arg);
    const char *record = recbuf.c_str();

    // Quit (with message from wfdb_checkname) if name is illegal.
    if (wfdb_checkname(record, "record")) return -1;

    // Try to create the header file.
    if ((oheader = wfdb_open("hea", record, WFDB_WRITE)) == nullptr) {
        wfdb_error("newheader: can't create header for record %s\n", record);
        return -1;
    }

    // Write the general information line.
    std::string out = strprintf("%s %d %.12g", record, nsig, ffreq);
    if ((cfreq > 0.0 && cfreq != ffreq) || bcount != 0.0) {
        out += strprintf("/%.12g", cfreq);
        if (bcount != 0.0) out += strprintf("(%.12g)", bcount);
    }
    out += strprintf(" %ld", nsig > 0 ? siarray[0].nsamp : 0L);
    if (btime != 0L || bdate != 0) {
        if (btime == 0L)
            out += " 0:00";
        else if (btime % 1000 == 0)
            out += " " + ftimstr(btime, 1000.0);
        else
            out += std::string(" ") + fmstimstr(btime, 1000.0);
    }
    if (bdate) out += datstr(bdate);
    out += "\r\n";

    // Write a signal specification line for each signal.
    for (unsigned s = 0; s < nsig; s++) {
        out += strprintf("%s %d", cstr_or_null(siarray[s].fname), siarray[s].fmt);
        if (siarray[s].spf > 1) out += strprintf("x%d", siarray[s].spf);
        if (s < osd.size() && osd[s]->skew)
            out += strprintf(":%d", osd[s]->skew * siarray[s].spf);
        if (s < osd.size() && osd[s]->info.group < ogd.size() &&
            ogd[osd[s]->info.group]->start)
            out += strprintf("+%ld", ogd[osd[s]->info.group]->start);
        else if (prolog_bytes)
            out += strprintf("+%ld", prolog_bytes);
        out += strprintf(" %.12g", siarray[s].gain);
        if (siarray[s].baseline != siarray[s].adczero)
            out += strprintf("(%d)", siarray[s].baseline);
        if (siarray[s].units) {
            std::optional<std::string> p =
                strtok_inplace(*siarray[s].units, " \t\n\r");
            if (p) out += "/" + *p;
        }
        out += strprintf(" %d %d %d %d %d", siarray[s].adcres,
                         siarray[s].adczero, siarray[s].initval,
                         static_cast<int>(static_cast<short>(siarray[s].cksum & 0xffff)),
                         siarray[s].bsize);
        if (siarray[s].desc) {
            std::optional<std::string> p = strtok_inplace(*siarray[s].desc, "\n\r");
            if (p) out += " " + *p;
        }
        out += "\r\n";
    }
    oheader->write(out.data(), 1, out.size());
    prolog_bytes = 0L;
    oheader->flush();
    return 0;
}

int getseginfo(const WFDB_Seginfo **sarray)
{
    *sarray = have_segarray ? segarray.data() : nullptr;
    return segments;
}

int setmsheader(const char *record_arg, const char *const *segment_name,
                unsigned int nsegments)
{
    WFDB_Frequency msfreq = 0, mscfreq = 0;
    double msbcount = 0;
    int n, nsig = 0, old_in_msrec = in_msrec;
    unsigned i;

    isigclose();    // close any open input signals

    // If another output header file was opened, close it.
    if (oheader) {
        oheader->close();
        if (outinfo == oheader.get()) outinfo = nullptr;
        oheader.reset();
    }

    // Remove trailing .hea, if any, from record name.
    std::string recbuf = wfdb_striphea(record_arg);
    const char *record = recbuf.c_str();

    // Quit (with message from wfdb_checkname) if name is illegal.
    if (wfdb_checkname(record, "record")) return -1;

    if (nsegments < 1) {
        wfdb_error("setmsheader: record must contain at least one segment\n");
        return -1;
    }

    std::vector<WFDB_Time> ns(nsegments);
    for (i = 0; i < nsegments; i++) {
        if (std::strlen(segment_name[i]) > WFDB_MAXRNL) {
            wfdb_error("setmsheader: `%s' is too long for a segment name in "
                       "record %s\n", segment_name[i], record);
            return -2;
        }
        in_msrec = 1;
        nsamples = 0;
        user_segments = true;   // wfdb-x: names given by the caller
        n = readheader(segment_name[i]);
        user_segments = false;
        in_msrec = old_in_msrec;
        if (n < 0) {
            wfdb_error("setmsheader: can't read segment %s header\n",
                       segment_name[i]);
            return -3;
        }
        if ((ns[i] = nsamples) <= 0L) {
            wfdb_error("setmsheader: length of segment %s must be specified\n",
                       segment_name[i]);
            return -4;
        }
        if (i == 0) {
            nsig = n;
            msfreq = ffreq;
            mscfreq = cfreq;
            msbcount = bcount;
            msbtime = btime;
            msbdate = bdate;
            msnsamples = ns[i];
        } else {
            if (nsig != n) {
                wfdb_error("setmsheader: incorrect number of signals in "
                           "segment %s\n", segment_name[i]);
                return -4;
            }
            if (msfreq != ffreq) {
                wfdb_error("setmsheader: incorrect sampling frequency in "
                           "segment %s\n", segment_name[i]);
                return -4;
            }
            msnsamples += ns[i];
        }
    }

    // Try to create the header file.
    if ((oheader = wfdb_open("hea", record, WFDB_WRITE)) == nullptr) {
        wfdb_error("setmsheader: can't create header file for record %s\n",
                   record);
        return -1;
    }

    // Write the first line of the master header.
    std::string out = strprintf("%s/%u %d %.12g", record, nsegments, nsig,
                                msfreq);
    if ((mscfreq > 0.0 && mscfreq != msfreq) || msbcount != 0.0) {
        out += strprintf("/%.12g", mscfreq);
        if (msbcount != 0.0) out += strprintf("(%.12g)", msbcount);
    }
    out += strprintf(" %lld", msnsamples);
    if (msbtime != 0L || msbdate != 0) {
        if (msbtime % 1000 == 0)
            out += " " + ftimstr(msbtime, 1000.0);
        else
            out += std::string(" ") + fmstimstr(msbtime, 1000.0);
    }
    if (msbdate) out += datstr(msbdate);
    out += "\r\n";

    // Write a line for each segment.
    for (i = 0; i < nsegments; i++)
        out += strprintf("%s %lld\r\n", segment_name[i], ns[i]);
    oheader->write(out.data(), 1, out.size());
    return 0;
}

int wfdbgetskew(WFDB_Signal s)
{
    if (s < static_cast<unsigned>(nvsig))
        return vsd[s]->skew;
    else
        return 0;
}

// Careful!!  This function is dangerous, and should be used only to restore
// skews when they have been reset as a side effect of using, e.g., sampfreq.
void wfdbsetiskew(WFDB_Signal s, int skew)
{
    if (s < static_cast<unsigned>(nvsig) && skew >= 0 && tspf &&
        static_cast<unsigned>(skew) < dsblen / static_cast<unsigned>(tspf))
        vsd[s]->skew = skew;
}

// Note: wfdbsetskew affects *only* the skew to be written by setheader.
void wfdbsetskew(WFDB_Signal s, int skew)
{
    if (s < nosig) osd[s]->skew = skew;
}

long wfdbgetstart(WFDB_Signal s)
{
    if (s < nisig && s < vsd.size() && vsd[s]->info.group < igd.size())
        return igd[vsd[s]->info.group]->start;
    else if (s == 0 && !hsd.empty())
        return hsd[0].start;
    else
        return 0L;
}

// Note: wfdbsetstart affects *only* the byte offset to be written by
// setheader.
void wfdbsetstart(WFDB_Signal s, long bytes)
{
    if (s < nosig) ogd[osd[s]->info.group]->start = bytes;
    prolog_bytes = bytes;
}

int wfdbputprolog(const char *buf, long size, WFDB_Signal s)
{
    long n = 0;
    WFDB_Group g = osd[s]->info.group;

    if (ogd[g]->fp) n = static_cast<long>(ogd[g]->fp->write(buf, 1, size));
    wfdbsetstart(s, n);
    if (n != size)
        wfdb_error("wfdbputprolog: only %ld of %ld bytes written\n", n, size);
    return n == size ? 0 : -1;
}

// Create a .info file (or open it for appending).
int setinfo(const char *record_arg)
{
    // Close any previously opened output info file.
    int stat = wfdb_oinfoclose();

    // Quit unless a record name has been specified.
    if (record_arg == nullptr) return stat;

    // Remove trailing .hea, if any, from record name.
    std::string recbuf = wfdb_striphea(record_arg);
    const char *record = recbuf.c_str();

    // Quit (with message from wfdb_checkname) if name is illegal.
    if (wfdb_checkname(record, "record")) return -1;

    // Try to create the .info file.
    if ((outinfo_file = wfdb_open("info", record, WFDB_APPEND)) == nullptr) {
        wfdb_error("setinfo: can't create info file for record %s\n", record);
        return -1;
    }
    outinfo = outinfo_file.get();
    return 0;
}

// Write an info string to the open output .hea or .info file.
int putinfo(const char *s)
{
    if (outinfo == nullptr) {
        if (oheader)
            outinfo = oheader.get();
        else {
            wfdb_error("putinfo: caller has not specified a record name\n");
            return -1;
        }
    }
    outinfo->printf("#%s\r\n", s);
    outinfo->flush();
    return 0;
}

// getinfo: On the first call, read all info strings from the .hea file and
// (if available) the .info file for the specified record, and return the
// first one.  On subsequent calls, return the next info string.  Return
// nullopt if there are no more info strings.
std::optional<std::string> getinfo(const char *record_arg)
{
    if (record_arg) wfdb_freeinfo();

    if (!have_pinfo) {  // info for record has not yet been read
        std::string recbuf;
        if (record_arg == nullptr) {
            std::optional<std::string> r = wfdb_getirec();
            if (!r) {
                wfdb_error("getinfo: caller did not specify record name\n");
                return std::nullopt;
            }
            recbuf = *r;
        } else
            recbuf = record_arg;

        if (ninfo) {
            wfdb_freeinfo();
            ninfo = 0;
        }

        info_i = 0;
        have_pinfo = true;
        pinfo.clear();

        // As in C, an info string is the line after its initial '#', without
        // its line ending, up to its first null character.
        auto save = [](const std::string &b) {
            std::string l(b.c_str());
            if (!l.empty() && l.back() == '\n') l.pop_back();
            if (!l.empty() && l.back() == '\r') l.pop_back();
            pinfo.push_back(l.substr(1));
            ninfo++;
        };

        // Read info from the .hea file, if available (skip for EDF files).
        if (!isedf) {
            recbuf = wfdb_striphea(recbuf.c_str());
            FilePtr ifile = wfdb_open("hea", recbuf.c_str(), WFDB_READ);
            if (ifile) {
                // As with wfdb_getline(), the buffer keeps its previous
                // contents when the end of the file is reached.
                std::string buf, line;
                while (ifile->getline(line)) {
                    buf = line;
                    if (buf[0] != '#') break;   // skip initial comments
                }
                while (ifile->getline(line)) {
                    buf = line;
                    if (buf[0] == '#') break;   // skip header content
                }
                while (!buf.empty() && buf[0]) {    // read and save info
                    if (buf[0] == '#') save(buf);
                    if (ifile->getline(line) == 0) break;
                    buf = line;
                }
            }
        }
        // Read more info from the .info file, if available.
        FilePtr ifile = wfdb_open("info", recbuf.c_str(), WFDB_READ);
        if (ifile) {
            std::string buf;
            while (ifile->getline(buf))
                if (buf[0] == '#') save(buf);
        }
    }
    if (info_i < ninfo)
        return pinfo[info_i++];
    else
        return std::nullopt;
}

// Release resources allocated for info string handling.
void wfdb_freeinfo()
{
    pinfo.clear();
    have_pinfo = false;
    ninfo = 0;
}

WFDB_Frequency sampfreq(const char *record_arg)
{
    int n;

    if (record_arg != nullptr) {
        // Remove trailing .hea, if any, from record name.
        std::string record = wfdb_striphea(record_arg);
        // Save the current record name.
        wfdb_setirec(record.c_str());
        // Don't require the sampling frequency of this record to match that
        // of the previously opened record, if any.
        setsampfreq(0.);
        // readheader sets sfreq if successful.
        if ((n = readheader(record.c_str())) < 0)
            // error message will come from readheader
            return static_cast<WFDB_Frequency>(n);
    }
    return sfreq;
}

int setsampfreq(WFDB_Frequency freq)
{
    if (freq >= 0.) {
        sfreq = ffreq = freq;
        if (spfmax == 0) spfmax = 1;
        if ((gvmode & WFDB_HIGHRES) == WFDB_HIGHRES) sfreq *= spfmax;
        return 0;
    }
    wfdb_error("setsampfreq: sampling frequency must not be negative\n");
    return -1;
}

int setbasetime(const char *string_arg)
{
    pdays = -1;
    if (string_arg == nullptr || *string_arg == '\0') {
        std::time_t t = std::time(nullptr);  // current time from system clock
        std::tm *now = std::localtime(&t);
        std::snprintf(date_string, sizeof(date_string), "%02d/%02d/%d",
                      now->tm_mday, now->tm_mon + 1, now->tm_year + 1900);
        bdate = strdat(date_string);
        std::snprintf(time_string, sizeof(time_string), "%d:%d:%d",
                      now->tm_hour, now->tm_min, now->tm_sec);
        btime = static_cast<long>(fstrtim(time_string, 1000.0));
        return 0;
    }
    std::string strbuf(string_arg);
    char *string = &strbuf[0];
    char *p;
    while (*string == ' ') string++;
    if ((p = std::strchr(string, ' ')) != nullptr)
        *p++ = '\0';    // split time and date components
    btime = static_cast<long>(fstrtim(string, 1000.0));
    bdate = p ? strdat(p) : 0;
    if (btime == 0L && bdate == 0 && *string != '[') {
        if (p) *(--p) = ' ';
        wfdb_error("setbasetime: incorrect time format, '%s'\n", string);
        return -1;
    }
    return 0;
}

namespace detail {
namespace {

// Convert sample number to string, using the given sampling frequency.
std::string ftimstr(WFDB_Time t, WFDB_Frequency f)
{
    char *save = nullptr;
    char *p = xstrtok(const_cast<char *>(fmstimstr(t, f)), ".", &save);
    if (p == nullptr) return std::string();
    if (t <= 0L && (btime != 0L || bdate != 0)) {   // time of day
        size_t n = std::strlen(p);
        size_t room = sizeof(time_string) - (p - time_string);
        std::snprintf(p + n, room - n, "%s]", date_string);
    }
    return std::string(p);
}

// Convert sample number to string, using the given sampling frequency.
const char *fmstimstr(WFDB_Time t, WFDB_Frequency f)
{
    int hours, minutes, seconds, msec;
    WFDB_Date days;
    double tms;
    WFDB_Time s;

    if (t > 0L || (btime == 0L && bdate == 0)) {    // time interval
        if (t < 0L) t = -t;
        // Convert from sample intervals to seconds.
        s = static_cast<WFDB_Time>(t / f);
        msec = static_cast<int>((t - s * f) * 1000 / f + 0.5);
        if (msec == 1000) {
            msec = 0;
            s++;
        }
        t = s;
        seconds = static_cast<int>(t % 60);
        t /= 60;
        minutes = static_cast<int>(t % 60);
        hours = static_cast<int>(t / 60);
        if (hours > 0)
            std::snprintf(time_string, sizeof(time_string), "%2d:%02d:%02d.%03d",
                          hours, minutes, seconds, msec);
        else
            std::snprintf(time_string, sizeof(time_string), "   %2d:%02d.%03d",
                          minutes, seconds, msec);
    } else {    // time of day
        // Convert to milliseconds since midnight.
        tms = btime - (t * 1000.0 / f);
        // Convert to seconds.
        s = static_cast<WFDB_Time>(tms / 1000.0);
        msec = static_cast<int>((tms - s * 1000.0) + 0.5);
        if (msec == 1000) {
            msec = 0;
            s++;
        }
        t = s;
        seconds = static_cast<int>(t % 60);
        t /= 60;
        minutes = static_cast<int>(t % 60);
        t /= 60;
        hours = static_cast<int>(t % 24);
        days = static_cast<WFDB_Date>(t / 24);
        if (days != pdays) {
            if (bdate > 0)
                (void)datstr(days + bdate);
            else if (days == 0)
                date_string[0] = '\0';
            else
                std::snprintf(date_string, sizeof(date_string), " %ld", days);
            pdays = days;
        }
        std::snprintf(time_string, sizeof(time_string), "[%02d:%02d:%02d.%03d%s]",
                      hours, minutes, seconds, msec, date_string);
    }
    return time_string;
}

// Convert string to sample number, using the given sampling frequency.
WFDB_Time fstrtim(const char *string, WFDB_Frequency f)
{
    const char *p, *q, *r;
    double x, y, z;
    WFDB_Date days;
    WFDB_Time t;

    while (*string == ' ' || *string == '\t' || *string == '\n' ||
           *string == '\r')
        string++;
    switch (*string) {
    case 'c':
        return cfreq > 0. ?
            static_cast<WFDB_Time>((std::strtod(string + 1, nullptr) - bcount) *
                                   f / cfreq) :
            std::strtoll(string + 1, nullptr, 10);
    case 'e':
        return (in_msrec ? msnsamples : nsamples) *
            (((gvmode & WFDB_HIGHRES) == WFDB_HIGHRES) ? spfmax : 1);
    case 'f':
        return static_cast<WFDB_Time>(std::strtoll(string + 1, nullptr, 10) *
                                      f / ffreq);
    case 'i':
        return static_cast<WFDB_Time>(
            istime * (ifreq > 0.0 ? (ifreq / sfreq) : 1.0) *
            (((gvmode & WFDB_HIGHRES) == WFDB_HIGHRES) ? ispfmax : 1));
    case 'o':
        return ostime;
    case 's':
        return std::strtoll(string + 1, nullptr, 10);
    case '[':   // time of day, possibly with date or days since start
        if ((q = std::strchr(++string, ']')) == nullptr)
            return 0;   // '[...': malformed time string
        if ((p = std::strchr(string, ' ')) == nullptr || p > q)
            days = 0;   // '[hh:mm:ss.sss]': time since midnight only
        else if ((r = std::strchr(p + 1, '/')) == nullptr || r > q)
            days = std::strtol(p + 1, nullptr, 10);    // '[hh:mm:ss.sss d]'
        else
            days = strdat(p + 1) - bdate;   // '[hh:mm:ss.sss dd/mm/yyyy]'
        x = fstrtim(string, 1000.0) - btime;
        if (days > 0L) x += (days * (24 * 60 * 60 * 1000.0));
        t = static_cast<WFDB_Time>(x * f / 1000.0 + 0.5);
        return -t;
    default:
        x = std::strtod(string, nullptr);
        if ((p = std::strchr(string, ':')) == nullptr)
            return static_cast<long>(x * f + 0.5);
        y = std::strtod(++p, nullptr);
        if ((p = std::strchr(p, ':')) == nullptr)
            return static_cast<long>((60. * x + y) * f + 0.5);
        z = std::strtod(++p, nullptr);
        return static_cast<WFDB_Time>((3600. * x + 60. * y + z) * f + 0.5);
    }
}

} // namespace
} // namespace detail

namespace {

// wfdb-x: the time conversion functions need a sampling frequency; the C
// library used 1 sample per second when none was specified.  Without one,
// timstr and mstimstr report an error and return the time as a sample number
// ("s" followed by the number, a valid strtim argument), and strtim reports
// an error and returns 0 for time strings that need a frequency.  In legacy
// mode, they use 1 sample per second, as the C library did.
std::string nofreq_timstr(const char *fn, WFDB_Time t)
{
    wfdb_error("%s: sampling frequency is not specified\n", fn);
    return "s" + std::to_string(t < 0 ? -t : t);
}

} // namespace

// wfdbx_set_legacy (a wfdb-x addition) turns legacy mode on (if on is
// nonzero) or off, and returns the previous setting (1: on, 0: off).
int wfdbx_set_legacy(int on)
{
    int previous = legacy_mode;

    legacy_mode = (on != 0);
    return previous;
}

// wfdbx_get_legacy (a wfdb-x addition) returns 1 if legacy mode is on, 0
// otherwise.
int wfdbx_get_legacy()
{
    return legacy_mode;
}

// wfdbx_legacy_args (a wfdb-x addition) is called by the tools at the
// beginning of main, as wfdbx_legacy_args(argc, argv).  If the first argument
// (argv[1]) is "--legacy", it removes it from the argument list (the
// following arguments move up by one, argv[0] is unchanged, and argc is
// decremented), turns legacy mode on, and returns 1; the tool then behaves
// exactly as the original one.  Otherwise, it changes nothing and returns 0.
int wfdbx_legacy_args(int &argc, char **&argv)
{
    if (argc < 2 || std::strcmp(argv[1], "--legacy") != 0)
        return 0;
    argv[1] = argv[0];
    argv++;
    argc--;
    wfdbx_set_legacy(1);
    return 1;
}

// wfdbx_time_needs_freq (a wfdb-x addition) returns 1 if strtim needs a
// sampling frequency to convert the string, 0 otherwise.
int wfdbx_time_needs_freq(const char *string)
{
    while (*string == ' ' || *string == '\t' || *string == '\n' ||
           *string == '\r')
        string++;
    switch (*string) {
    case 'e': case 'i': case 'o': case 's': return 0;
    case 'c': return cfreq > 0.;
    default: return 1;
    }
}

std::string timstr(WFDB_Time t)
{
    double f;

    if (ifreq > 0.) f = ifreq;
    else if (sfreq > 0.) f = sfreq;
    else if (legacy_mode) f = 1.0;
    else return nofreq_timstr("timstr", t);

    return ftimstr(t, f);
}

std::string mstimstr(WFDB_Time t)
{
    double f;

    if (ifreq > 0.) f = ifreq;
    else if (sfreq > 0.) f = sfreq;
    else if (legacy_mode) f = 1.0;
    else return nofreq_timstr("mstimstr", t);

    return fmstimstr(t, f);
}

WFDB_Frequency getcfreq()
{
    return cfreq > 0. ? cfreq : ffreq;
}

void setcfreq(WFDB_Frequency freq)
{
    cfreq = freq;
}

double getbasecount()
{
    return bcount;
}

void setbasecount(double counter)
{
    bcount = counter;
}

WFDB_Time strtim(const char *string)
{
    double f;

    if (ifreq > 0.) f = ifreq;
    else if (sfreq > 0.) f = sfreq;
    else if (!legacy_mode && wfdbx_time_needs_freq(string)) {
        wfdb_error("strtim: sampling frequency is not specified\n");
        return 0L;
    } else f = 1.0;     // legacy mode; otherwise not used

    return fstrtim(string, f);
}

// The functions datstr and strdat convert between Julian dates (used
// internally) and dd/mm/yyyy format dates.  They are based on similar
// functions in chapter 1 of "Numerical Recipes", by Press, Flannery,
// Teukolsky, and Vetterling (Cambridge U. Press, 1986).
std::string datstr(WFDB_Date date)
{
    constexpr WFDB_Date IGREG = 2299161L;   // Julian date of 15/10/1582
    int d, m, y, gcorr, jm, jy;
    WFDB_Date jd;

    if (date >= IGREG) {        // Gregorian calendar correction
        gcorr = static_cast<int>(((date - 1867216L) - 0.25) / 36524.25);
        date += 1 + gcorr - static_cast<long>(0.25 * gcorr);
    }
    date += 1524;
    jy = static_cast<int>(6680 + ((date - 2439870L) - 122.1) / 365.25);
    jd = static_cast<WFDB_Date>(365L * jy + (0.25 * jy));
    jm = static_cast<int>((date - jd) / 30.6001);
    d = static_cast<int>(date - jd - static_cast<int>(30.6001 * jm));
    if ((m = jm - 1) > 12) m -= 12;
    y = jy - 4715;
    if (m > 2) y--;
    if (y <= 0) y--;
    std::snprintf(date_string, sizeof(date_string), " %02d/%02d/%d", d, m, y);
    pdays = -1;
    return date_string;
}

WFDB_Date strdat(const char *string)
{
    const char *mp, *yp;
    int d, m, y, gcorr, jm, jy;
    WFDB_Date date;

    if ((mp = std::strchr(string, '/')) == nullptr ||
        (yp = std::strchr(mp + 1, '/')) == nullptr ||
        (d = static_cast<int>(std::strtol(string, nullptr, 10))) < 1 || d > 31 ||
        (m = static_cast<int>(std::strtol(mp + 1, nullptr, 10))) < 1 || m > 12 ||
        (y = static_cast<int>(std::strtol(yp + 1, nullptr, 10))) == 0)
        return 0L;
    if (m > 2) {
        jy = y;
        jm = m + 1;
    } else {
        jy = y - 1;
        jm = m + 13;
    }
    if (jy > 0)
        date = static_cast<WFDB_Date>(365.25 * jy);
    else
        date = -static_cast<long>(-365.25 * (jy + 0.25));
    date += static_cast<int>(30.6001 * jm) + d + 1720995L;
    constexpr long IGREG = 15 + 31L * (10 + 12L * 1582);    // 15/10/1582
    if (d + 31L * (m + 12L * y) >= IGREG) {
        // Gregorian calendar correction
        gcorr = static_cast<int>(0.01 * jy);
        date += 2 - gcorr + static_cast<int>(0.25 * gcorr);
    }
    return date;
}

namespace {

// wfdb-x: the unit conversion functions need the gain of the signal; the C
// library assumed WFDB_DEFGAIN (200 adu per physical unit) for uncalibrated
// signals (gain 0) and invalid signal numbers (with a baseline of 0), as
// legacy mode does.  Otherwise they report an error and return
// WFDB_INVALID_SAMPLE (aduphys returns NaN).
WFDB_Gain conversion_gain(const char *fn, WFDB_Signal s)
{
    if (legacy_mode) {
        WFDB_Gain g = (s < static_cast<unsigned>(nvsig)) ? vsd[s]->info.gain
                                                         : WFDB_DEFGAIN;
        return g == 0. ? WFDB_DEFGAIN : g;
    }
    if (s >= static_cast<unsigned>(nvsig)) {
        wfdb_error("%s: invalid signal number %u\n", fn, s);
        return 0.;
    }
    if (vsd[s]->info.gain == 0.)
        wfdb_error("%s: signal %u is uncalibrated\n", fn, s);
    return vsd[s]->info.gain;
}

// The baseline of signal s (0 for an invalid signal number: legacy mode).
int conversion_baseline(WFDB_Signal s)
{
    return s < static_cast<unsigned>(nvsig) ? vsd[s]->info.baseline : 0;
}

} // namespace

int adumuv(WFDB_Signal s, WFDB_Sample a)
{
    double x;
    WFDB_Gain g = conversion_gain("adumuv", s);

    if (g == 0.) return WFDB_INVALID_SAMPLE;
    x = a * 1000. / g;
    if (x >= 0.0)
        return d2i(x + 0.5);
    else
        return d2i(x - 0.5);
}

WFDB_Sample muvadu(WFDB_Signal s, int v)
{
    double x;
    WFDB_Gain g = conversion_gain("muvadu", s);

    if (g == 0.) return WFDB_INVALID_SAMPLE;
    x = g * v * 0.001;
    if (x >= 0.0)
        return d2i(x + 0.5);
    else
        return d2i(x - 0.5);
}

double aduphys(WFDB_Signal s, WFDB_Sample a)
{
    WFDB_Gain g = conversion_gain("aduphys", s);

    if (g == 0.) return std::numeric_limits<double>::quiet_NaN();
    double b = conversion_baseline(s);
    return (a - b) / g;
}

WFDB_Sample physadu(WFDB_Signal s, double v)
{
    WFDB_Gain g = conversion_gain("physadu", s);

    if (g == 0.) return WFDB_INVALID_SAMPLE;
    int b = conversion_baseline(s);
    v *= g;
    if (v >= 0)
        return iadd(d2i(v + 0.5), b);
    else
        return iadd(d2i(v - 0.5), b);
}

// sample(s, t) provides buffered random access to the input signals.
WFDB_Sample sample(WFDB_Signal s, WFDB_Time t)
{
    int nsig = (nvsig > static_cast<int>(nisig)) ? nvsig : static_cast<int>(nisig);
    // getvec may store tspf samples per call.
    int stride = nsig;

    // Allocate the sample buffer on the first call.
    if (!have_sbuf) {
        size_t width = static_cast<size_t>(nsig > tspf ? nsig : tspf);
        sbuf.assign((width ? width : 1) * BUFLN + width, 0);
        have_sbuf = true;
        sample_tt = -1;
    }

    // If the caller requested a sample from an unavailable signal, return an
    // invalid value.  Note that sample_vflag is not cleared in this case.
    if (s >= static_cast<unsigned>(nsig)) {
        sample_vflag = -1;
        return WFDB_INVALID_SAMPLE;
    }

    // If the caller specified a negative sample number, prepare to return
    // sample 0.
    if (t < 0L) t = 0L;

    // If the caller has requested a sample that is no longer in the buffer,
    // or that is further ahead than the length of the buffer, reset the
    // signal file pointer(s).
    if (t <= sample_tt - BUFLN || t > sample_tt + BUFLN) {
        sample_tt = t - BUFLN;
        if (sample_tt < 0L) sample_tt = -1L;
        if (isigsettime(sample_tt + 1) < 0) {
            sample_vflag = 0;
            return WFDB_INVALID_SAMPLE;
        }
    }
    // If the requested sample is not yet in the buffer, read and buffer more
    // samples.  If we reach the end of the record, clear sample_vflag and
    // return the last valid value.
    while (t > sample_tt) {
        if (getvec(sbuf.data() + stride * ((++sample_tt) & (BUFLN - 1))) < 0) {
            --sample_tt;
            sample_vflag = 0;
            return sbuf[stride * (sample_tt & (BUFLN - 1)) + s];
        }
    }

    // The requested sample is in the buffer.  Set sample_vflag and return
    // the requested sample.
    if ((sample_v = sbuf[stride * (t & (BUFLN - 1)) + s]) == WFDB_INVALID_SAMPLE)
        sample_vflag = -1;
    else
        sample_vflag = 1;
    return sample_v;
}

int sample_valid()
{
    return sample_vflag;
}

} // namespace wfdbx
