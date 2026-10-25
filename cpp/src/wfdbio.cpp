// wfdbio.cpp: low-level I/O functions of the WFDB library
// (C++ port of lib/wfdbio.c, WFDB 10.7.0)
//
// This file contains the WFDB path functions (getwfdb, setwfdb, ...), the
// functions that find and open WFDB files (wfdb_open, wfdb_fopen), error
// reporting (wfdb_error, wfdberror), and the stdio wrappers of WFDB_FILE.
// Remote (http, ftp) files are not supported by the C++ implementation;
// WFDB path components that are URLs are ignored.
//
// wfdb-x: wfdb_open opens an input file named by an absolute path directly
// (the C library searched for it in each directory of the WFDB path, so that
// it was found only if the path had an empty component or the current
// directory was the root), and output files can be created in a directory
// set with wfdbx_set_output_dir; the sortann program (legacy mode, see
// annot.cpp) is run without a shell, in the output directory if one is set.  Decided by Reza Sameni after a code
// review, Oct 2026.  The original behavior remains available with --legacy
// (see docs/DIVERGENCES.md).
//
// Copyright (C) 1988-2013 George B. Moody (original C implementation,
// lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

#include "wfdblib.hpp"

#include <cerrno>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>
#include <sys/types.h>

#if defined(_WIN32)
#include <direct.h>
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#define MKDIR(d) _mkdir(d)
#else
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif
#define MKDIR(d) mkdir((d), 0755)
#endif

