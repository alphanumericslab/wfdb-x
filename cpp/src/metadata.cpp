// metadata.cpp: header metadata, the "Key: value" info strings of the header
// of a record (see <wfdbx/record.hpp>; the equivalent of
// python/src/wfdbx/metadata.py)
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// The info strings of a header are its comment lines (lines that begin with
// '#') after the record line, as getinfo() reads them.  Many datasets store
// facts about the recording in them as "Key: value" pairs ("# Age: 63").
// read_metadata(), get_metadata(), set_metadata(), remove_metadata() and
// update_metadata() read and change such entries; read_header() returns them
// (Header::metadata), and write_record() writes them (WriteOptions::metadata).
//
// The rules (tests/metadata/README.md gives them in full; every
// implementation of WFDB-x follows them):
//
// * A header is split after each line feed; each line keeps its line ending
//   (CR LF, LF, or none for a last line without one).  The record line is
//   the first line that does not begin with '#'; every later line that
//   begins with '#' is an info string.  Only the .hea file is read, never
//   the .info file that getinfo() also reads.
// * An info string is an entry if the text after its '#' contains a colon:
//   the key is the text before the first colon, the value the rest, both
//   without spaces, tabs, VT, FF and CR at either end.  An info string
//   whose key is then empty or contains '#' is a free comment, which is
//   never returned or changed.
// * Keys are compared without regard to letter case (A-Z and a-z only).
//   If several entries have the same key, reading returns the first (with a
//   warning), set and update refuse to change it, and remove removes them
//   all.
// * An entry is written as "# Key: value" ("# Key:" for an empty value).  A
//   changed entry replaces its line (keeping its line ending); a new one is
//   inserted after the last info string, or after the last line that is not
//   blank, with the line ending of the record line.  Every other byte is
//   kept.  The new header is written to a temporary file in the directory of
//   the destination, which then replaces the destination (keeping its
//   permissions); nothing is written if nothing changes (unless `dir` is
//   given).
//
// Text is handled as bytes (std::string), as everywhere in the library.
// These functions open the header with wfdb_open, as the library opens a
// header, and use no other library state: they do not call wfdbquit(), and
// leave any open record as it is.

#include "wfdbx/record.hpp"

#include "wfdblib.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <random>
#include <sys/stat.h>
#include <sys/types.h>

#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#include <share.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

namespace wfdbx {

namespace {

namespace fs = std::filesystem;

// The characters removed from both ends of keys and values.
const char *const TRIM = " \t\v\f\r";
// The line ending of new lines when the header has none (that of the headers
// written by WFDB).
const char *const DEFAULT_EOL = "\r\n";

// One line of a header: its content (without the line ending) and its line
// ending ("\r\n", "\n", or "" for a last line without one).
struct Line {
    std::string content, eol;
};

// The lines of `data`, split after each LF.
std::vector<Line> split_lines(const std::string &data)
{
    std::vector<Line> lines;
    size_t start = 0, n = data.size();
    while (start < n) {
        size_t i = data.find('\n', start);
        if (i == std::string::npos) {
            lines.push_back({data.substr(start), ""});
            break;
        }
        if (i > start && data[i - 1] == '\r')
            lines.push_back({data.substr(start, i - 1 - start), "\r\n"});
        else
            lines.push_back({data.substr(start, i - start), "\n"});
        start = i + 1;
    }
    return lines;
}

// `s` without the characters of TRIM at both ends.
std::string strip(const std::string &s)
{
    size_t a = s.find_first_not_of(TRIM);
    if (a == std::string::npos) return std::string();
    return s.substr(a, s.find_last_not_of(TRIM) - a + 1);
}

// `key` with the letters A-Z changed to a-z (no other byte is changed).
std::string fold(std::string key)
{
    for (char &c : key)
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    return key;
}

bool starts_with_hash(const std::string &s)
{
    return !s.empty() && s[0] == '#';
}

// The key and value of an info string (`content`, beginning with '#'), or
// nullopt if it is a free comment.
std::optional<std::pair<std::string, std::string>>
entry_of(const std::string &content)
{
    std::string text = content.substr(1);
    size_t i = text.find(':');
    if (i == std::string::npos) return std::nullopt;
    std::string key = strip(text.substr(0, i));
    if (key.empty() || key.find('#') != std::string::npos) return std::nullopt;
    return std::make_pair(key, strip(text.substr(i + 1)));
}

// An entry of a header: the index of its line, its key and its value.
struct Entry {
    size_t line;
    std::string key, value;
};

// A parsed header: its lines, the index of the record line (nullopt if it
// has none), the indices of the info strings, and the entries in file order.
struct ParsedHeader {
    std::vector<Line> lines;
    std::optional<size_t> rec;
    std::vector<size_t> info;
    std::vector<Entry> entries;

