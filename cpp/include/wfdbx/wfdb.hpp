// wfdbx/wfdb.hpp: the WFDB library API (C++ version of <wfdb/wfdb.h>).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of lib/wfdb.h from the WFDB Software Package 10.7.0,
// by George B. Moody. The translation follows the logic and behavior of the
// original code, but it is new code, not the original C code.
//
// Changes from the original: WFDB_DEFFREQ, WFDB_DEFGAIN and WFDB_DEFRES remain
// defined but are used only in legacy mode, and missing units are never taken
// to be millivolts; the functions whose behavior differs say so in their
// descriptions; it also declares the additions of WFDB-x: wfdbx_set_legacy,
// wfdbx_get_legacy, wfdbx_legacy_args, wfdbx_time_needs_freq, getvecs, the
// input and output directories and network access (wfdbx_set_input_dir,
// wfdbx_set_output_dir, wfdbx_set_network, ...), and the count of write
// errors (wfdbx_write_errors, wfdbx_note_write_error). Each change is marked
// "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C code: lib/wfdb.h, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2013 George B. Moody; revised 2010-2020 by
//   Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
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
//     // The sample record 100s (the first minute of record 100 of the
//     // MIT-BIH Arrhythmia Database), included with WFDB-x in the tests/data
//     // directory of a copy of the repository:
//     wfdbx_set_input_dir("tests/data");
//     WFDB_Siginfo si[2];
//     if (isigopen("100s", si, 2) == 2) {
//         WFDB_Sample v[2];
//         while (getvec(v) > 0) { /* v[0], v[1]: one sample per signal */ }
//     }
//     wfdbquit();

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
/// resolution (bits), kept for compatibility.  WFDB-x never assumes them:
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
// WFDB-x: files are found by explicit names (nothing is searched).  A file of
// a record is named "<record>.<type>" (e.g. "100s.hea", "100s.atr").  A
// relative name is read under the input directory (wfdbx_set_input_dir(); a
// local directory or a URL) and written under the output directory
// (wfdbx_set_output_dir()), by default the current directory; an absolute
// name, a "~" name or a URL is used as given.  The signal files and segments
// named in a header are in the directory of that header (or below it).  URLs
// are opened only with network access (wfdbx_set_network()).  Legacy mode:
// as the C library, records are searched for in the directories of the WFDB
// path (see setwfdb()), without network access.

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
///
/// Translation of the C function annopen() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results. Differences: the annotation files are found only
/// where they are named, not by a search of the WFDB path; see
/// docs/DIVERGENCES.md.
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
///
/// Translation of the C function isigopen() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: the signal files and segments named in
/// the header are read only from the header's directory, and no sampling
/// frequency, gain, ADC resolution or units are assumed; see
/// docs/DIVERGENCES.md.
int isigopen(const char *record, WFDB_Siginfo *siarray, int nsig);
/// Open `nsig` output signals as described by the header of `record` (an
/// existing record), filling `siarray` with their descriptions.  Previously
/// opened output signals are closed first, unless `record` begins with '+'.
/// Returns the number of signals opened, or a negative value on error (for
/// example -3 if the record has fewer than nsig signals or a signal file
/// cannot be created).
///
/// Translation of the C function osigopen() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: an output signal file that is one of
/// the input files of the open record is refused; see docs/DIVERGENCES.md.
int osigopen(const char *record, WFDB_Siginfo *siarray, unsigned nsig);
/// Open `nsig` output signals as described by `siarray` (fname, fmt, gain,
/// ...; signals of the same group must have the same fname, and group
/// numbers must increase by 1 with each new file).  Previously opened output
/// signals are closed.  Returns the number of signals opened, or a negative
/// value on error (-2 for an invalid specification, -3 if a file cannot be
/// created).
///
/// Translation of the C function osigfopen() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: an output signal file that is one of
/// the input files of the open record is refused; see docs/DIVERGENCES.md.
int osigfopen(const WFDB_Siginfo *siarray, unsigned nsig);
/// annopen() followed, if it succeeds, by isigopen(); returns the result of
/// the last call made (the number of input signals on success).
///
/// Translation of the C function wfdbinit() (lib/wfdbinit.c, WFDB 10.7.0):
/// same arguments and results. Differences: those of annopen() and isigopen();
/// see docs/DIVERGENCES.md.
int wfdbinit(const char *record, const WFDB_Anninfo *aiarray, unsigned nann,
             WFDB_Siginfo *siarray, unsigned nsig);
