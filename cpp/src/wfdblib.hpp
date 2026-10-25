// wfdblib.hpp: internal definitions of the wfdb-x C++ library
// (C++ version of lib/wfdblib.h; not installed)
//
// Copyright (C) 1989-2012 George B. Moody (original C header, lib/wfdblib.h;
// revised 2017-2022 by Benjamin Moody).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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

namespace wfdbx {

// Default WFDB path and calibration file
extern const char *const DEFWFDB;
constexpr const char *DEFWFDBCAL = "wfdbcal";
constexpr int DEFWFDBANNSORT = 1;
constexpr int DEFWFDBGVMODE = WFDB_LOWRES;

// Path component types
constexpr int WFDB_LOCAL = 0;   // a local file
constexpr int WFDB_NET = 1;     // a remote file (not supported by the wfdb-x C++ library)

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
    WFDBFile(std::FILE *fp, bool is_std) : fp_(fp), is_std_(is_std) {}
    WFDBFile(const WFDBFile &) = delete;
    WFDBFile &operator=(const WFDBFile &) = delete;
    ~WFDBFile() { close(); }

    std::FILE *fp() const { return fp_; }
    bool is_std() const { return is_std_; }
    int type() const { return WFDB_LOCAL; }

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
    int eof() { return std::feof(fp_); }
    int error() { return std::ferror(fp_); }
    void clearerr() { std::clearerr(fp_); }
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
};

using FilePtr = std::unique_ptr<WFDBFile>;

// wfdbio.cpp
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

// signal.cpp
void wfdb_sampquit();
void wfdb_sigclose();
void wfdb_osflush();
int wfdb_oinfoclose();

// annot.cpp
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