    explicit ParsedHeader(const std::string &data) : lines(split_lines(data))
    {
        for (size_t i = 0; i < lines.size(); i++)
            if (!starts_with_hash(lines[i].content)) {
                rec = i;
                break;
            }
        if (!rec) return;
        for (size_t i = *rec + 1; i < lines.size(); i++) {
            const std::string &c = lines[i].content;
            if (!starts_with_hash(c)) continue;
            info.push_back(i);
            if (auto e = entry_of(c)) entries.push_back({i, e->first, e->second});
        }
    }

    // The line indices of the entries whose key is `key`, ignoring letter
    // case.
    std::vector<size_t> matches(const std::string &key) const
    {
        std::string f = fold(key);
        std::vector<size_t> idx;
        for (const Entry &e : entries)
            if (fold(e.key) == f) idx.push_back(e.line);
        return idx;
    }

    // The line ending of new lines: that of the record line, or of the
    // first line that has one, or DEFAULT_EOL.
    std::string eol() const
    {
        if (rec && !lines[*rec].eol.empty()) return lines[*rec].eol;
        for (const Line &l : lines)
            if (!l.eol.empty()) return l.eol;
        return DEFAULT_EOL;
    }

    // The index at which a new entry is inserted: after the last info
    // string, or after the last line that is not blank.
    size_t insertion_point() const
    {
        if (!info.empty()) return info.back() + 1;
        for (size_t i = lines.size(); i > 0; i--)
            if (!strip(lines[i - 1].content).empty()) return i;
        return lines.size();
    }