/// Close all open files (flushing buffered output and terminating output
/// annotation files), release the library's buffers and reset the state of
/// the open record; in legacy mode, the WFDB path is restored (see
/// resetwfdb(); WFDB-x: the input directory is left as it is).  Headers
/// are not written: call newheader() or setheader() first.  Call wfdbquit()
/// before exiting after writing files.
///
/// Translation of the C function wfdbquit() (lib/wfdbinit.c, WFDB 10.7.0):
/// same arguments and results. Differences: the input and output directories
/// are kept (the WFDB path is restored only in legacy mode); see
/// docs/DIVERGENCES.md.
void wfdbquit();
/// Write all buffered output signal and annotation data to their files.
///
/// Translation of the C function wfdbflush() (lib/wfdbinit.c, WFDB 10.7.0):
/// same arguments and results.
void wfdbflush();
/// @}

/// @name Reading and writing signals
/// @{

/// Number of the open input signal whose description is `signame`; a string
/// of digits is taken as a signal number if such a signal exists.  Returns
/// -1 if there is no such signal.
///
/// Translation of the C function findsig() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
int findsig(const char *signame);
/// The number of getvec() results per frame: the maximum samples per frame
/// of the open signals in WFDB_HIGHRES mode, 1 otherwise.
///
/// Translation of the C function getspf() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
int getspf();
/// Set the getvec mode: WFDB_LOWRES (oversampled signals are averaged to one
/// sample per frame) or WFDB_HIGHRES (every sample is returned, the other
/// signals being repeated), optionally or'ed with WFDB_GVPAD (invalid
/// samples are replaced by the previous valid sample).  A negative `mode`
/// restores the default (from the WFDBGVMODE environment variable, or
/// WFDB_LOWRES).
///
/// Translation of the C function setgvmode() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
void setgvmode(int mode);
/// The current getvec mode.
///
/// Translation of the C function getgvmode() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
int getgvmode();
/// Resample the input signals to `freq` (Hz) in getvec() (by linear
/// interpolation), after isigopen().  Returns 0, or -1 if no record is open,
/// its sampling frequency is not specified (WFDB-x), or freq <= 0.
///
/// Translation of the C function setifreq() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: it fails if the sampling frequency of
/// the input record is not specified; see docs/DIVERGENCES.md.
int setifreq(WFDB_Frequency freq);
/// The sampling frequency of the samples returned by getvec() (the one set
/// by setifreq(), or that of the open record).
///
/// Translation of the C function getifreq() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
WFDB_Frequency getifreq();
/// Read the next sample of each open input signal into `vector` (one entry
/// per signal).  Returns the number of input signals, -1 at the end of the
/// data, -3 on an unexpected end of file (or a decoding error), -4 on a
/// checksum error.
///
/// Translation of the C function getvec() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
int getvec(WFDB_Sample *vector);
/// Read the next frame into `vector`: spf samples of each input signal, in
/// signal order (sum of the signals' spf entries).  Return values as for
/// getvec().
///
/// Translation of the C function getframe() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
int getframe(WFDB_Sample *vector);
/// Write a frame to the open output signals: `vector` holds spf samples of
/// each signal, in signal order.  Returns the number of output signals, 0 if
/// a first difference was too large for format 8 (the difference is then
/// clipped), or -1 on a write error.
///
/// Translation of the C function putvec() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
int putvec(const WFDB_Sample *vector);
/// Skip to sample `t` of every input signal (negative values are taken as
/// their absolute value); returns 0 on success.
///
/// Translation of the C function isigsettime() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
int isigsettime(WFDB_Time t);
/// Skip to sample `t` of the input signals of group `g`; returns 0 on
/// success.
///
/// Translation of the C function isgsettime() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
int isgsettime(WFDB_Group g, WFDB_Time t);
/// Time of the next valid sample of input signal `s` at or after `t`; the
/// input signals are positioned at that time.  Returns a negative value if
/// there is none or on error.
///
/// Translation of the C function tnextvec() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
WFDB_Time tnextvec(WFDB_Signal s, WFDB_Time t);
/// Sample `t` of input signal `s` (random access through a buffer that is
/// filled with getvec(), so the position of the input signals changes).
/// Returns WFDB_INVALID_SAMPLE if the sample is not available; see
/// sample_valid().
///
/// Translation of the C function sample() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
WFDB_Sample sample(WFDB_Signal s, WFDB_Time t);
/// Status of the value last returned by sample(): 1 if it is valid, -1 if it
/// is WFDB_INVALID_SAMPLE, 0 if it is beyond the end of the record.
///
/// Translation of the C function sample_valid() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
int sample_valid();
/// @}

