// wfdbio.cpp: low-level I/O functions of the WFDB library
// (C++ port of lib/wfdbio.c, WFDB 10.7.0)
//
// This file contains the WFDB path functions (getwfdb, setwfdb, ...), the
// functions that find and open WFDB files (wfdb_open, wfdb_fopen), error
// reporting (wfdb_error, wfdberror), the stdio wrappers of WFDB_FILE, and
// the wfdb-x settings that locate files (wfdbx_set_input_dir,
// wfdbx_set_output_dir, wfdbx_set_network).
//
// wfdb-x: files are found by explicit names instead of a search of the WFDB
// path: a relative name is read under the input directory and written under
// the output directory (by default, the current directory), and an absolute
// name, a ~ name or a URL is used as given; nothing else is searched.  A URL
// is opened only if network access was allowed (wfdbx_set_network or
// WFDBX_NETWORK); it is then read in full by the curl program, run without a
// shell.  Decided by Reza Sameni, Oct 2026: a search can silently open the
// wrong file (a stale copy earlier in the path) and fails in ways nobody
// notices, and the network must not be used without being asked for.  The
// sortann program (legacy mode, see annot.cpp) is run without a shell, in the
// output directory if one is set (Reza Sameni, after a code review, Oct
// 2026).  The original behavior remains available with --legacy (see
// docs/DIVERGENCES.md); legacy mode searches the WFDB path, and has no
// network access (as the C library built without libcurl).
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

#include <map>

#if defined(_WIN32)
#include <direct.h>
#include <fcntl.h>
#include <io.h>
#include <process.h>
#include <windows.h>
#define MKDIR(d) _mkdir(d)
#else
#include <fcntl.h>
#include <pwd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#define environ (*_NSGetEnviron())
#else
extern char **environ;
#endif
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
    // wfdb-x: the settings that locate files in normal mode (see
    // wfdbx_set_input_dir, wfdbx_set_output_dir, wfdbx_set_network).  Each
    // is read from its environment variable when it is first needed.
    std::optional<std::string> input_dir, env_input_dir;
    bool input_dir_init = false, wfdb_warned = false;
    std::optional<std::string> setwfdb_input_dir;   // set by setwfdb
    bool setwfdb_called = false;
    std::optional<std::string> output_dir, env_output_dir;
    bool output_dir_init = false;
    int network = -1;           // -1 until first needed
    int env_network = 0;
    // wfdb-x: the URLs fetched (contents, or nullopt for a failure)
    std::map<std::string, std::optional<std::string>> fetched;
    bool network_warned = false, curl_warned = false;
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

// wfdb-x: true if s is an http:// or https:// URL.
bool is_url(const std::string &s)
{
    return s.compare(0, 7, "http://") == 0 || s.compare(0, 8, "https://") == 0;
}

// wfdb-x: true if c is a directory separator ('/', and on MS-Windows '\').
bool is_dsep(char c)
{
#if defined(_WIN32)
    if (c == '\\') return true;
#endif
    return c == '/';
}

// The next component of the path string s, from position q (after any
// whitespace): its beginning is stored in start and its type (WFDB_LOCAL or
// WFDB_NET) in type, and the position of its end (the character that follows
// it) is returned.  (wfdb-x: used by wfdb_parse_path, and by setwfdb in
// normal mode.)
size_t path_component(const std::string &s, size_t q, size_t &start, int &type)
{
    size_t n = s.size();
    while (q < n && std::strchr(" \t\n\r", s[q])) q++;
    start = q;
    type = WFDB_LOCAL;
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
    return q;
}

void init_input_dir()
{
    IOState &st = io();
    if (!st.input_dir_init) {
        st.input_dir_init = true;
        const char *p = std::getenv("WFDBX_INPUT_DIR");
        if (p && *p) st.env_input_dir = st.input_dir = std::string(p);
    }
    if (!st.wfdb_warned && !wfdbx_get_legacy()) {
        st.wfdb_warned = true;
        const char *p = std::getenv("WFDB");
        if (p && *p)
            wfdb_error("wfdb-x: the WFDB environment variable is ignored; set "
                       "WFDBX_INPUT_DIR instead (or use legacy mode)\n");
    }
}