    std::string bytes() const
    {
        std::string out;
        for (const Line &l : lines) out += l.content + l.eol;
        return out;
    }
};

// The line numbers (from 1) of the line indices `idx`, as "3, 7".
std::string line_numbers(const std::vector<size_t> &idx)
{
    std::string s;
    for (size_t i : idx) {
        if (!s.empty()) s += ", ";
        s += std::to_string(i + 1);
    }
    return s;
}

// The entries of `hdr`, one per key (the first); a warning (wfdb_error) for
// each key that has more than one.
Metadata unique_entries(const ParsedHeader &hdr, const std::string &record)
{
    struct Seen {
        std::string folded, key;
        std::vector<size_t> lines;
    };
    std::vector<Seen> seen;
    Metadata out;
    for (const Entry &e : hdr.entries) {
        std::string f = fold(e.key);
        bool dup = false;
        for (Seen &s : seen)
            if (s.folded == f) {
                s.lines.push_back(e.line);
                dup = true;
                break;
            }
        if (dup) continue;
        seen.push_back({f, e.key, {e.line}});
        out.emplace_back(e.key, e.value);
    }
    for (const Seen &s : seen)
        if (s.lines.size() > 1)
            wfdb_error("WFDB-x: header of record %s has more than one entry "
                       "for key %s (lines %s); the first is used\n",
                       record.c_str(), s.key.c_str(),
                       line_numbers(s.lines).c_str());
    return out;
}

// ---------------------------------------------------------------------------
// Arguments

// `s` in single quotes, with CR, LF, tab, NUL and backslash written as
// escapes (as in the Python messages), for an error message.
std::string quote_text(const std::string &s)
{
    std::string q = "'";
    for (char c : s) {
        switch (c) {
        case '\r': q += "\\r"; break;
        case '\n': q += "\\n"; break;
        case '\t': q += "\\t"; break;
        case '\0': q += "\\x00"; break;
        case '\\': q += "\\\\"; break;
        default: q += c;
        }
    }
    return q + "'";
}

// The name, in an error message, of a character that a key or value must
// not contain.
const char *forbidden_name(char c)
{
    switch (c) {
    case ':': return "':'";
    case '#': return "'#'";
    case '\0': return "a NUL character";
    default: return "a line break";
    }
}

// `key` without the characters of TRIM at either end, checked.
std::string check_key(const std::string &key)
{
    std::string k = strip(key);
    if (k.empty()) throw ArgumentError("metadata key must not be empty");
    for (char c : {':', '#', '\r', '\n', '\0'})
        if (k.find(c) != std::string::npos)
            throw ArgumentError("metadata key " + quote_text(key) +
                                " must not contain " + forbidden_name(c));
    return k;
}

// `value` (of the key `key`, as given) without the characters of TRIM at
// either end, checked.
std::string check_value(const std::string &key, const std::string &value)
{
    std::string v = strip(value);
    for (char c : {'\r', '\n', '\0'})
        if (v.find(c) != std::string::npos)
            throw ArgumentError("value of metadata key " + quote_text(key) +
                                " must not contain " + forbidden_name(c));
    return v;
}

// The info string of an entry, as written: "# Key: value" ("# Key:" if the
// value is empty).
std::string entry_line(const std::string &key, const std::string &value)
{
    return "# " + key + ":" + (value.empty() ? "" : " " + value);
}

using Change = std::pair<std::string, std::optional<std::string>>;

// `changes`, checked: valid keys and values (without spaces at either end),
// and no two keys that differ only in letter case.
std::vector<Change> check_changes(const MetadataChanges &changes)
{
    std::vector<Change> out;
    std::vector<std::string> seen;
    for (const auto &c : changes) {
        std::string k = check_key(c.first);
        std::string f = fold(k);
        for (const std::string &s : seen)
            if (s == f)
                throw ArgumentError("metadata key " + quote_text(c.first) +
                                    " is given more than once (keys are "
                                    "compared without regard to letter "
                                    "case)");
        seen.push_back(f);
        out.emplace_back(k, c.second ? std::optional<std::string>(
                                           check_value(c.first, *c.second))
                                     : std::nullopt);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Files

bool is_url(const std::string &s)
{
    return s.compare(0, 7, "http://") == 0 || s.compare(0, 8, "https://") == 0;
}

// The record name to open (without a trailing ".hea"), checked.
std::string record_name(const std::string &record)
{
    if (record.empty()) throw ArgumentError("record name must not be empty");
    if (record == "-")
        throw ArgumentError("the metadata of a header read from the standard "
                            "input cannot be read or changed");
    return detail::wfdb_striphea(record.c_str());
}

// A header as read: its bytes, the name of the file it was read from, and
// whether that is a URL.
struct HeaderFile {
    std::string data, path;
    bool url = false;
};

// Read the header of `record` as the library opens it (wfdb_open with type
// "hea"), with the current input settings.  Throws FileError if it cannot be
// opened or read.
HeaderFile read_file(const std::string &record)
{
    std::string name = record_name(record);
    detail::FilePtr f = detail::wfdb_open("hea", name.c_str(), WFDB_READ);
    if (!f) throw FileError("can't read header for record " + record);
    HeaderFile h;
    h.path = detail::wfdb_filename();
    char buf[65536];
    size_t k;
    while ((k = f->read(buf, 1, sizeof buf)) > 0) h.data.append(buf, k);
    bool bad = f->error() != 0;
    f->close();
    if (bad) throw FileError("can't read header for record " + record);
    h.url = is_url(h.path);
    return h;
}

// The library's input directory and network access set from `in` (the
// options that are set) for the lifetime of the object, as the InputScope of
// record.cpp does.
class InputSettings {
public:
    explicit InputSettings(const InputOptions &in) : in_(in)
    {
        if (in_.input_dir) prev_dir_ = wfdbx_set_input_dir(in_.input_dir->c_str());
        if (in_.network) prev_net_ = wfdbx_set_network(*in_.network ? 1 : 0);
    }
    ~InputSettings()
    {
        if (in_.network) wfdbx_set_network(prev_net_);
        if (in_.input_dir)
            wfdbx_set_input_dir(prev_dir_ ? prev_dir_->c_str() : nullptr);
    }
    InputSettings(const InputSettings &) = delete;
    InputSettings &operator=(const InputSettings &) = delete;
private:
    InputOptions in_;
    std::optional<std::string> prev_dir_;
    int prev_net_ = 0;
};

HeaderFile read_with(const std::string &record, const InputOptions &in)
{
    InputSettings settings(in);
    return read_file(record);
}

// The file to which a changed header is written: the file read, or, with
// `dir`, the file of the same name in `dir` (which must exist).
std::string destination(const std::string &record, const HeaderFile &h,
                        const std::string &dir)
{
    if (dir.empty()) {
        if (h.url)
            throw ArgumentError("header of record " + record + " was read "
                                "from a URL, and cannot be changed (give dir "
                                "to write the changed header to a local "
                                "directory)");
        return h.path;
    }
    std::string d = detail::wfdbx_expand_home(dir);
    std::error_code ec;
    if (!fs::is_directory(d, ec))
        throw FileError("directory " + dir + " does not exist");
    size_t p = h.path.find_last_of("/\\");
    std::string base = p == std::string::npos ? h.path : h.path.substr(p + 1);
    if (d.back() == '/' || d.back() == '\\') return d + base;
    return d + "/" + base;
}

#if !defined(_WIN32)
mode_t current_umask()
{
    mode_t m = umask(0);
    umask(m);
    return m;
}
#endif

// Create a new temporary file in the directory part `dirpart` of a
// destination (a name beginning with "." + `base`); returns its descriptor
// (-1 on failure) and sets `name`.
int create_temp(const std::string &dirpart, const std::string &base,
                std::string &name)
{
#if defined(_WIN32)
    std::random_device rd;
    for (int attempt = 0; attempt < 100; attempt++) {
        char suffix[16];
        std::snprintf(suffix, sizeof suffix, "%08x", static_cast<unsigned>(rd()));
        name = dirpart + "." + base + "." + suffix + ".tmp";
        int fd = -1;
        if (_sopen_s(&fd, name.c_str(),
                     _O_WRONLY | _O_CREAT | _O_EXCL | _O_BINARY, _SH_DENYNO,
                     _S_IREAD | _S_IWRITE) == 0)
            return fd;
        if (errno != EEXIST) return -1;
    }
    return -1;
#else
    std::string tmpl = dirpart + "." + base + ".XXXXXX";
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');
    int fd = mkstemp(buf.data());
    if (fd >= 0) name = buf.data();
    return fd;
#endif
}

// Write all of `data` to the file descriptor `fd`, and flush it to the disk.
bool write_all(int fd, const std::string &data)
{
    size_t off = 0;
    while (off < data.size()) {
#if defined(_WIN32)
        int w = _write(fd, data.data() + off,
                       static_cast<unsigned>(std::min<size_t>(data.size() - off,
                                                              1 << 30)));
#else
        ssize_t w = ::write(fd, data.data() + off, data.size() - off);
#endif
        if (w < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        off += static_cast<size_t>(w);
    }
#if defined(_WIN32)
    return _commit(fd) == 0;
#else
    return fsync(fd) == 0;
#endif
}

int close_fd(int fd)
{
#if defined(_WIN32)
    return _close(fd);
#else
    return ::close(fd);
#endif
}

// Write `data` to `dest` through a temporary file in the same directory,
// which then replaces `dest`, with the permissions of `dest` (or, if it does
// not exist, those of a new file).  The temporary file is removed on any
// failure.  Throws FileError on failure.
void write_file(const std::string &dest, const std::string &data,
                const std::string &record)
{
    const std::string error = "can't write header for record " + record;
    std::string dirpart = detail::wfdbx_dirname(dest);
    std::string base = dest.substr(dirpart.size());
    std::string tmp;
    int fd = create_temp(dirpart, base, tmp);
    if (fd < 0) throw FileError(error);
    bool ok = write_all(fd, data);
    ok = close_fd(fd) == 0 && ok;
    std::error_code ec;
    if (ok) {
        fs::file_status st = fs::status(dest, ec);
        if (!ec && fs::exists(st)) {
            fs::permissions(tmp, st.permissions() & fs::perms::mask, ec);
        } else {
            ec.clear();
#if !defined(_WIN32)
            fs::permissions(tmp, static_cast<fs::perms>(0666 & ~current_umask()),
                            ec);
#endif
        }
        ok = !ec;
    }
    if (ok) {
        fs::rename(tmp, dest, ec);
        ok = !ec;
    }
    if (!ok) {
        std::remove(tmp.c_str());
        throw FileError(error);
    }
}

// Apply `changes` (checked) to the header of `record`; returns the number of
// lines removed.
int change(const std::string &record, const std::vector<Change> &changes,
           const MetadataOptions &opt)
{
    HeaderFile h = read_with(record, opt);
    std::string dest = destination(record, h, opt.dir);
    ParsedHeader hdr(h.data);
    if (!hdr.rec)
        throw ArgumentError("header of record " + record +
                            " has no record line");
    // (every change is checked before the header is changed)
    for (const Change &c : changes) {
        std::vector<size_t> idx = hdr.matches(c.first);
        if (c.second && idx.size() > 1)
            throw ArgumentError("header of record " + record + " has more "
                                "than one entry for key " + c.first +
                                " (lines " + line_numbers(idx) +
                                "); remove them first");
    }
    int removed = 0;
    for (const Change &c : changes) {
        std::vector<size_t> idx = hdr.matches(c.first);
        if (!c.second) {
            for (size_t j = idx.size(); j > 0; j--)
                hdr.lines.erase(hdr.lines.begin() +
                                static_cast<std::ptrdiff_t>(idx[j - 1]));
            removed += static_cast<int>(idx.size());
        } else if (!idx.empty()) {
            hdr.lines[idx[0]].content = entry_line(c.first, *c.second);
        } else {
            std::string eol = hdr.eol();
            size_t at = hdr.insertion_point();
            if (at > 0 && hdr.lines[at - 1].eol.empty())
                hdr.lines[at - 1].eol = eol;
            hdr.lines.insert(hdr.lines.begin() + static_cast<std::ptrdiff_t>(at),
                             Line{entry_line(c.first, *c.second), eol});
        }
        hdr = ParsedHeader(hdr.bytes());
    }
    std::string out = hdr.bytes();
    if (out != h.data || !opt.dir.empty()) write_file(dest, out, record);
    return removed;
}

} // namespace

// ---------------------------------------------------------------------------
// The public functions

Metadata read_metadata(const std::string &record, const InputOptions &input)
{
    HeaderFile h = read_with(record, input);
    return unique_entries(ParsedHeader(h.data), record);
}

std::optional<std::string> get_metadata(const std::string &record,
                                        const std::string &key,
                                        const InputOptions &input)
{
    std::string f = fold(check_key(key));
    for (const auto &e : read_metadata(record, input))
        if (fold(e.first) == f) return e.second;
    return std::nullopt;
}

void set_metadata(const std::string &record, const std::string &key,
                  const std::string &value, const MetadataOptions &opt)
{
    std::string k = check_key(key);
    change(record, {{k, check_value(key, value)}}, opt);
}

int remove_metadata(const std::string &record, const std::string &key,
                    const MetadataOptions &opt)
{
    return change(record, {{check_key(key), std::nullopt}}, opt);
}

void update_metadata(const std::string &record, const MetadataChanges &changes,
                     const MetadataOptions &opt)
{
    change(record, check_changes(changes), opt);
}

namespace detail {

std::vector<std::string> wfdbx_metadata_info_lines(
    const Metadata &metadata, const std::vector<std::string> &comments)
{
    MetadataChanges changes;
    for (const auto &e : metadata) changes.emplace_back(e.first, e.second);
    std::vector<Change> entries = check_changes(changes);
    std::vector<std::string> folded;
    for (const Change &e : entries) folded.push_back(fold(e.first));
    for (const std::string &c : comments) {
        auto e = entry_of("#" + c);
        if (!e) continue;
        std::string f = fold(e->first);
        for (const std::string &k : folded)
            if (k == f)
                throw ArgumentError("metadata key " + quote_text(e->first) +
                                    " is also given in comments");
    }
    std::vector<std::string> lines;
    for (const Change &e : entries)
        lines.push_back(entry_line(e.first, *e.second).substr(1));
    return lines;
}

} // namespace detail

} // namespace wfdbx