/// @name Reading and writing annotations
/// @{

/// Read the next annotation of input annotator `a` into `annot`.  Returns 0,
/// -1 at the end of the file, -2 if `a` is not open, -3 on an unexpected end
/// of file.
///
/// Translation of the C function getann() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
int getann(WFDB_Annotator a, WFDB_Annotation *annot);
/// Push back `annot`, to be returned by the next getann(a, ...).  Returns 0,
/// -1 if an annotation is already pushed back, -2 if `a` is not open.
///
/// Translation of the C function ungetann() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
int ungetann(WFDB_Annotator a, const WFDB_Annotation *annot);
/// Write `annot` to output annotator `a`.  Annotations should be written in
/// time order; otherwise the file is sorted when it is closed (see
/// oannclose()).  Returns 0, -1 on a write error, -2 if `a` is not open.
///
/// Translation of the C function putann() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
int putann(WFDB_Annotator a, const WFDB_Annotation *annot);
/// Skip every input annotator to its first annotation at or after time `t`
/// (negative values are taken as their absolute value).  Returns 0, or -1
/// if no annotator could be positioned.
///
/// Translation of the C function iannsettime() (lib/annot.c, WFDB 10.7.0):
/// same arguments and results.
int iannsettime(WFDB_Time t);
/// Close input annotator `a`; the following input annotators are
/// renumbered.
///
/// Translation of the C function iannclose() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
void iannclose(WFDB_Annotator a);
/// Close output annotator `a`; the following output annotators are
/// renumbered.  If annotations were written out of order, the file is
/// sorted (unless the WFDBANNSORT environment variable is 0), with the result
/// of `sortann -r. RECORD -a ANNOTATOR`.  WFDB-x: the file is sorted in this
/// process; the C library (and legacy mode) runs the sortann program.
///
/// Translation of the C function oannclose() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results. Differences: an out-of-order file is sorted in this
/// process, without losing annotations, instead of by running sortann; see
/// docs/DIVERGENCES.md.
void oannclose(WFDB_Annotator a);
/// Set the time resolution (ticks per second) recorded in output annotation
/// files (0: none, the sampling frequency of the record applies).  It is
/// used by the files to which no annotation has been written yet.
///
/// Translation of the C function setafreq() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
void setafreq(WFDB_Frequency f);
/// The time resolution set by setafreq().
///
/// Translation of the C function getafreq() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
WFDB_Frequency getafreq();
/// Set the time resolution (ticks per second) of the times returned by
/// getann() for input annotator `a`.
///
/// Translation of the C function setiafreq() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
void setiafreq(WFDB_Annotator a, WFDB_Frequency f);
/// The time resolution of the times returned for input annotator `a`, or -2
/// if `a` is not open.
///
/// Translation of the C function getiafreq() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
WFDB_Frequency getiafreq(WFDB_Annotator a);
/// The time resolution recorded in the file of input annotator `a` (0 if
/// none), or -2 if `a` is not open.
///
/// Translation of the C function getiaorigfreq() (lib/annot.c, WFDB 10.7.0):
/// same arguments and results.
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
///
/// Translations of the C functions of the same names (lib/annot.c, WFDB
/// 10.7.0): same arguments and results.
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
/// that set by setifreq()).  WFDB-x: if no sampling frequency is specified
/// (C assumed 1 sample per second), timstr() and mstimstr() report an error
/// and return the time as a sample number ("s" followed by |t|), and strtim()
/// reports an error and returns 0 for strings that need the frequency (see
/// wfdbx_time_needs_freq() and docs/DIVERGENCES.md).
/// @{