// Replace the input directory (by the default if dir is null or empty).
void put_input_dir(const char *dir)
{
    init_input_dir();
    IOState &st = io();
    if (dir && *dir)
        st.input_dir = std::string(dir);
    else
        st.input_dir = st.env_input_dir;
}

const char *const output_url_error =
    "wfdbx_set_output_dir: the output directory must be a local directory\n";

void init_output_dir()
{
    IOState &st = io();
    if (st.output_dir_init) return;
    st.output_dir_init = true;
    const char *p = std::getenv("WFDBX_OUTPUT_DIR");
    if (p && *p) {
        if (is_url(p))
            wfdb_error("%s", output_url_error);
        else
            st.env_output_dir = st.output_dir = std::string(p);
    }
}

// setwfdb in normal mode: the path p, split into components as by
// wfdb_parse_path, must name at most one input directory.
void setwfdb_normal(const char *p)
{
    std::string s(p ? p : "");
    std::optional<std::string> d;
    int n = 0, type;
    for (size_t q = 0, start; q < s.size();) {
        q = path_component(s, q, start, type);
        if (q > start && n++ == 0) d = s.substr(start, q - start);
        if (q < s.size()) q++;
    }
    if (n > 1) {
        wfdb_error("setwfdb: wfdb-x reads from a single input directory; use "
                   "wfdbx_set_input_dir (or legacy mode for the WFDB search "
                   "path)\n");
        return;
    }
    put_input_dir(d ? d->c_str() : nullptr);
    IOState &st = io();
    st.setwfdb_input_dir = d;
    st.setwfdb_called = true;
}

// wfdb-x: the name s, with a leading "~" or "~/" replaced by the home
// directory ($HOME, or the home directory of the current user if HOME is not
// set; on MS-Windows, %USERPROFILE%), and, on POSIX systems, "~user" by the
// home directory of that user (if there is no such user, s is unchanged), as
// Python's os.path.expanduser does.
std::string expand_home(const std::string &s)
{
    if (s.empty() || s[0] != '~') return s;
    size_t rest = 1;
    while (rest < s.size() && !is_dsep(s[rest])) rest++;
    std::optional<std::string> home;
    if (rest == 1) {
#if defined(_WIN32)
        if (const char *h = std::getenv("USERPROFILE")) home = h;
#else
        if (const char *h = std::getenv("HOME"))
            home = h;
        else if (struct passwd *pw = getpwuid(getuid()))
            home = pw->pw_dir;
#endif
    }
#if !defined(_WIN32)
    else if (struct passwd *pw = getpwnam(s.substr(1, rest - 1).c_str()))
        home = pw->pw_dir;
#endif
    if (!home) return s;
    while (!home->empty() && is_dsep(home->back())) home->pop_back();
    std::string r = *home + s.substr(rest);
    return r.empty() ? "/" : r;
}

// wfdb-x: dir + sep + name, with exactly one separator between them ('/' in
// a URL, otherwise sep).
std::string join(const std::string &dir, const std::string &name, char sep)
{
    if (is_url(dir)) sep = '/';
    if (dir.empty() || dir.back() == sep || is_dsep(dir.back()))
        return dir + name;
    return dir + sep + name;
}

// wfdb-x: the location of the file named name in normal mode: an absolute
// name or a URL as given, a ~ name expanded, and a relative name under the
// input directory (for reading) or the output directory (for writing), if
// one is set.
std::string resolve(const std::string &name, bool output)
{
    if (!name.empty() && name[0] == '~') return expand_home(name);
    if (is_absolute_path(name) || is_url(name)) return name;
    if (output)
        init_output_dir();
    else
        init_input_dir();
    const std::optional<std::string> &dir =
        output ? io().output_dir : io().input_dir;
    if (!dir) return name;
    return join(expand_home(*dir), name, output ? DSEP : '/');
}

