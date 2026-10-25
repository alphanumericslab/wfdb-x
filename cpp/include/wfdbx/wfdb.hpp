// wfdbx/wfdb.hpp: the WFDB library API (C++ implementation of wfdb-x)
//
// This header declares, in namespace wfdbx, the C++ equivalent of every
// function of the WFDB library (WFDB Software Package 10.7.0, <wfdb/wfdb.h>).
// The functions have the names, arguments, return values and behavior of
// their C counterparts, so that WFDB programs can be ported line by line; the
// WFDB Programmer's Guide remains the complete reference.  The differences
// are in the types:
//
//  * String arguments are `const char *` (a null pointer is accepted where C
//    accepts NULL).
//  * Strings returned by the library (timstr, annstr, getwfdb, ...) are
//    returned by value as `std::string`, or as `std::optional<std::string>`
//    where the C function may return NULL.  Unlike the C pointers, they stay
//    valid after later library calls.
//  * The string fields of WFDB_Siginfo, WFDB_Calinfo and WFDB_Annotation are
//    `std::optional<std::string>`, since C distinguishes NULL from an empty
//    string; the name of WFDB_Anninfo is a `std::string`.
//  * WFDB_Time is 64 bits (as in the C library built with -DWFDB_LARGETIME).
//
// As in C, arrays (of WFDB_Siginfo, of samples, ...) are allocated by the
// caller and must be large enough for the number of elements stated below.
//
// Errors: unless stated otherwise, a negative return value indicates an
// error.  The library prints a message on stderr (see wfdbquiet()) and keeps
// the last one (see wfdberror()).
//
// As in C, the library keeps global state (the open record, signals,
// annotators and settings); it is not thread-safe.  For reading and writing
// whole records, see the higher-level interface of <wfdbx/record.hpp>.
//
//     #include <wfdbx/wfdb.hpp>
//     using namespace wfdbx;
//
//     WFDB_Siginfo si[2];
//     if (isigopen("100s", si, 2) == 2) {
//         WFDB_Sample v[2];
//         while (getvec(v) > 0) { /* v[0], v[1]: one sample per signal */ }
//     }
//     wfdbquit();
//
// Copyright (C) 1983-2013 George B. Moody (original C header, lib/wfdb.h;
// revised 2010-2020 by Benjamin Moody).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

#ifndef WFDBX_WFDB_HPP
#define WFDBX_WFDB_HPP

#include <climits>
#include <cfloat>
#include <optional>
#include <string>