/// Time `t` as a string: an elapsed time ("0:10", "1:02:03", right-aligned
/// with leading spaces) if t > 0 or if the base time of the record is
/// unknown; otherwise the time of day of sample -t, "[hh:mm:ss dd/mm/yyyy]"
/// (the date only if known).
///
/// Translation of the C function timstr() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: if the sampling frequency is not
/// specified, it reports an error and returns the time as a sample number (the
/// original assumed 1 sample per second); see docs/DIVERGENCES.md.
std::string timstr(WFDB_Time t);
/// As timstr(), with milliseconds ("0:10.000", "[12:34:56.789 31/12/1999]").
///
/// Translation of the C function mstimstr() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: if the sampling frequency is not
/// specified, it reports an error and returns the time as a sample number (the
/// original assumed 1 sample per second); see docs/DIVERGENCES.md.
std::string mstimstr(WFDB_Time t);
/// The sample number given by a time string: an elapsed time ("1:30",
/// "90.5"), a sample number ("s1000"), a time of day ("[12:00:00]",
/// "[12:00:00 01/01/2020]"), or "e" (the end of the record).  Times of day
/// are returned as negative values (-sample number).
///
/// Translation of the C function strtim() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: if the string needs a sampling
/// frequency and none is specified, it reports an error and returns 0 (the
/// original assumed 1 sample per second); see docs/DIVERGENCES.md.
WFDB_Time strtim(const char *time_string);
/// 1 if strtim() needs a sampling frequency to convert
/// `time_string`, 0 if it does not: strings starting (after leading spaces,
/// tabs, newlines and CRs) with 'e', 'i', 'o' or 's', or with 'c' if the
/// counter frequency is <= 0.
///
/// Part of WFDB-x; not in the original WFDB package.
int wfdbx_time_needs_freq(const char *time_string);
/// Turn legacy mode on (`on` nonzero) or off (`on` 0) for the whole
/// library.  Returns the previous setting (1: on, 0: off).  In legacy mode,
/// the library behaves exactly as the original WFDB package, including its
/// assumed signal parameters and its search for files (see
/// docs/DIVERGENCES.md).  Use it only to reproduce old results.  Default:
/// off.
///
///     wfdbx_set_legacy(1);
///
/// Part of WFDB-x; not in the original WFDB package.
int wfdbx_set_legacy(int on);
/// 1 if legacy mode is on, 0 otherwise.
///
/// Part of WFDB-x; not in the original WFDB package.
int wfdbx_get_legacy();
/// If the first argument of a tool (argv[1]) is exactly "--legacy", remove
/// it (argv[0] is kept, argc is decremented), turn legacy mode on and return
/// 1; otherwise change nothing and return 0.
///
/// It also sets the exit status of the program, as for the tools: at exit,
/// in normal mode, the standard output is flushed, a failure to write it is
/// reported ("PROGRAM: write error on standard output", PROGRAM being the
/// last component of argv[0]), and an exit status of 0 becomes 1 if the
/// standard output or another output file could not be written (see
/// wfdbx_write_errors()).  Legacy mode keeps the exit status.
///
/// Part of WFDB-x; not in the original WFDB package.
int wfdbx_legacy_args(int &argc, char **&argv);
/// The number of write errors since the program started: the output files
/// (signal files, headers, annotation files, info and calibration files, and
/// the standard output opened as "-") that the library could not write,
/// flush or close (found when they are closed, as by wfdbquit()), and the
/// errors reported with wfdbx_note_write_error().  The high-level writers
/// throw an error when they meet one, and the tools then exit with status 1.
///
/// Part of WFDB-x; not in the original WFDB package.
int wfdbx_write_errors();
/// Count a write error (see wfdbx_write_errors()): for an application that
/// writes a file itself.
///
/// Part of WFDB-x; not in the original WFDB package.
void wfdbx_note_write_error();
/// Set the output directory: a file named by a relative name, such as
/// "100.qrs" or "out/100.qrs", is created in `dir`.  Full paths and "~"
/// paths are used as given, and URLs cannot be written.  The names recorded
/// in headers do not change.  Missing directories are created.  nullptr or
/// "" restores the default: the environment variable WFDBX_OUTPUT_DIR if it
/// is set, otherwise the current directory.
///
/// Returns the previous value (std::nullopt if none).  A URL is refused with
/// the error "wfdbx_set_output_dir: the output directory must be a local
/// directory"; the setting is then unchanged, and its current value is
/// returned.  wfdbquit() does not change the setting.
///
///     wfdbx_set_output_dir("out");
///
/// Part of WFDB-x; not in the original WFDB package.
std::optional<std::string> wfdbx_set_output_dir(const char *dir);
/// The output directory (std::nullopt if none is set).
///
/// Part of WFDB-x; not in the original WFDB package.
std::optional<std::string> wfdbx_get_output_dir();
/// Set the input directory: a file named by a relative name, such as "100"
/// or "mitdb/100", is read from `dir`.  Full paths, "~" paths and URLs are
/// used as given.  `dir` may be a local directory, a "~" path or the URL of a
/// directory, such as "https://physionet.org/files/mitdb/1.0.0/" (the
/// MIT-BIH Arrhythmia Database at PhysioNet, which
/// needs network access, see wfdbx_set_network()).  nullptr or "" restores
/// the default: the environment variable WFDBX_INPUT_DIR if it is set,
/// otherwise the current directory.  Returns the previous value
/// (std::nullopt if none).  wfdbquit() does not change the setting.
///
///     wfdbx_set_input_dir("/data/mitdb");  // a local copy of the MIT-BIH
///                                          // Arrhythmia Database
///
/// Part of WFDB-x; not in the original WFDB package.
std::optional<std::string> wfdbx_set_input_dir(const char *dir);
/// The input directory (std::nullopt if none is set).
///
/// Part of WFDB-x; not in the original WFDB package.
std::optional<std::string> wfdbx_get_input_dir();
/// Allow (`on` > 0) or forbid (`on` 0) network access, that is, reading
/// http:// and https:// URLs.  A negative value restores the default:
/// allowed if the environment variable WFDBX_NETWORK is a nonzero number,
/// otherwise forbidden.  Returns the previous setting (1 or 0).
///
/// URLs are read with the curl program, which must be installed.  Each URL
/// is read at most once while the program runs.  A download gives up when
/// it cannot connect, or receives nothing, for 30 seconds.  With network
/// access forbidden, opening a URL fails with the error "WFDB-x: network
/// access is disabled; ...".
///
///     wfdbx_set_network(1);
///
/// Part of WFDB-x; not in the original WFDB package.
int wfdbx_set_network(int on);
/// 1 if network access is allowed, 0 otherwise.
///
/// Part of WFDB-x; not in the original WFDB package.
int wfdbx_get_network();
/// Julian date `d` as " dd/mm/yyyy" (with a leading space).
///
/// Translation of the C function datstr() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
std::string datstr(WFDB_Date d);
/// Julian date of a "dd/mm/yyyy" string, or 0 if it is invalid.
///
/// Translation of the C function strdat() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
WFDB_Date strdat(const char *date_string);
/// @}