namespace wfdbx {

const char *const DEFWFDB =
    ". /usr/local/database http://physionet.org/physiobank/database";

namespace detail {

namespace {

// The C library reports the date on which it was compiled; wfdb-x reports
// the date of the WFDB release it reproduces.
const char *const WFDB_BUILD_DATE = "Jun 10 2022";
const char DSEP = '/';

struct PathComponent {
    std::string prefix;
    int type;
};

struct IOState {
    std::optional<std::string> wfdbpath;
    std::optional<std::string> wfdbpath_init;
    std::vector<PathComponent> path_list;
    bool error_print = true;
    bool error_flag = false;
    std::string error_message;
    std::string filename;       // name of the file most recently opened
    std::string irec;           // current record name (for %r)
    int mem_behavior = 1;
    // wfdb-x: the directory in which wfdb_open creates output files (none:
    // files are created as named; see wfdbx_set_output_dir)
    std::optional<std::string> output_dir;
};

IOState &io()
{
    static IOState state;
    return state;
}

std::string spr1(const std::string &record, const char *type)
{
    if (*type == '\0') return record;
    return record + "." + type;
}

std::string spr2(const std::string &record, const char *type)
{
    if (*type == '\0') return record + ".";
    return record + "." + std::string(type, strnlen(type, 3));
}

void export_config(const char *p)
{
#if defined(_WIN32)
    _putenv_s("WFDB", p);
    if (!std::getenv("WFDBCAL")) _putenv_s("WFDBCAL", DEFWFDBCAL);
    if (!std::getenv("WFDBANNSORT")) _putenv_s("WFDBANNSORT", "1");
    if (!std::getenv("WFDBGVMODE")) _putenv_s("WFDBGVMODE", "0");
#else
    setenv("WFDB", p, 1);
    setenv("WFDBCAL", DEFWFDBCAL, 0);
    setenv("WFDBANNSORT", "1", 0);
    setenv("WFDBGVMODE", "0", 0);
#endif
}

// If p begins with '@', read the WFDB path from the named file
// (wfdb_getiwfdb).
std::string getiwfdb(std::string p)
{
    constexpr int MAXNEST = 10;     // how deeply '@' files may be nested
    for (int i = 0; i < MAXNEST && !p.empty() && p[0] == '@'; i++) {
        std::FILE *f = std::fopen(p.c_str() + 1, "rb");
        if (!f) {
            p.clear();
        } else {
            std::string data;
            char buf[4096];
            size_t n;
            while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0)
                data.append(buf, n);
            std::fclose(f);
            while (!data.empty() &&
                   (data.back() == '\r' || data.back() == '\n'))
                data.pop_back();
            p = data;
        }
    }
    if (!p.empty() && p[0] == '@') {
        wfdb_error("getwfdb: files nested too deeply\n");
        p.clear();
    }
    return p;
}

bool is_directory(const char *name)
{
    struct stat st;
    return stat(name, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR;
}

// wfdb-x: true if s is an absolute local path: on POSIX systems, a path
// beginning with '/'; on MS-Windows, one beginning with 'X:\', 'X:/', '\\'
// or '/'.
bool is_absolute_path(const std::string &s)
{
#if defined(_WIN32)
    if (s.size() >= 3 &&
        ((s[0] >= 'A' && s[0] <= 'Z') || (s[0] >= 'a' && s[0] <= 'z')) &&
        s[1] == ':' && (s[2] == '\\' || s[2] == '/'))
        return true;
    if (s.size() >= 2 && s[0] == '\\' && s[1] == '\\') return true;
#endif
    return !s.empty() && s[0] == '/';
}

} // namespace

// ---------------------------------------------------------------------------
// Formatted output into strings

std::string vstrprintf(const char *format, va_list ap)
{
    char buf[512];
    va_list ap2;
    va_copy(ap2, ap);
    int n = std::vsnprintf(buf, sizeof(buf), format, ap);
    if (n < 0) {
        va_end(ap2);
        return std::string();
    }
    if (static_cast<size_t>(n) < sizeof(buf)) {
        va_end(ap2);
        return std::string(buf, n);
    }
    std::string s(n + 1, '\0');
    std::vsnprintf(&s[0], n + 1, format, ap2);
    va_end(ap2);
    s.resize(n);
    return s;
}

std::string strprintf(const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    std::string s = vstrprintf(format, ap);
    va_end(ap);
    return s;
}

// ---------------------------------------------------------------------------
// WFDBFile

int WFDBFile::printf(const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    int n = std::vfprintf(fp_, format, ap);
    va_end(ap);
    return n;
}

int WFDBFile::seek(long offset, int whence)
{
#if defined(_WIN32)
    return _fseeki64(fp_, offset, whence);
#else
    return fseeko(fp_, static_cast<off_t>(offset), whence);
#endif
}

long WFDBFile::tell()
{
#if defined(_WIN32)
    return static_cast<long>(_ftelli64(fp_));
#else
    return static_cast<long>(ftello(fp_));
#endif
}

int WFDBFile::close()
{
    if (!fp_) return 0;
    int status;
    if (is_std_)
        status = std::fflush(fp_);
    else
        status = std::fclose(fp_);
    fp_ = nullptr;
    return status;
}

size_t WFDBFile::getline(std::string &line)
{
    line.clear();
    int c;
    while ((c = getc()) != EOF) {
        line.push_back(static_cast<char>(c));
        if (c == '\n') break;
    }
    return line.size();
}

char *WFDBFile::fgets(char *s, int size)
{
    return std::fgets(s, size, fp_);
}

// ---------------------------------------------------------------------------
// Opening files

const std::string &wfdb_filename() { return io().filename; }

FilePtr wfdb_fopen(const char *fname, const char *mode)
{
    if (fname == nullptr || std::strstr(fname, "..")) return nullptr;
    if (std::strstr(fname, "://")) return nullptr; // remote files: no support
    if (mode[0] == 'r' && is_directory(fname)) return nullptr;
    std::FILE *fp = std::fopen(fname, mode);
    if (fp) return std::make_unique<WFDBFile>(fp, false);
    if (std::strcmp(mode, "wb") == 0 || std::strcmp(mode, "ab") == 0) {
        // Try to create any missing directories in the path.
        int stat = 1;
        std::string p(fname);
        for (size_t i = 0; i < p.size(); i++) {
            if (p[i] == '/') {
                std::string d = p.substr(0, i);
                stat = MKDIR(d.c_str());
            }
        }
        if (stat == 0 && (fp = std::fopen(fname, mode)) != nullptr)
            return std::make_unique<WFDBFile>(fp, false);
    }
    return nullptr;
}

namespace {

FilePtr std_stream(bool read)
{
    std::FILE *fp = read ? stdin : stdout;
#if defined(_WIN32)
    _setmode(_fileno(fp), _O_BINARY);
#endif
    return std::make_unique<WFDBFile>(fp, true);
}

} // namespace

FilePtr wfdb_open(const char *s, const char *record, int mode)
{
    IOState &st = io();
    if (s == nullptr) s = "";
    if (record == nullptr || *record == '\0') {
        if (*s) {
            record = s;
            s = "";
        } else
            return nullptr;
    }
    if (std::strcmp(record, "-") == 0) return std_stream(mode == WFDB_READ);

    // If the record name ends with '/', append the last component of the
    // directory name (e.g. "foo/bar/" becomes "foo/bar/bar").
    std::string r(record);
    size_t rlen = r.size();
    if (rlen > 1 && r[rlen - 1] == '/') {
        size_t p = rlen - 1, q = p - 1;
        while (q > 0) {
            if (r[q] == '/') {
                q++;
                break;
            }
            q--;
        }
        if (q < p) r += std::string(record + q, record + p);
    }

    if (mode == WFDB_WRITE || mode == WFDB_APPEND) {
        st.filename = spr1(r, s);
        // wfdb-x: in the output directory, if one was set
        if (st.output_dir) st.filename = *st.output_dir + DSEP + st.filename;
        return wfdb_fopen(st.filename.c_str(), mode == WFDB_WRITE ? "wb" : "ab");
    }

    if (st.path_list.empty()) getwfdb();

    // wfdb-x: an absolute local path is opened directly (and its directory
    // is added to the WFDB path, so that the files next to it are found); if
    // it cannot be, the WFDB path is searched as in the C library (and in
    // legacy mode).
    if (!wfdbx_get_legacy() && is_absolute_path(r)) {
        st.filename = spr1(r, s);
        if (FilePtr f = wfdb_fopen(st.filename.c_str(), "rb")) {
            wfdb_addtopath(st.filename.c_str());
            return f;
        }
    }

    std::vector<PathComponent> plist = st.path_list;
    for (const PathComponent &c : plist) {
        // Substitute the record name for %r (or its first N characters for
        // %Nr) in the path component.
        std::string b;
        const std::string &pr = c.prefix;
        size_t n = pr.size();
        for (size_t i = 0; i < n;) {
            char ch = pr[i];
            if (ch == '%') {
                i++;
                ch = i < n ? pr[i] : '\0';
                if (ch == 'r') {
                    b += st.irec;
                    i++;
                } else if (ch >= '1' && ch <= '9' && i + 1 < n &&
                           pr[i + 1] == 'r') {
                    b += st.irec.substr(0, ch - '0');
                    i += 2;
                } else {
                    if (ch != '\0') b += ch;
                    i++;
                }
            } else {
                b += ch;
                i++;
            }
        }
        if (c.type == WFDB_NET) continue;   // remote files: no support
        if (!b.empty() && b.back() != DSEP) b += DSEP;
        b += r;
        st.filename = spr1(b, s);
        FilePtr f = wfdb_fopen(st.filename.c_str(), "rb");
        if (f) {
            wfdb_addtopath(st.filename.c_str());
            return f;
        }
        std::string long_filename = st.filename;
        st.filename = spr2(b, s);
        if (st.filename != long_filename) {
            f = wfdb_fopen(st.filename.c_str(), "rb");
            if (f) {
                wfdb_addtopath(st.filename.c_str());
                return f;
            }
        }
    }
    return nullptr;
}

int wfdb_checkname(const char *p, const char *s)
{
    if (p == nullptr) p = "";
    do {
        char c = *p;
        if (('0' <= c && c <= '9') || c == '_' || c == '~' || c == '-' ||
            c == DSEP || ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z'))
            p++;
        else {
            wfdb_error("init: illegal character %d in %s name\n", c, s);
            return -1;
        }
    } while (*p);
    return 0;
}

std::string wfdb_striphea(const char *p)
{
    if (p == nullptr) return std::string();
    std::string r(p);
    if (r.size() > 4 && r.compare(r.size() - 4, 4, ".hea") == 0)
        r.resize(r.size() - 4);
    return r;
}

void wfdb_setirec(const char *p)
{
    const char *r = std::strrchr(p, DSEP);
    r = r ? r + 1 : p;
    if (std::strcmp(r, "-") != 0)
        io().irec = std::string(r, strnlen(r, WFDB_MAXRNL));
}

std::optional<std::string> wfdb_getirec()
{
    if (io().irec.empty()) return std::nullopt;
    return io().irec;
}

// ---------------------------------------------------------------------------
// WFDB path

int wfdb_parse_path(const char *p)
{
    IOState &st = io();
    st.path_list.clear();
    if (p == nullptr) return 0;
    std::string s(p);
    size_t n = s.size(), q = 0;
    while (q < n) {
        while (q < n && std::strchr(" \t\n\r", s[q]) && s[q]) q++;
        size_t start = q;
        int type = WFDB_LOCAL;
        int slashes = 0;
        for (;; q++) {
            char c = q < n ? s[q] : '\0';
            if (c == ':') {
                if (s.compare(q + 1, 2, "//") == 0)
                    type = WFDB_NET;
                else if (type != WFDB_NET || slashes > 2)
                    break;
            } else if (c == ';' || c == ' ' || c == '\t' || c == '\n' ||
                       c == '\r' || c == '\0')
                break;
            else if (c == '/')
                slashes++;
        }
        st.path_list.push_back({s.substr(start, q - start), type});
        if (q < n) q++;
    }
    return 0;
}

void wfdb_addtopath(const char *s)
{
    if (s == nullptr || *s == '\0') return;
    long p = static_cast<long>(std::strlen(s)) - 1;
    while (p >= 0 && !std::strchr("/\\:", s[p])) p--;
    if (p == 0 && std::strchr("/\\:", s[0])) p++;
    if (p < 0) return;
    IOState &st = io();
    if (!st.wfdbpath) getwfdb();
    std::vector<PathComponent> &plist = st.path_list;
    if (plist.empty()) return;
    std::optional<PathComponent> found;
    for (size_t idx = 0; idx < plist.size(); idx++) {
        if (std::strncmp(plist[idx].prefix.c_str(), s, p) == 0) {
            if (idx == 0 || (idx == 1 && plist[0].prefix == "."))
                return;     // no changes needed
            found = plist[idx];
            plist.erase(plist.begin() + idx);
            break;
        }
    }
    if (!found) {
        std::string prefix(s, p);
        found = PathComponent{prefix, prefix.find("://") != std::string::npos
                                          ? WFDB_NET : WFDB_LOCAL};
    }
    if (plist[0].prefix == ".")
        plist.insert(plist.begin() + 1, *found);
    else
        plist.insert(plist.begin(), *found);
}

// ---------------------------------------------------------------------------
// The sortann program, run by oannclose in legacy mode

namespace {

#if defined(_WIN32)
// An argument of a command line, quoted as the MS-Windows C runtime parses it
// (_spawnvp joins its arguments with spaces, without quoting them).
std::string quote_arg(const std::string &a)
{
    if (!a.empty() && a.find_first_of(" \t\"") == std::string::npos)
        return a;
    std::string q = "\"";
    size_t backslashes = 0;
    for (char c : a) {
        if (c == '\\') {
            backslashes++;
            continue;
        }
        q.append(c == '"' ? 2 * backslashes + 1 : backslashes, '\\');
        backslashes = 0;
        q += c;
    }
    q.append(2 * backslashes, '\\');
    return q + "\"";
}
#endif

// Run the program prog (looked for in the PATH unless it contains a
// directory) with the arguments args (args[0] being the program name), without
// a shell, in the directory workdir if given (else the current one), and wait
// for it.  Returns its exit status, or -1 if it could not be run or did not
// exit normally.
int run_program(const std::string &prog, const std::vector<std::string> &args,
                const std::optional<std::string> &workdir)
{
    std::fflush(stdout);
    std::fflush(stderr);
#if defined(_WIN32)
    std::string cmdline;
    for (const std::string &a : args)
        cmdline += (cmdline.empty() ? "" : " ") + quote_arg(a);
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));
    if (!CreateProcessA(prog.find_first_of("/\\") != std::string::npos
                            ? prog.c_str() : nullptr,
                        &cmdline[0], nullptr, nullptr, FALSE, 0, nullptr,
                        workdir ? workdir->c_str() : nullptr, &si, &pi))
        return -1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    BOOL ok = GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return ok ? static_cast<int>(code) : -1;
#else
    std::vector<char *> argv;
    for (const std::string &a : args) argv.push_back(const_cast<char *>(a.c_str()));
    argv.push_back(nullptr);
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {     // the child: change directory, then run the program
        if (workdir && chdir(workdir->c_str()) != 0) _exit(127);
        execvp(prog.c_str(), argv.data());
        _exit(127);
    }
    int status;
    while (waitpid(pid, &status, 0) < 0)
        if (errno != EINTR) return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
#endif
}

} // namespace

int run_sortann(const std::string &record, const std::string &annotator,
                const std::optional<std::string> &workdir)
{
    std::string exe;
#if defined(__linux__)
    char buf[4096];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n > 0) exe.assign(buf, n);
#elif defined(__APPLE__)
    char buf[4096];
    uint32_t size = sizeof(buf);
    char real[PATH_MAX];
    // (absolute, as the program may run in another directory)
    if (_NSGetExecutablePath(buf, &size) == 0)
        exe = realpath(buf, real) ? real : buf;
#elif defined(_WIN32)
    char buf[4096];
    DWORD n = GetModuleFileNameA(nullptr, buf, sizeof(buf));
    if (n > 0 && n < sizeof(buf)) exe.assign(buf, n);
#endif
    std::string prog = "sortann";
    size_t slash = exe.find_last_of("/\\");
    if (slash != std::string::npos) {
        std::string candidate = exe.substr(0, slash + 1) + "sortann";
#if defined(_WIN32)
        candidate += ".exe";
#endif
        struct stat sb;
        if (stat(candidate.c_str(), &sb) == 0) prog = candidate;
    }
    // wfdb-x: the arguments are passed directly (the C library ran the
    // command "sortann -r. RECORD -a ANNOTATOR" through the shell), with
    // --legacy first, so that the program also behaves as the original.
    return run_program(prog, {prog, "--legacy", "-r.", record, "-a", annotator},
                       workdir);
}

} // namespace detail