namespace wfdbx {

/// @name Version of the WFDB Software Package implemented
/// @{
constexpr int WFDB_MAJOR = 10;
constexpr int WFDB_MINOR = 7;
constexpr int WFDB_RELEASE = 0;
/// @}

// ---------------------------------------------------------------------------
// Types

using WFDB_Sample = int;            ///< units are adus (ADC units)
using WFDB_Time = long long;        ///< units are sample intervals
using WFDB_Date = long;             ///< units are days (Julian date)
using WFDB_Frequency = double;      ///< units are Hz
using WFDB_Gain = double;           ///< units are adus per physical unit
using WFDB_Group = unsigned int;    ///< signal group number
using WFDB_Signal = unsigned int;   ///< signal number
using WFDB_Annotator = unsigned int; ///< annotator number

/// @name Ranges of the sample and time types
/// @{
constexpr WFDB_Sample WFDB_SAMPLE_MIN = INT_MIN;
constexpr WFDB_Sample WFDB_SAMPLE_MAX = INT_MAX;
constexpr WFDB_Time WFDB_TIME_MIN = LLONG_MIN;
constexpr WFDB_Time WFDB_TIME_MAX = LLONG_MAX;
/// @}

/// Value returned by getvec() and getframe() for invalid (missing) samples,
/// unless padding is enabled (see WFDB_GVPAD).  putvec() writes it as the
/// lowest value of the output format.
constexpr WFDB_Sample WFDB_INVALID_SAMPLE = -32768;

/// @name Historical limits
/// Kept for compatibility; they are no longer limits of the library itself.
/// @{
constexpr int WFDB_MAXANN = 2;
constexpr int WFDB_MAXSIG = 32;
constexpr int WFDB_MAXSPF = 4;
constexpr int WFDB_MAXRNL = 50;     ///< maximum length of a record name
constexpr int WFDB_MAXUSL = 50;     ///< maximum length of a units string
constexpr int WFDB_MAXDSL = 100;    ///< maximum length of a signal description
/// @}

/// @name Annotation file and info file types (WFDB_Anninfo::stat)
/// @{
constexpr int WFDB_READ = 0;        ///< standard input annotation file
constexpr int WFDB_WRITE = 1;       ///< standard output annotation file
constexpr int WFDB_AHA_READ = 2;    ///< AHA-format input annotation file
constexpr int WFDB_AHA_WRITE = 3;   ///< AHA-format output annotation file
constexpr int WFDB_APPEND = 4;      ///< for output info files
/// @}

/// Supported signal storage formats (WFDB_NFMTS entries).
constexpr int WFDB_FMT_LIST[] = {0, 8, 16, 61, 80, 160, 212, 310, 311, 24, 32,
                                 508, 516, 524};
constexpr int WFDB_NFMTS = 14;

/// C's default sampling frequency (Hz), gain (adu/physical unit) and ADC
/// resolution (bits), kept for compatibility.  wfdb-x never assumes them:
/// the library does not use them (see docs/DIVERGENCES.md).
constexpr double WFDB_DEFFREQ = 250.0;
constexpr double WFDB_DEFGAIN = 200.0;
constexpr int WFDB_DEFRES = 12;

/// @name getvec operating modes (see setgvmode())
/// @{
constexpr int WFDB_LOWRES = 0;      ///< one sample per signal per frame
constexpr int WFDB_HIGHRES = 1;     ///< each sample of oversampled signals
constexpr int WFDB_GVPAD = 2;       ///< replace invalid samples (flag)
/// @}

/// @name Calibration pulse types (WFDB_Calinfo::caltype)
/// A coupling (AC or DC) plus a pulse shape, e.g.
/// `WFDB_DC_COUPLED | WFDB_CAL_SQUARE`.
/// @{
constexpr int WFDB_AC_COUPLED = 0;
constexpr int WFDB_DC_COUPLED = 1;
constexpr int WFDB_CAL_SQUARE = 2;
constexpr int WFDB_CAL_SINE = 4;
constexpr int WFDB_CAL_SAWTOOTH = 6;
constexpr int WFDB_CAL_UNDEF = 8;
/// @}

/// Signal information (WFDB_Siginfo): one entry of a record's header.
struct WFDB_Siginfo {
    std::optional<std::string> fname;   ///< name of the signal file
    std::optional<std::string> desc;    ///< signal description
    std::optional<std::string> units;   ///< physical units (none: unspecified)
    WFDB_Gain gain = 0;         ///< gain (adu/physical unit, 0: uncalibrated)
    WFDB_Sample initval = 0;    ///< initial value (that of sample number 0)
    WFDB_Group group = 0;       ///< signal group number
    int fmt = 0;                ///< storage format (8, 16, etc.)
    int spf = 0;                ///< samples per frame (>1: oversampled)
    int bsize = 0;              ///< block size (for character special files)
    int adcres = 0;             ///< ADC resolution in bits (0: unspecified)
    int adczero = 0;            ///< ADC output given 0 VDC input
    int baseline = 0;           ///< ADC output given 0 physical units input
    long nsamp = 0;             ///< number of samples (0: unspecified)
    int cksum = 0;              ///< 16-bit checksum of all samples
};

/// Calibration information (WFDB_Calinfo): an entry of the calibration list.
struct WFDB_Calinfo {
    double low = 0;             ///< low level of calibration pulse
    double high = 0;            ///< high level of calibration pulse
    double scale = 0;           ///< customary plotting scale (units per cm)
    std::optional<std::string> sigtype; ///< signal type
    std::optional<std::string> units;   ///< physical units
    int caltype = 0;            ///< calibration pulse type (see above)
};

/// Annotator information (WFDB_Anninfo), as passed to annopen().
struct WFDB_Anninfo {
    std::string name;           ///< annotator name (file suffix, e.g. "atr")
    int stat = 0;               ///< WFDB_READ, WFDB_WRITE, ...
};

/// Annotation (WFDB_Annotation).  As in C, `aux` is either absent (NULL) or
/// holds the auxiliary information preceded by a byte that gives its length:
/// aux[0] is the length, the data follow (e.g. "\x02(N" for the text "(N").
struct WFDB_Annotation {
    WFDB_Time time = 0;         ///< time, in sample intervals from the start
    char anntyp = 0;            ///< annotation type (see ecgcodes.hpp)
    signed char subtyp = 0;     ///< annotation subtype
    unsigned char chan = 0;     ///< channel number
    signed char num = 0;        ///< annotator number
    std::optional<std::string> aux; ///< auxiliary information
};

/// Segment of a multi-segment record (WFDB_Seginfo; see getseginfo()).
struct WFDB_Seginfo {
    char recname[WFDB_MAXRNL + 1] = {};  ///< segment name
    WFDB_Time nsamp = 0;        ///< number of samples in segment
    WFDB_Time samp0 = 0;        ///< sample number of first sample
};

/// @name Shorter names for the types above
/// @{
using Sample = WFDB_Sample;
using Time = WFDB_Time;
using Date = WFDB_Date;
using Frequency = WFDB_Frequency;
using Gain = WFDB_Gain;
using Siginfo = WFDB_Siginfo;
using Calinfo = WFDB_Calinfo;
using Anninfo = WFDB_Anninfo;
using Annotation = WFDB_Annotation;
using Seginfo = WFDB_Seginfo;
/// @}

// ---------------------------------------------------------------------------
// Functions
//
// Records and other input files are searched for in the directories of the
// WFDB path (see setwfdb()).  Output files are created as "<record>.<type>"
// (e.g. "100s.hea", "100s.atr"), relative to the current directory.

/// @name Opening and closing records
/// @{

/// Open the `nann` annotation files described by `aiarray` for `record`:
/// input files for stat WFDB_READ or WFDB_AHA_READ, output files for
/// WFDB_WRITE or WFDB_AHA_WRITE.  Input and output annotators are numbered
/// separately (0, 1, ...), in the order of `aiarray`.  Previously opened
/// annotation files are closed first, unless `record` begins with '+'.
/// Returns 0 on success, -3 if an input file cannot be read, -4 if an output
/// file cannot be created, -5 for an invalid `stat`.  If nann is 0, only
/// closes the open annotation files, and returns 0 or a negative value
/// reporting a problem in closing them (-6: output annotations were out of
/// order, -7: write error).
int annopen(const char *record, const WFDB_Anninfo *aiarray, unsigned nann);
/// Open the input signals of `record`, and fill `siarray` (nsig entries)
/// with their descriptions.  Previously opened input signals are closed
/// first, unless `record` begins with '+'.  Signals stored in the same file
/// (a signal group) are opened together: a group is skipped if its file
/// cannot be opened or if it does not fit in the remaining entries.  Returns
/// the number of signals opened (possibly fewer than nsig), or a negative
/// value on error (-1 if the header cannot be read, -2 if it is invalid).
/// If nsig <= 0, no signals are opened: up to -nsig entries of `siarray`
/// (which may be nullptr) are filled from the header, and the number of
/// signals of the record is returned.
int isigopen(const char *record, WFDB_Siginfo *siarray, int nsig);
/// Open `nsig` output signals as described by the header of `record` (an
/// existing record), filling `siarray` with their descriptions.  Previously
/// opened output signals are closed first, unless `record` begins with '+'.
/// Returns the number of signals opened, or a negative value on error (for
/// example -3 if the record has fewer than nsig signals or a signal file
/// cannot be created).
int osigopen(const char *record, WFDB_Siginfo *siarray, unsigned nsig);
/// Open `nsig` output signals as described by `siarray` (fname, fmt, gain,
/// ...; signals of the same group must have the same fname, and group
/// numbers must increase by 1 with each new file).  Previously opened output
/// signals are closed.  Returns the number of signals opened, or a negative
/// value on error (-2 for an invalid specification, -3 if a file cannot be
/// created).
int osigfopen(const WFDB_Siginfo *siarray, unsigned nsig);
/// annopen() followed, if it succeeds, by isigopen(); returns the result of
/// the last call made (the number of input signals on success).
int wfdbinit(const char *record, const WFDB_Anninfo *aiarray, unsigned nann,
             WFDB_Siginfo *siarray, unsigned nsig);
/// Close all open files (flushing buffered output and terminating output
/// annotation files), release the library's buffers and reset the state of
/// the open record; the WFDB path is restored (see resetwfdb()).  Headers
/// are not written: call newheader() or setheader() first.  Call wfdbquit()
/// before exiting after writing files.
void wfdbquit();
/// Write all buffered output signal and annotation data to their files.
void wfdbflush();
/// @}

/// @name Reading and writing signals
/// @{

/// Number of the open input signal whose description is `signame`; a string
/// of digits is taken as a signal number if such a signal exists.  Returns
/// -1 if there is no such signal.
int findsig(const char *signame);
/// The number of getvec() results per frame: the maximum samples per frame
/// of the open signals in WFDB_HIGHRES mode, 1 otherwise.
int getspf();
/// Set the getvec mode: WFDB_LOWRES (oversampled signals are averaged to one
/// sample per frame) or WFDB_HIGHRES (every sample is returned, the other
/// signals being repeated), optionally or'ed with WFDB_GVPAD (invalid
/// samples are replaced by the previous valid sample).  A negative `mode`
/// restores the default (from the WFDBGVMODE environment variable, or
/// WFDB_LOWRES).
void setgvmode(int mode);
/// The current getvec mode.
int getgvmode();
/// Resample the input signals to `freq` (Hz) in getvec() (by linear
/// interpolation), after isigopen().  Returns 0, or -1 if no record is open,
/// its sampling frequency is not specified (wfdb-x), or freq <= 0.
int setifreq(WFDB_Frequency freq);
/// The sampling frequency of the samples returned by getvec() (the one set
/// by setifreq(), or that of the open record).
WFDB_Frequency getifreq();
/// Read the next sample of each open input signal into `vector` (one entry
/// per signal).  Returns the number of input signals, -1 at the end of the
/// data, -3 on an unexpected end of file (or a decoding error), -4 on a
/// checksum error.
int getvec(WFDB_Sample *vector);
/// Read the next frame into `vector`: spf samples of each input signal, in
/// signal order (sum of the signals' spf entries).  Return values as for
/// getvec().
int getframe(WFDB_Sample *vector);
/// Write a frame to the open output signals: `vector` holds spf samples of
/// each signal, in signal order.  Returns the number of output signals, 0 if
/// a first difference was too large for format 8 (the difference is then
/// clipped), or -1 on a write error.
int putvec(const WFDB_Sample *vector);
/// Skip to sample `t` of every input signal (negative values are taken as
/// their absolute value); returns 0 on success.
int isigsettime(WFDB_Time t);
/// Skip to sample `t` of the input signals of group `g`; returns 0 on
/// success.
int isgsettime(WFDB_Group g, WFDB_Time t);
/// Time of the next valid sample of input signal `s` at or after `t`; the
/// input signals are positioned at that time.  Returns a negative value if
/// there is none or on error.
WFDB_Time tnextvec(WFDB_Signal s, WFDB_Time t);
/// Sample `t` of input signal `s` (random access through a buffer that is
/// filled with getvec(), so the position of the input signals changes).
/// Returns WFDB_INVALID_SAMPLE if the sample is not available; see
/// sample_valid().
WFDB_Sample sample(WFDB_Signal s, WFDB_Time t);
/// Status of the value last returned by sample(): 1 if it is valid, -1 if it
/// is WFDB_INVALID_SAMPLE, 0 if it is beyond the end of the record.
int sample_valid();
/// @}

/// @name Reading and writing annotations
/// @{

/// Read the next annotation of input annotator `a` into `annot`.  Returns 0,
/// -1 at the end of the file, -2 if `a` is not open, -3 on an unexpected end
/// of file.
int getann(WFDB_Annotator a, WFDB_Annotation *annot);
/// Push back `annot`, to be returned by the next getann(a, ...).  Returns 0,
/// -1 if an annotation is already pushed back, -2 if `a` is not open.
int ungetann(WFDB_Annotator a, const WFDB_Annotation *annot);
/// Write `annot` to output annotator `a`.  Annotations should be written in
/// time order; otherwise the file is sorted when it is closed (see
/// oannclose()).  Returns 0, -1 on a write error, -2 if `a` is not open.
int putann(WFDB_Annotator a, const WFDB_Annotation *annot);
/// Skip every input annotator to its first annotation at or after time `t`
/// (negative values are taken as their absolute value).  Returns 0, or -1
/// if no annotator could be positioned.
int iannsettime(WFDB_Time t);
/// Close input annotator `a`; the following input annotators are
/// renumbered.
void iannclose(WFDB_Annotator a);
/// Close output annotator `a`; the following output annotators are
/// renumbered.  If annotations were written out of order, the file is
/// sorted (unless the WFDBANNSORT environment variable is 0), with the result
/// of `sortann -r. RECORD -a ANNOTATOR`.  wfdb-x: the file is sorted in this
/// process; the C library (and legacy mode) runs the sortann program.
void oannclose(WFDB_Annotator a);
/// Set the time resolution (ticks per second) recorded in output annotation
/// files (0: none, the sampling frequency of the record applies).  It is
/// used by the files to which no annotation has been written yet.
void setafreq(WFDB_Frequency f);
/// The time resolution set by setafreq().
WFDB_Frequency getafreq();
/// Set the time resolution (ticks per second) of the times returned by
/// getann() for input annotator `a`.
void setiafreq(WFDB_Annotator a, WFDB_Frequency f);
/// The time resolution of the times returned for input annotator `a`, or -2
/// if `a` is not open.
WFDB_Frequency getiafreq(WFDB_Annotator a);
/// The time resolution recorded in the file of input annotator `a` (0 if
/// none), or -2 if `a` is not open.
WFDB_Frequency getiaorigfreq(WFDB_Annotator a);
/// @}

/// @name Annotation codes and mnemonics
/// Codes are those of ecgcodes.hpp (0 to ACMAX).  ecgstr()/strecg() use the
/// standard mnemonics ("N", "V", ...); annstr()/strann() use the mnemonics
/// in effect for the open annotation files (which may redefine them).
///
/// * ecgstr(), annstr(): the mnemonic of `code`; codes out of range give
///   "[code]".
/// * strecg(), strann(): the code of `mnemonic`, or NOTQRS if unknown.
/// * anndesc(): the description of `code`; nullopt if the code has none,
///   "illegal annotation code" if it is out of range.
/// * setecgstr(), setannstr(), setanndesc(): change a mnemonic or
///   description; return 0, or -1 if the code is out of range.  A
///   positive code given to setannstr() or setanndesc() also marks the
///   definition to be saved in output annotation files opened afterwards;
///   pass -code to change it without saving it.
/// * wfdb_isann() ... wfdb_setannpos(): the functions behind the macros of
///   <ecgmap.h>; use the equivalent functions of ecgmap.hpp.
/// @{
std::optional<std::string> ecgstr(int code);
int strecg(const char *mnemonic);
int setecgstr(int code, const char *mnemonic);
std::optional<std::string> annstr(int code);
int strann(const char *mnemonic);
int setannstr(int code, const char *mnemonic);
std::optional<std::string> anndesc(int code);
int setanndesc(int code, const char *description);
int wfdb_isann(int code);
int wfdb_isqrs(int code);
int wfdb_setisqrs(int code, int newval);
int wfdb_map1(int code);
int wfdb_setmap1(int code, int newval);
int wfdb_map2(int code);
int wfdb_setmap2(int code, int newval);
int wfdb_ammap(int code);
int wfdb_mamap(int code, int subtype);
int wfdb_annpos(int code);
int wfdb_setannpos(int code, int newval);
/// @}

/// @name Time and date conversion
/// Times are converted using the sampling frequency of the open record (or
/// that set by setifreq()).  wfdb-x: if no sampling frequency is specified
/// (C assumed 1 sample per second), timstr() and mstimstr() report an error
/// and return the time as a sample number ("s" followed by |t|), and strtim()
/// reports an error and returns 0 for strings that need the frequency (see
/// wfdbx_time_needs_freq() and docs/DIVERGENCES.md).
/// @{

/// Time `t` as a string: an elapsed time ("0:10", "1:02:03", right-aligned
/// with leading spaces) if t > 0 or if the base time of the record is
/// unknown; otherwise the time of day of sample -t, "[hh:mm:ss dd/mm/yyyy]"
/// (the date only if known).
std::string timstr(WFDB_Time t);
/// As timstr(), with milliseconds ("0:10.000", "[12:34:56.789 31/12/1999]").
std::string mstimstr(WFDB_Time t);
/// The sample number given by a time string: an elapsed time ("1:30",
/// "90.5"), a sample number ("s1000"), a time of day ("[12:00:00]",
/// "[12:00:00 01/01/2020]"), or "e" (the end of the record).  Times of day
/// are returned as negative values (-sample number).
WFDB_Time strtim(const char *time_string);
/// (wfdb-x addition) 1 if strtim() needs a sampling frequency to convert
/// `time_string`, 0 if it does not: strings starting (after leading spaces,
/// tabs, newlines and CRs) with 'e', 'i', 'o' or 's', or with 'c' if the
/// counter frequency is <= 0.
int wfdbx_time_needs_freq(const char *time_string);
/// (wfdb-x addition) Turn legacy mode on (`on` nonzero) or off, and return
/// the previous setting (1: on, 0: off).  In legacy mode, the library
/// behaves exactly as the original WFDB library, with its built-in defaults
/// (WFDB_DEFFREQ for a header without a frequency, an ADC resolution
/// inferred from the format or WFDB_DEFRES, 1 sample per second in the time
/// conversions, WFDB_DEFGAIN in the unit conversions).  For compatibility
/// only: see docs/DIVERGENCES.md.  Default: off.
int wfdbx_set_legacy(int on);
/// (wfdb-x addition) 1 if legacy mode is on, 0 otherwise.
int wfdbx_get_legacy();
/// (wfdb-x addition) If the first argument of a tool (argv[1]) is exactly
/// "--legacy", remove it (argv[0] is kept, argc is decremented), turn legacy
/// mode on and return 1; otherwise change nothing and return 0.
int wfdbx_legacy_args(int &argc, char **&argv);
/// (wfdb-x addition) Set the directory in which output files are created:
/// wfdb_open, for writing or appending, then creates the file DIR/NAME,
/// where NAME is the name it would use otherwise (the record name and file
/// type; the header still records the names as given).  nullptr or "" means
/// none (the default: files are created as named).  Returns the previous
/// value (std::nullopt if none).  Not reset by wfdbquit(); the same in
/// legacy mode.
std::optional<std::string> wfdbx_set_output_dir(const char *dir);
/// (wfdb-x addition) The directory set by wfdbx_set_output_dir()
/// (std::nullopt if none).
std::optional<std::string> wfdbx_get_output_dir();
/// Julian date `d` as " dd/mm/yyyy" (with a leading space).
std::string datstr(WFDB_Date d);
/// Julian date of a "dd/mm/yyyy" string, or 0 if it is invalid.
WFDB_Date strdat(const char *date_string);
/// @}

/// @name Amplitude conversion (input signal `s`)
/// The gain and baseline of the open input signal `s` are used.  wfdb-x: if
/// `s` is not open or is uncalibrated (gain 0), these functions report an
/// error and return WFDB_INVALID_SAMPLE (aduphys(): NaN); C assumed the
/// gain WFDB_DEFGAIN (see docs/DIVERGENCES.md).
/// @{

/// ADC units to microvolts (rounded).
int adumuv(WFDB_Signal s, WFDB_Sample a);
/// Microvolts to ADC units (rounded).
WFDB_Sample muvadu(WFDB_Signal s, int microvolts);
/// ADC units to physical units: (a - baseline) / gain.
double aduphys(WFDB_Signal s, WFDB_Sample a);
/// Physical units to ADC units: round(v * gain) + baseline.
WFDB_Sample physadu(WFDB_Signal s, double v);
/// @}

/// @name Calibration
/// @{

/// Read a calibration file (nullptr: the file named by $WFDBCAL, or
/// "wfdbcal"), searched for in the WFDB path.  The calibration list is
/// emptied first, unless the name begins with '+'.  Returns 0, or -2 if the
/// file cannot be read.
int calopen(const char *calibration_filename);
/// Copy to `cal` the first calibration list entry whose signal type is a
/// prefix of `description` and whose units are `units` (nullptr matches
/// anything).  Returns 0 if found, -1 otherwise.
int getcal(const char *description, const char *units, WFDB_Calinfo *cal);
/// Append a copy of `cal` to the calibration list; returns 0.
int putcal(const WFDB_Calinfo *cal);
/// Write the calibration list to a new file; returns 0, or -1 on error.
int newcal(const char *calibration_filename);
/// Empty the calibration list.
void flushcal();
/// @}

/// @name Info strings
/// Info strings are the comment lines ("#...") that follow the signal
/// specifications in a header, and the lines of the record's ".info" file.
/// @{

/// If `record` is not nullptr, read the info strings of `record` and return
/// the first; otherwise return the next one (reading those of the open
/// record on the first call).  Returns nullopt when there are no more.
std::optional<std::string> getinfo(const char *record);
/// Append `info` as an info string to the info file opened by setinfo(),
/// or otherwise to the header last written; returns 0, or -1 if there is
/// neither.
int putinfo(const char *info);
/// Open the info file "<record>.info" for appending (nullptr: close it);
/// returns 0 on success.
int setinfo(const char *record);
/// Release the info strings read by getinfo().
void wfdb_freeinfo();
/// @}

/// @name Header files
/// @{

/// Write the header of `record` for the open output signals (after the
/// samples have been written with putvec()).  Returns 0, or -1 on error.
int newheader(const char *record);
/// Write the header of `record` for the `nsig` signals described by
/// `siarray`.  Returns 0, or -1 on error.
int setheader(const char *record, WFDB_Siginfo *siarray, unsigned nsig);
/// Write the header of a multi-segment record made of the `nsegments`
/// records named in `segnames` (which must exist and have the same number
/// of signals and sampling frequency).  Returns 0, or a negative value on
/// error.
int setmsheader(const char *record, const char *const *segnames,
                unsigned nsegments);
/// Point `*segments` at the segment table of the open multi-segment record
/// (nullptr if there is none; the table belongs to the library and is valid
/// until the record is closed).  Returns the number of segments (0 if the
/// record is not multi-segment).
int getseginfo(const WFDB_Seginfo **segments);
/// Skew (in frames) of input signal `s` (0 if `s` is not open).
int wfdbgetskew(WFDB_Signal s);
/// Change the skew of input signal `s` (to restore a skew reset as a side
/// effect of another call).
void wfdbsetiskew(WFDB_Signal s, int skew);
/// Set the skew of output signal `s` to be written by setheader()/newheader().
void wfdbsetskew(WFDB_Signal s, int skew);
/// Length of the prolog (the byte offset of sample 0) of the signal file of
/// input signal `s`.
long wfdbgetstart(WFDB_Signal s);
/// Set the prolog length of output signal `s` to be written by
/// setheader()/newheader().
void wfdbsetstart(WFDB_Signal s, long bytes);
/// Write `bytes` bytes of `prolog` at the current position (normally the
/// start) of the file of output signal `s`, and record that length as with
/// wfdbsetstart().  Returns 0, or -1 if not all bytes were written.
int wfdbputprolog(const char *prolog, long bytes, WFDB_Signal s);
/// @}

/// @name Frequencies and base time
/// @{

/// Sampling frequency (Hz) of `record`, read from its header, or of the open
/// record if `record` is nullptr.  Returns a negative value if the header
/// cannot be read, and 0 if it does not specify the frequency (wfdb-x; C
/// assumed WFDB_DEFFREQ).
WFDB_Frequency sampfreq(const char *record);
/// Set the sampling frequency (Hz) used for time conversions and written to
/// new headers; returns 0, or -1 if it is negative.
int setsampfreq(WFDB_Frequency sampling_frequency);
/// The counter frequency (that of the record's counter, or the sampling
/// frequency if it has none).
WFDB_Frequency getcfreq();
/// Set the counter frequency (0: none) written to new headers.
void setcfreq(WFDB_Frequency counter_frequency);
/// The counter value of sample 0.
double getbasecount();
/// Set the counter value of sample 0 written to new headers.
void setbasecount(double count);
/// Set the base time (and date) of the record: "hh:mm:ss dd/mm/yyyy", or
/// the current time if nullptr or empty.  Returns 0, or -1 if the string is
/// invalid.
int setbasetime(const char *time_string);
/// @}

/// @name Error handling, WFDB path, miscellaneous
/// @{

/// Stop printing error messages on stderr.
void wfdbquiet();
/// Resume printing error messages (the default).
void wfdbverbose();
/// The last error message (or, if there was none, the library version).
std::string wfdberror();
/// Report an error (printf-style): the message is saved for wfdberror() and
/// printed on stderr unless wfdbquiet() is in effect.
void wfdb_error(const char *format, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 1, 2)))
#endif
    ;