/// @name Amplitude conversion (input signal `s`)
/// The gain and baseline of the open input signal `s` are used.  WFDB-x: if
/// `s` is not open or is uncalibrated (gain 0), these functions report an
/// error and return WFDB_INVALID_SAMPLE (aduphys(): NaN); C assumed the
/// gain WFDB_DEFGAIN (see docs/DIVERGENCES.md).
/// @{

/// ADC units to microvolts (rounded).
///
/// Translation of the C function adumuv() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: an uncalibrated signal or an invalid
/// signal number is an error (the original assumed a gain of 200); see
/// docs/DIVERGENCES.md.
int adumuv(WFDB_Signal s, WFDB_Sample a);
/// Microvolts to ADC units (rounded).
///
/// Translation of the C function muvadu() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: an uncalibrated signal or an invalid
/// signal number is an error (the original assumed a gain of 200); see
/// docs/DIVERGENCES.md.
WFDB_Sample muvadu(WFDB_Signal s, int microvolts);
/// ADC units to physical units: (a - baseline) / gain.
///
/// Translation of the C function aduphys() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: an uncalibrated signal or an invalid
/// signal number is an error (the original assumed a gain of 200); see
/// docs/DIVERGENCES.md.
double aduphys(WFDB_Signal s, WFDB_Sample a);
/// Physical units to ADC units: round(v * gain) + baseline.
///
/// Translation of the C function physadu() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: an uncalibrated signal or an invalid
/// signal number is an error (the original assumed a gain of 200); see
/// docs/DIVERGENCES.md.
WFDB_Sample physadu(WFDB_Signal s, double v);
/// @}