// wfdb-x: true if a file name found in a header names a file in the header's
// directory or below it: a relative name that does not begin with '~' and
// contains no ".." component (on MS-Windows, no drive letter either).
bool in_header_dir(const std::string &name)
{
    if (is_absolute_path(name) || is_url(name) || (!name.empty() && name[0] == '~'))
        return false;
#if defined(_WIN32)
    if (name.size() > 1 && name[1] == ':') return false;
#endif
    for (size_t p = 0;;) {
        size_t q = p;
        while (q < name.size() && !is_dsep(name[q])) q++;
        if (q - p == 2 && name[p] == '.' && name[p + 1] == '.') return false;
        if (q >= name.size()) return true;
        p = q + 1;
    }
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

// ---------------------------------------------------------------------------
// wfdb-x: remote files.  In normal mode, a URL (http:// or https://) is opened
// only if network access is allowed (see wfdbx_set_network).  It is then read
// in full (no range requests) by the system program curl, run without a
// shell as
//     curl --silent --fail --location --connect-timeout 30
//          --speed-limit 1 --speed-time 30 URL
// (following redirections, failing on an HTTP status of 400 or more, and
// giving up if connecting takes 30 seconds or no data arrives for 30 seconds;
// there is no limit on the total time, since record files can be large),
// reading its standard output.  The result (the contents, or a failure) is
// kept for the rest of the process, so that each URL is requested at most
// once.  The file is read from a temporary copy.

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

// Read the URL into data.  Returns 1 on success, 0 on failure, or -1 if curl
// could not be started.
int run_curl(const std::string &url, std::string &data)
{
    const char *argv[] = {"curl", "--silent", "--fail", "--location",
                          "--connect-timeout", "30", "--speed-limit", "1",
                          "--speed-time", "30", url.c_str(), nullptr};
    int status;
    data.clear();
    std::fflush(stdout);
    std::fflush(stderr);
#if defined(_WIN32)
    // The standard output of curl goes to a temporary file, and its standard
    // error to NUL (both redirected while it runs).  (Untested.)
    std::FILE *tf = std::tmpfile();
    if (tf == nullptr) return 0;
    std::string quoted = quote_arg(url);
    argv[6] = quoted.c_str();
    int so = _dup(1), se = _dup(2), nul = _open("NUL", _O_WRONLY);
    _dup2(_fileno(tf), 1);
    if (nul >= 0) _dup2(nul, 2);
    intptr_t r = _spawnvp(_P_WAIT, "curl", argv);
    _dup2(so, 1);
    _dup2(se, 2);
    _close(so);
    _close(se);
    if (nul >= 0) _close(nul);
    if (r == -1) {
        std::fclose(tf);
        return -1;
    }
    status = static_cast<int>(r);
    std::rewind(tf);
    char buf[65536];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof(buf), tf)) > 0) data.append(buf, n);
    std::fclose(tf);
#else
    int fd[2];
    if (pipe(fd) != 0) return 0;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, fd[1], 1);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addclose(&fa, fd[0]);
    posix_spawn_file_actions_addclose(&fa, fd[1]);
    pid_t pid;
    int err = posix_spawnp(&pid, "curl", &fa, nullptr,
                           const_cast<char *const *>(argv), environ);
    posix_spawn_file_actions_destroy(&fa);
    close(fd[1]);
    if (err != 0) {
        close(fd[0]);
        return -1;
    }
    char buf[65536];
    for (;;) {
        ssize_t n = read(fd[0], buf, sizeof(buf));
        if (n > 0)
            data.append(buf, static_cast<size_t>(n));
        else if (n < 0 && errno == EINTR)
            continue;
        else
            break;
    }
    close(fd[0]);
    while (waitpid(pid, &status, 0) < 0)
        if (errno != EINTR) return 0;
    if (!WIFEXITED(status)) return 0;
    status = WEXITSTATUS(status);
#endif
    if (status == 127) return -1;   // the shell's code for "command not found"
    return status == 0;
}

