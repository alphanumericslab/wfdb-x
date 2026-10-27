// wfdblib.hpp: internal definitions of the wfdb-x C++ library (not installed).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of lib/wfdblib.h from the WFDB Software Package
// 10.7.0, by George B. Moody, with revisions by Benjamin Moody. The
// translation follows the logic and behavior of the original code, but it is
// new code, not the original C code.
//
// Changes from the original: it also declares wfdb-x's internal functions (the
// location of files by name, the remote file reader, the in-process sorting of
// annotation files, and what the high-level functions and check_record use);
// the stream functions read and write without locking the stream. Each change
// is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C code: lib/wfdblib.h, WFDB Software Package 10.7.0.
//   Copyright (C) 1989-2012 George B. Moody; revised 2017-2022 by Benjamin
//   Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

#ifndef WFDBX_WFDBLIB_HPP
#define WFDBX_WFDBLIB_HPP

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "wfdbx/wfdb.hpp"
#include "wfdbx/ecgcodes.hpp"

#if defined(_WIN32)
#define WFDBX_GETC(f) _getc_nolock(f)
#define WFDBX_PUTC(c, f) _putc_nolock(c, f)
#else
#define WFDBX_GETC(f) getc_unlocked(f)
#define WFDBX_PUTC(c, f) putc_unlocked(c, f)
#endif

// wfdb-x: ferror and feof without locking the stream (putvec tests the
// error indicator after every sample, getann the end-of-file indicator after
// every annotation word).  ferror_unlocked and feof_unlocked are found by the
// build (CMakeLists.txt: WFDBX_HAVE_FERROR_UNLOCKED, WFDBX_HAVE_FEOF_UNLOCKED;
// glibc, macOS and the BSDs have them); elsewhere (e.g. Windows, whose C
// library has no documented lock-free equivalent) ferror and feof are used.
#if defined(WFDBX_HAVE_FERROR_UNLOCKED)
#define WFDBX_FERROR(f) ferror_unlocked(f)
#else
#define WFDBX_FERROR(f) std::ferror(f)
#endif
#if defined(WFDBX_HAVE_FEOF_UNLOCKED)
#define WFDBX_FEOF(f) feof_unlocked(f)
#else
#define WFDBX_FEOF(f) std::feof(f)
#endif

namespace wfdbx {

// Default WFDB path and calibration file
extern const char *const DEFWFDB;
constexpr const char *DEFWFDBCAL = "wfdbcal";
constexpr int DEFWFDBANNSORT = 1;
constexpr int DEFWFDBGVMODE = WFDB_LOWRES;

// Path component types
constexpr int WFDB_LOCAL = 0;   // a local file
constexpr int WFDB_NET = 1;     // a remote file read via libwww (not used by wfdb-x)
constexpr int WFDB_FETCHED = 2; // wfdb-x: a remote file, fetched in full and
                                // read from a temporary copy (see wfdbio.cpp)

namespace detail {

// printf into a std::string
std::string vstrprintf(const char *format, va_list ap);
std::string strprintf(const char *format, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 1, 2)))
#endif
    ;

// ---------------------------------------------------------------------------
// WFDB_FILE: an open file (C standard I/O stream).  The member functions
// correspond to the wfdb_* stdio wrappers of the C library.

class WFDBFile {
public:
    WFDBFile(std::FILE *fp, bool is_std, int type = WFDB_LOCAL)
        : fp_(fp), is_std_(is_std), type_(type) {}
    WFDBFile(const WFDBFile &) = delete;
    WFDBFile &operator=(const WFDBFile &) = delete;
    ~WFDBFile() { close(); }

    std::FILE *fp() const { return fp_; }
    bool is_std() const { return is_std_; }
    int type() const { return type_; }