/// @name Calibration
/// @{

/// Read a calibration file (nullptr: the file named by $WFDBCAL, or
/// "wfdbcal"), searched for in the WFDB path.  The calibration list is
/// emptied first, unless the name begins with '+'.  Returns 0, or -2 if the
/// file cannot be read.
///
/// Translation of the C function calopen() (lib/calib.c, WFDB 10.7.0): same
/// arguments and results. Differences: the calibration file is found only
/// where it is named, not by a search of the WFDB path; see
/// docs/DIVERGENCES.md.
int calopen(const char *calibration_filename);
/// Copy to `cal` the first calibration list entry whose signal type is a
/// prefix of `description` and whose units are `units` (nullptr matches
/// anything).  Returns 0 if found, -1 otherwise.
///
/// Translation of the C function getcal() (lib/calib.c, WFDB 10.7.0): same
/// arguments and results.
int getcal(const char *description, const char *units, WFDB_Calinfo *cal);
/// Append a copy of `cal` to the calibration list; returns 0.
///
/// Translation of the C function putcal() (lib/calib.c, WFDB 10.7.0): same
/// arguments and results.
int putcal(const WFDB_Calinfo *cal);
/// Write the calibration list to a new file; returns 0, or -1 on error.
///
/// Translation of the C function newcal() (lib/calib.c, WFDB 10.7.0): same
/// arguments and results.
int newcal(const char *calibration_filename);
/// Empty the calibration list.
///
/// Translation of the C function flushcal() (lib/calib.c, WFDB 10.7.0): same
/// arguments and results.
void flushcal();
/// @}

/// @name Info strings
/// Info strings are the comment lines ("#...") that follow the signal
/// specifications in a header, and the lines of the record's ".info" file.
/// @{

/// If `record` is not nullptr, read the info strings of `record` and return
/// the first; otherwise return the next one (reading those of the open
/// record on the first call).  Returns nullopt when there are no more.
///
/// Translation of the C function getinfo() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
std::optional<std::string> getinfo(const char *record);
/// Append `info` as an info string to the info file opened by setinfo(),
/// or otherwise to the header last written; returns 0, or -1 if there is
/// neither.
///
/// Translation of the C function putinfo() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
int putinfo(const char *info);
/// Open the info file "<record>.info" for appending (nullptr: close it);
/// returns 0 on success.
///
/// Translation of the C function setinfo() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
int setinfo(const char *record);
/// Release the info strings read by getinfo().
///
/// Translation of the C function wfdb_freeinfo() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
void wfdb_freeinfo();
/// @}

/// @name Header files
/// @{

/// Write the header of `record` for the open output signals (after the
/// samples have been written with putvec()).  Returns 0, or -1 on error.
///
/// Translation of the C function newheader() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: a header written under a path names the
/// record and its signal files relative to its own directory, and only the
/// record's own name (the last component) is checked; see docs/DIVERGENCES.md.
int newheader(const char *record);
/// Write the header of `record` for the `nsig` signals described by
/// `siarray`.  Returns 0, or -1 on error.
///
/// Translation of the C function setheader() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: a header written under a path names the
/// record and its signal files relative to its own directory, and only the
/// record's own name (the last component) is checked; see docs/DIVERGENCES.md.
int setheader(const char *record, WFDB_Siginfo *siarray, unsigned nsig);
/// Write the header of a multi-segment record made of the `nsegments`
/// records named in `segnames` (which must exist and have the same number
/// of signals and sampling frequency).  Returns 0, or a negative value on
/// error.
///
/// Translation of the C function setmsheader() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results. Differences: a header written under a path
/// names the record and its segments relative to its own directory, and only
/// the record's own name (the last component) is checked; see
/// docs/DIVERGENCES.md.
int setmsheader(const char *record, const char *const *segnames,
                unsigned nsegments);