using namespace detail;

// ---------------------------------------------------------------------------
// Public functions

void resetwfdb()
{
    IOState &st = io();
    if (st.wfdbpath_init) {
        st.wfdbpath = st.wfdbpath_init;
    }
}

std::string getwfdb()
{
    IOState &st = io();
    if (!st.wfdbpath) {
        const char *p = std::getenv("WFDB");
        if (p == nullptr) p = DEFWFDB;
        std::string path = getiwfdb(p);
        st.wfdbpath = path;
        st.wfdbpath_init = path;
        wfdb_parse_path(path.c_str());
    }
    return *st.wfdbpath;
}

void setwfdb(const char *p)
{
    IOState &st = io();
    if (p == nullptr && (p = std::getenv("WFDB")) == nullptr) p = DEFWFDB;
    std::string value(p);
    export_config(value.c_str());
    st.wfdbpath = getiwfdb(value);
    wfdb_parse_path(st.wfdbpath->c_str());
}

void wfdbquiet() { io().error_print = false; }

void wfdbverbose() { io().error_print = true; }

std::string wfdberror()
{
    IOState &st = io();
    if (!st.error_flag)
        st.error_message =
            strprintf("WFDB library version %d.%d.%d (%s).\n", WFDB_MAJOR,
                      WFDB_MINOR, WFDB_RELEASE, WFDB_BUILD_DATE);
    return st.error_message;
}