    int getc() { return WFDBX_GETC(fp_); }
    int putc(int c) { return WFDBX_PUTC(c, fp_); }
    size_t read(void *p, size_t size, size_t n)
        { return std::fread(p, size, n, fp_); }
    size_t write(const void *p, size_t size, size_t n)
        { return std::fwrite(p, size, n, fp_); }
    int printf(const char *format, ...)
#if defined(__GNUC__)
        __attribute__((format(printf, 2, 3)))
#endif
        ;
    int seek(long offset, int whence);
    long tell();
    int flush() { return std::fflush(fp_); }
    int eof() { return WFDBX_FEOF(fp_); }
    int error() { return WFDBX_FERROR(fp_); }
    void clearerr() { std::clearerr(fp_); }
    // wfdb-x: the number of bytes between the current position and the end
    // of the file, if the file is a regular file (-1 otherwise, or if it
    // cannot be determined).  Used by the bulk reader of getvecs.
    long long bytes_left();
    // Close the file (standard streams are flushed, not closed).
    int close();
    // Read a line, including its newline if any, into `line`.  Returns the
    // number of characters read (0 at end of file).
    size_t getline(std::string &line);
    // fgets: read at most size-1 characters (up to a newline) into s.
    char *fgets(char *s, int size);

    // Binary helpers (wfdb_g16, wfdb_g32, wfdb_p16, wfdb_p32): 16-bit and
    // 32-bit integers in PDP-11 byte order.
    int g16() {
        int x = getc();
        return static_cast<int>(static_cast<short>((getc() << 8) | (x & 0xff)));
    }
    long g32() {
        long x = g16(), y = g16();
        return (x << 16) | (y & 0xffff);
    }
    void p16(unsigned int x) {
        putc(static_cast<char>(x));
        putc(static_cast<char>(x >> 8));
    }
    void p32(long x) {
        p16(static_cast<unsigned>(x >> 16));
        p16(static_cast<unsigned>(x));
    }

private:
    std::FILE *fp_;
    bool is_std_;
    int type_;
};

using FilePtr = std::unique_ptr<WFDBFile>;

// wfdbio.cpp
// Turn the printing of library messages on or off (as wfdbverbose() and
// wfdbquiet() do); returns the previous setting.
bool wfdb_set_error_print(bool on);
FilePtr wfdb_open(const char *file_type, const char *record, int mode);
FilePtr wfdb_fopen(const char *fname, const char *mode);
int wfdb_checkname(const char *name, const char *description);
std::string wfdb_striphea(const char *record);
void wfdb_setirec(const char *record_name);
std::optional<std::string> wfdb_getirec();
int wfdb_parse_path(const char *wfdb_path);
void wfdb_addtopath(const char *pathname);
// Name of the file most recently opened by wfdb_open
const std::string &wfdb_filename();
// wfdb-x: open, for reading, a file named in the header of record `record` (a
// signal file, or a segment of a multi-segment record, of type `type`):
// `name`, in the directory `dir` of that header (as wfdbx_dirname() returns
// it; nullopt if unknown, for a header read from the standard input: `name`
// is then resolved as any relative name).  `name` must be in that directory
// or below it (otherwise an error is reported); the signal file name "-"
// (the standard input) is also accepted.
FilePtr wfdbx_open_in(const std::optional<std::string> &dir, const char *type,
                      const char *name, const char *record);
// wfdb-x: the file that wfdb_open(name, nullptr, WFDB_WRITE) creates in
// normal mode (under the output directory, if one is set); nullopt for "",
// "-" (the standard output) or a URL.
std::optional<std::string> wfdbx_output_file(const char *name);
// wfdb-x: true if a file name found in a header names a file in the header's
// directory or below it (see wfdbx_open_in).
bool wfdbx_in_header_dir(const std::string &name);
// wfdb-x: the directory part of a file name or URL, including its final
// separator ("" if it has none).
std::string wfdbx_dirname(const std::string &path);
// wfdb-x: an argument of a command line, quoted as the MS-Windows C runtime
// parses it (_spawnvp joins its arguments with spaces, without quoting them).
std::string wfdbx_quote_arg(const std::string &a);
// wfdb-x: the command line that fetches `url` with curl (program name first,
// the URL last), the URL quoted with wfdbx_quote_arg if `quote` (as on
// MS-Windows).
std::vector<std::string> wfdbx_curl_args(const std::string &url, bool quote);