/// The value set by wfdbmemerr() (1 by default).  Provided for
/// compatibility; it has no other effect.
int wfdb_me_fatal();
void wfdbmemerr(int exit_on_error);
/// Set the WFDB path, the list of directories where input files are
/// searched for (separated by spaces, ';' or ':'; "@file" reads the path
/// from a file); nullptr: $WFDB, or the default.  The value is also
/// exported as the WFDB environment variable.  Remote (http, ftp) components
/// are ignored.
void setwfdb(const char *database_path);
/// The current WFDB path.
std::string getwfdb();
/// Restore the initial WFDB path (from $WFDB or the default), if the path
/// had been read before it was changed by setwfdb().
void resetwfdb();
/// Set the input or output buffer size (bytes) of signal files opened
/// afterwards (0: the default).  Returns the new size, -1 if signals are
/// already open, -2 if the size is negative.
int setibsize(int input_buffer_size);
int setobsize(int output_buffer_size);
/// The path name of the file of `record` with type (suffix) `file_type`, as
/// found in the WFDB path, or nullopt if it cannot be found.  wfdb-x: input
/// files named by an absolute path are opened directly (C, and legacy mode:
/// they are searched for in the WFDB path like any other name; an empty
/// component, as in setwfdb(";"), uses names as given).
std::optional<std::string> wfdbfile(const char *file_type, const char *record);
/// Library version ("10.7.0").
std::string wfdbversion();
/// Build flags of the C library (empty strings here).
std::string wfdbldflags();
std::string wfdbcflags();
/// The default WFDB path, and the default calibration file name.
std::string wfdbdefwfdb();
std::string wfdbdefwfdbcal();
/// @}

/// @name Additions (not in the C library)
/// @{

/// Read up to `n` getvec() results into `out`, with exactly the semantics
/// of n calls of getvec() but faster.  `out` must have room for n times the
/// number of values returned by getvec().  Returns the number read (>= 0),
/// or the negative value returned by getvec() if none could be read.
long long getvecs(WFDB_Sample *out, long long n);
/// @}

} // namespace wfdbx

#endif // WFDBX_WFDB_HPP