/// Point `*segments` at the segment table of the open multi-segment record
/// (nullptr if there is none; the table belongs to the library and is valid
/// until the record is closed).  Returns the number of segments (0 if the
/// record is not multi-segment).
///
/// Translation of the C function getseginfo() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
int getseginfo(const WFDB_Seginfo **segments);
/// Skew (in frames) of input signal `s` (0 if `s` is not open).
///
/// Translation of the C function wfdbgetskew() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
int wfdbgetskew(WFDB_Signal s);
/// Change the skew of input signal `s` (to restore a skew reset as a side
/// effect of another call).
///
/// Translation of the C function wfdbsetiskew() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
void wfdbsetiskew(WFDB_Signal s, int skew);
/// Set the skew of output signal `s` to be written by setheader()/newheader().
///
/// Translation of the C function wfdbsetskew() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
void wfdbsetskew(WFDB_Signal s, int skew);
/// Length of the prolog (the byte offset of sample 0) of the signal file of
/// input signal `s`.
///
/// Translation of the C function wfdbgetstart() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
long wfdbgetstart(WFDB_Signal s);
/// Set the prolog length of output signal `s` to be written by
/// setheader()/newheader().
///
/// Translation of the C function wfdbsetstart() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
void wfdbsetstart(WFDB_Signal s, long bytes);
/// Write `bytes` bytes of `prolog` at the current position (normally the
/// start) of the file of output signal `s`, and record that length as with
/// wfdbsetstart().  Returns 0, or -1 if not all bytes were written.
///
/// Translation of the C function wfdbputprolog() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
int wfdbputprolog(const char *prolog, long bytes, WFDB_Signal s);
/// @}

/// @name Frequencies and base time
/// @{

/// Sampling frequency (Hz) of `record`, read from its header, or of the open
/// record if `record` is nullptr.  Returns a negative value if the header
/// cannot be read, and 0 if it does not specify the frequency (WFDB-x; C
/// assumed WFDB_DEFFREQ).
///
/// Translation of the C function sampfreq() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results. Differences: it returns 0, not 250, if the header
/// gives no sampling frequency; see docs/DIVERGENCES.md.
WFDB_Frequency sampfreq(const char *record);
/// Set the sampling frequency (Hz) used for time conversions and written to
/// new headers; returns 0, or -1 if it is negative.
///
/// Translation of the C function setsampfreq() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
int setsampfreq(WFDB_Frequency sampling_frequency);
/// The counter frequency (that of the record's counter, or the sampling
/// frequency if it has none).
///
/// Translation of the C function getcfreq() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
WFDB_Frequency getcfreq();
/// Set the counter frequency (0: none) written to new headers.
///
/// Translation of the C function setcfreq() (lib/signal.c, WFDB 10.7.0): same
/// arguments and results.
void setcfreq(WFDB_Frequency counter_frequency);
/// The counter value of sample 0.
///
/// Translation of the C function getbasecount() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
double getbasecount();
/// Set the counter value of sample 0 written to new headers.
///
/// Translation of the C function setbasecount() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
void setbasecount(double count);
/// Set the base time (and date) of the record: "hh:mm:ss dd/mm/yyyy", or
/// the current time if nullptr or empty.  Returns 0, or -1 if the string is
/// invalid.
///
/// Translation of the C function setbasetime() (lib/signal.c, WFDB 10.7.0):
/// same arguments and results.
int setbasetime(const char *time_string);
/// @}

/// @name Error handling, WFDB path, miscellaneous
/// @{

/// Stop printing error messages on stderr.
///
/// Translation of the C function wfdbquiet() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results.
void wfdbquiet();
/// Resume printing error messages (the default).
///
/// Translation of the C function wfdbverbose() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results.
void wfdbverbose();
/// The last error message (or, if there was none, the library version).
///
/// Translation of the C function wfdberror() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results.
std::string wfdberror();
/// Report an error (printf-style): the message is saved for wfdberror() and
/// printed on stderr unless wfdbquiet() is in effect.
///
/// Translation of the C function wfdb_error() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results.
void wfdb_error(const char *format, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 1, 2)))
#endif
    ;