// signal.cpp
void wfdb_sampquit();
// wfdb-x: while on, getvec's message for a checksum error is recorded (see
// wfdberror) but not printed (used by the high-level read_record, which
// reports a checksum error itself).  Returns the previous setting.
bool wfdbx_set_checksum_quiet(bool on);
// wfdb-x: the bulk reader of getvecs (on by default); off, getvecs reads
// frame by frame (for the unit tests, which compare the two).  Returns the
// previous setting.
bool wfdbx_set_bulk_read(bool on);
// wfdb-x: the number of samples per signal given by the header of the
// record opened last (that of the whole record for a multi-segment record;
// 0 if not given), its base time (btime, in milliseconds after midnight) and
// its base date (bdate, a Julian date; 0 if none), for the high-level
// readers.
void wfdbx_header_values(WFDB_Time *nsamp, long *btime, WFDB_Date *bdate);
// wfdb-x: the year, month and day of a Julian date, computed as datstr()
// does.
void wfdbx_julian_ymd(WFDB_Date date, int *y, int *m, int *d);
// wfdb-x: for check_record.  The number of samples per signal of the header
// read last (master: that of the multi-segment record, msnsamples; otherwise
// that of the header read last, nsamples; 0 if not given).
WFDB_Time wfdbx_header_nsamples(bool master);
// wfdb-x: for check_record: true if the open input record is an EDF file;
// the number of open input signal groups; the checksum accumulator of input
// signal s (the header's checksum less the samples read so far); the size
// of the local file of input group g (-1 if it is not a local file).
bool wfdbx_input_is_edf();
unsigned wfdbx_input_groups();
int wfdbx_input_cksum(unsigned s);
long long wfdbx_input_file_size(unsigned g);
void wfdb_sigclose();
void wfdb_osflush();
int wfdb_oinfoclose();

// annot.cpp
// wfdb-x: whether oannclose sorts an out-of-order output annotation file:
// -1 (the default): as WFDBANNSORT says; 0: not sorted; 1: sorted (for the
// `sort` option of the high-level write_annotations).  Returns the previous
// setting.
int wfdbx_set_annsort(int mode);
// wfdb-x: a copy of the annotation mnemonics and descriptions (and the flags
// of the modified types), and their restoration from such a copy (for
// check_record: annopen reads an annotation file's definitions into them).
std::shared_ptr<void> wfdbx_save_anndefs();
void wfdbx_restore_anndefs(const std::shared_ptr<void> &saved);
void wfdb_anclose();
void wfdb_oaflush();

// wfdb-x: the list of annotations built by the sortann program (insert_ann
// in app/sortann.c), used by the sortann tool and by the in-process sorting
// of oannclose.  Annotations are kept in the canonical order (time, then
// num, then chan); one with the same time, num and chan as an annotation
// already in the list replaces it.  The list reproduces the C algorithm (a
// stable insertion, searching backwards from the end), except for its loss
// of annotations: C also compared the list head (time, num and chan 0) with
// the new annotation, so that an out-of-order annotation with time, num and
// chan 0 "replaced" the head and was detached from the list, with any
// annotation later inserted after it.  wfdb-x: the head is not compared (such
// an annotation is inserted at the beginning); with `legacy`, it is, as in C
// (the sortann tool in legacy mode).
class AnnSortList {
public:
    explicit AnnSortList(bool legacy = false) : list_(1), legacy_(legacy) {}
    // Insert a copy of annotation a.
    void insert(const WFDB_Annotation &a);
    // False if an annotation was inserted out of order.
    bool in_order() const { return in_order_; }
    // Call f(annotation) for each annotation of the list, in order.
    template <class F> void for_each(F &&f) const {
        for (long p = list_[0].next; p != -1; p = list_[p].next)
            f(list_[p].annotation);
    }

private:
    // Entry 0 is the list head, whose annotation is all zeros and which
    // takes part in comparisons as in sortann.c; -1 is a null link.
    struct Entry {
        long next = -1, prev = -1;
        WFDB_Annotation annotation;
    };
    std::vector<Entry> list_;
    long last_ = 0;
    bool in_order_ = true;
    bool legacy_;
};

// Run the sortann program to sort an annotation file (used by oannclose in
// legacy mode), as "sortann --legacy -r. RECORD -a ANNOTATOR", without a
// shell, in the directory `workdir` if given (else the current one).  The
// program is looked for in the directory of the running executable, then in
// the PATH.  Returns its exit status (-1 if it could not be run).
int run_sortann(const std::string &record, const std::string &annotator,
                const std::optional<std::string> &workdir);

} // namespace detail
} // namespace wfdbx

#endif // WFDBX_WFDBLIB_HPP