// Open a URL for reading.
FilePtr fetch_open(const std::string &url)
{
    IOState &st = io();
    if (!wfdbx_get_network()) {
        if (!st.network_warned) {
            st.network_warned = true;
            wfdb_error("wfdb-x: network access is disabled; set "
                       "WFDBX_NETWORK=1 or call wfdbx_set_network(1) to open "
                       "%s\n", url.c_str());
        }
        return nullptr;
    }
    auto it = st.fetched.find(url);
    if (it == st.fetched.end()) {
        std::string data;
        int stat = run_curl(url, data);
        if (stat < 0 && !st.curl_warned) {
            st.curl_warned = true;
            wfdb_error("wfdb-x: network access needs the curl program, which "
                       "was not found\n");
        }
        it = st.fetched.emplace(url, stat > 0 ? std::optional<std::string>(
                                                    std::move(data))
                                              : std::nullopt).first;
    }
    if (!it->second) return nullptr;
    std::FILE *fp = std::tmpfile();
    if (fp == nullptr) return nullptr;
    const std::string &data = *it->second;
    if (!data.empty() && std::fwrite(data.data(), 1, data.size(), fp) !=
                             data.size()) {
        std::fclose(fp);
        return nullptr;
    }
    std::rewind(fp);
    return std::make_unique<WFDBFile>(fp, false, WFDB_FETCHED);
}

} // namespace

FilePtr wfdb_fopen(const char *fname, const char *mode)
{
    if (fname == nullptr) return nullptr;
    if (wfdbx_get_legacy()) {
        // As the C library built without network support: names containing
        // ".." or "://" are refused.
        if (std::strstr(fname, "..") || std::strstr(fname, "://"))
            return nullptr;
    } else if (is_url(fname))   // wfdb-x: ".." is accepted; a URL is fetched
        return mode[0] == 'r' ? fetch_open(fname) : nullptr;
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

// If the record name ends with '/', append the last component of the
// directory name (e.g. "foo/bar/" becomes "foo/bar/bar").  (wfdb-x: this was
// part of wfdb_open.)
std::string expand_record(const std::string &record)
{
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
        if (q < p) r += record.substr(q, p - q);
    }
    return r;
}