/// The value set by wfdbmemerr() (1 by default).  Provided for
/// compatibility; it has no other effect.
///
/// Translation of the C functions wfdb_me_fatal() and wfdbmemerr()
/// (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
int wfdb_me_fatal();
void wfdbmemerr(int exit_on_error);
/// WFDB-x: in normal mode, set the input directory (see
/// wfdbx_set_input_dir()): `database_path`, split into components as the
/// WFDB path is (at spaces, ';', and ':' outside URLs), must have at most one
/// non-empty component, which becomes the input directory (none, as in ""
/// or ";": the default); with more, an error is reported ("setwfdb: WFDB-x
/// reads from a single input directory; ...") and nothing changes.
/// Legacy mode: as in C, set the WFDB path, the list of directories where
/// input files are searched for ("@file" reads the path from a file);
/// nullptr: $WFDB, or the default; the value is also exported as the WFDB
/// environment variable; remote components are not used.
///
/// Translation of the C function setwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results. Differences: it sets a single input directory (the
/// WFDB path in legacy mode); see docs/DIVERGENCES.md.
void setwfdb(const char *database_path);
/// WFDB-x: in normal mode, the input directory, or "." if none is set.
/// Legacy mode: the current WFDB path.
///
/// Translation of the C function getwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results. Differences: it returns the input directory (the
/// WFDB path in legacy mode); see docs/DIVERGENCES.md.
std::string getwfdb();
/// WFDB-x: in normal mode, restore the input directory set by the last
/// setwfdb(), if any.  Legacy mode: restore the initial WFDB path (from $WFDB
/// or the default), if the path had been read before it was changed by
/// setwfdb().
///
/// Translation of the C function resetwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results. Differences: it restores the input directory set by
/// the last setwfdb() (the WFDB path in legacy mode); see docs/DIVERGENCES.md.
void resetwfdb();
/// Set the input or output buffer size (bytes) of signal files opened
/// afterwards (0: the default).  Returns the new size, -1 if signals are
/// already open, -2 if the size is negative.
///
/// Translation of the C functions setibsize() and setobsize() (lib/signal.c,
/// WFDB 10.7.0): same arguments and results.
int setibsize(int input_buffer_size);
int setobsize(int output_buffer_size);
/// The path name (or URL) of the file of `record` with type (suffix)
/// `file_type`, or nullopt if it cannot be opened.  WFDB-x: the file is at
/// the one location its name designates (see "Opening and closing records");
/// legacy mode: as found in the WFDB path.
///
/// Translation of the C function wfdbfile() (lib/wfdbio.c, WFDB 10.7.0): same
/// arguments and results. Differences: the file is found as wfdb_open() finds
/// it, not by a search of the WFDB path; see docs/DIVERGENCES.md.
std::optional<std::string> wfdbfile(const char *file_type, const char *record);
/// Library version ("10.7.0").
///
/// Translation of the C function wfdbversion() (lib/wfdbio.c, WFDB 10.7.0):
/// same arguments and results.
std::string wfdbversion();
/// Build flags of the C library (empty strings here).
///
/// Translation of the C functions wfdbldflags() and wfdbcflags()
/// (lib/wfdbio.c, WFDB 10.7.0): same arguments and results. Differences:
/// the result is always empty; see docs/KNOWN_C_BEHAVIORS.md.
std::string wfdbldflags();
std::string wfdbcflags();
/// The default WFDB path, and the default calibration file name.
///
/// Translation of the C functions wfdbdefwfdb() and wfdbdefwfdbcal()
/// (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
std::string wfdbdefwfdb();
std::string wfdbdefwfdbcal();
/// @}

/// @name Additions (not in the C library)
/// @{

/// Read up to `n` getvec() results into `out`, with exactly the semantics
/// of n calls of getvec() but faster.  `out` must have room for n times the
/// number of values returned by getvec().  Returns the number read (>= 0),
/// or the negative value returned by getvec() if none could be read.  If
/// `status` is not null, it receives the value returned by the last getvec()
/// call: the negative status of the first frame that could not be read
/// (-1 at the end of the data, < -1 on an error, e.g. -3 for an unexpected
/// end of file), or the number of values per frame if all n were read.
///
/// Part of WFDB-x; not in the original WFDB package.
long long getvecs(WFDB_Sample *out, long long n, int *status = nullptr);
/// @}

} // namespace wfdbx

#endif // WFDBX_WFDB_HPP