void wfdb_error(const char *format, ...)
{
    IOState &st = io();
    va_list ap;
    va_start(ap, format);
    st.error_flag = true;
    st.error_message = vstrprintf(format, ap);
    va_end(ap);
    if (st.error_print) {
        std::fputs(st.error_message.c_str(), stderr);
        std::fflush(stderr);
    }
}

std::optional<std::string> wfdbx_set_output_dir(const char *dir)
{
    IOState &st = io();
    std::optional<std::string> previous = std::move(st.output_dir);
    st.output_dir.reset();
    if (dir && *dir) st.output_dir = dir;
    return previous;
}

std::optional<std::string> wfdbx_get_output_dir() { return io().output_dir; }

void wfdbmemerr(int behavior) { io().mem_behavior = behavior; }

int wfdb_me_fatal() { return io().mem_behavior; }

std::string wfdbversion() { return "10.7.0"; }
std::string wfdbldflags() { return ""; }
std::string wfdbcflags() { return ""; }
std::string wfdbdefwfdb() { return DEFWFDB; }
std::string wfdbdefwfdbcal() { return DEFWFDBCAL; }

std::optional<std::string> wfdbfile(const char *s, const char *record)
{
    if (s == nullptr && record == nullptr) return io().filename;
    std::string rec;
    if (record) {
        rec = wfdb_striphea(record);
        record = rec.c_str();
    }
    FilePtr f = wfdb_open(s, record, WFDB_READ);
    if (f) return io().filename;
    return std::nullopt;
}

} // namespace wfdbx