// wfdb-x: open the file at location p (as resolved by resolve, or in the
// directory of a header) for reading, trying the two forms of the name (see
// spr1 and spr2) there.
FilePtr open_at(const std::string &p, const char *s)
{
    IOState &st = io();
    if (s == nullptr) s = "";
    st.filename = spr1(p, s);
    if (FilePtr f = wfdb_fopen(st.filename.c_str(), "rb")) return f;
    std::string long_filename = st.filename;
    st.filename = spr2(p, s);
    if (st.filename != long_filename)
        return wfdb_fopen(st.filename.c_str(), "rb");
    return nullptr;
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

    std::string r = expand_record(record);  // (wfdb-x: moved there)

    if (mode == WFDB_WRITE || mode == WFDB_APPEND) {
        st.filename = spr1(r, s);
        init_output_dir();
        if (!wfdbx_get_legacy()) {
            // wfdb-x: a relative name in the output directory, if one is set;
            // a URL cannot be written
            if (is_url(st.filename)) return nullptr;
            st.filename = resolve(st.filename, true);
        }
        // wfdb-x: legacy mode: any name in the output directory, if set
        else if (st.output_dir)
            st.filename = *st.output_dir + DSEP + st.filename;
        return wfdb_fopen(st.filename.c_str(), mode == WFDB_WRITE ? "wb" : "ab");
    }

    // wfdb-x: in normal mode, the file is opened at the one location that its
    // name designates (see resolve); nothing is searched.
    if (!wfdbx_get_legacy()) return open_at(resolve(r, false), s);

    if (st.path_list.empty()) getwfdb();

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
        if (c.type == WFDB_NET) continue;   // remote files: none in legacy mode
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

std::optional<std::string> wfdbx_output_file(const char *name)
{
    if (name == nullptr || *name == '\0' || std::strcmp(name, "-") == 0)
        return std::nullopt;
    std::string r = expand_record(name);
    if (is_url(r)) return std::nullopt;
    return resolve(r, true);
}

bool wfdbx_in_header_dir(const std::string &name) { return in_header_dir(name); }

FilePtr wfdbx_open_in(const std::optional<std::string> &dir, const char *s,
                      const char *name, const char *record)
{
    if (std::strcmp(name, "-") == 0) return wfdb_open(s, name, WFDB_READ);
    if (!in_header_dir(name)) {
        wfdb_error("init: file %s named in the header of record %s is not "
                   "in the header's directory\n", name, record);
        return nullptr;
    }
    if (!dir) return wfdb_open(s, name, WFDB_READ);
    return open_at(*dir + name, s);
}

std::string wfdbx_dirname(const std::string &path)
{
    size_t p = path.size();
    while (p > 0 && !is_dsep(path[p - 1])) p--;
    return path.substr(0, p);
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
    size_t n = s.size(), q = 0, start;
    int type;
    while (q < n) {
        q = path_component(s, q, start, type);
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

// wfdb-x: in normal mode, setwfdb, getwfdb and resetwfdb set and return the
// input directory (see wfdbx_set_input_dir) instead of the WFDB path.
// setwfdb(p): p, split into components as the WFDB path is, must contain at
// most one non-empty component, which becomes the input directory (none: the
// default); with more, setwfdb reports an error and changes nothing.  getwfdb
// returns the input directory, or "." if none is set.  resetwfdb restores the
// input directory set by the last setwfdb, if any (wfdbquit does not call it
// in normal mode).  The WFDB environment variable, @FILE paths, %r and
// wfdb_addtopath are used only in legacy mode.

void resetwfdb()
{
    IOState &st = io();
    // wfdb-x: the input directory set by the last setwfdb, if any
    if (!wfdbx_get_legacy()) {
        if (st.setwfdb_called)
            put_input_dir(st.setwfdb_input_dir ? st.setwfdb_input_dir->c_str()
                                               : nullptr);
        return;
    }
    if (st.wfdbpath_init) {
        st.wfdbpath = st.wfdbpath_init;
    }
}

std::string getwfdb()
{
    IOState &st = io();
    // wfdb-x: the input directory, or "." if none is set
    if (!wfdbx_get_legacy()) {
        init_input_dir();
        return st.input_dir.value_or(".");
    }
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
    // wfdb-x: the path names a single input directory
    if (!wfdbx_get_legacy()) {
        setwfdb_normal(p);
        return;
    }
    if (p == nullptr && (p = std::getenv("WFDB")) == nullptr) p = DEFWFDB;
    std::string value(p);
    export_config(value.c_str());
    st.wfdbpath = getiwfdb(value);
    wfdb_parse_path(st.wfdbpath->c_str());
}

bool detail::wfdb_set_error_print(bool on)
{
    bool previous = io().error_print;
    io().error_print = on;
    return previous;
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

std::optional<std::string> wfdbx_set_input_dir(const char *dir)
{
    init_input_dir();
    std::optional<std::string> previous = io().input_dir;
    put_input_dir(dir);
    return previous;
}

std::optional<std::string> wfdbx_get_input_dir()
{
    init_input_dir();
    return io().input_dir;
}

std::optional<std::string> wfdbx_set_output_dir(const char *dir)
{
    IOState &st = io();
    init_output_dir();
    if (dir && is_url(dir)) {
        wfdb_error("%s", output_url_error);
        return st.output_dir;
    }
    std::optional<std::string> previous = std::move(st.output_dir);
    if (dir && *dir)
        st.output_dir = std::string(dir);
    else
        st.output_dir = st.env_output_dir;
    return previous;
}

std::optional<std::string> wfdbx_get_output_dir()
{
    init_output_dir();
    return io().output_dir;
}

int wfdbx_set_network(int on)
{
    int previous = wfdbx_get_network();
    IOState &st = io();
    st.network = on < 0 ? st.env_network : (on != 0);
    return previous;
}

int wfdbx_get_network()
{
    IOState &st = io();
    if (st.network < 0) {
        const char *p = std::getenv("WFDBX_NETWORK");
        st.env_network = (p != nullptr && std::strtol(p, nullptr, 10) != 0);
        st.network = st.env_network;
    }
    return st.network;
}

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
