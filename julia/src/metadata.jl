# metadata.jl: header metadata: "Key: value" info strings in the header of a
# record (read_metadata, get_metadata, set_metadata, remove_metadata,
# update_metadata), and the metadata of read_header and write_record.
#
# The info strings of a header are its comment lines (lines that begin with
# '#') after the record line, as the C function getinfo() reads them. Many
# datasets store facts about the recording in them as "Key: value" pairs,
# for example:
#
#     # Age: 63
#     # Sex: F
#     # Dx: 164889003
#
# Rules (the same in every implementation of WFDB-x; see
# tests/metadata/README.md):
#
# * Lines. A header is split after each line feed (LF). Each line has a line
#   ending: CR LF, LF, or none (the last line of a file that does not end
#   with a line feed). The content of a line is the line without its ending.
# * Reading. The record line is the first line whose content does not begin
#   with '#'; the comment lines before it are not info strings, and are
#   never read or changed. Every later line that begins with '#' is an info
#   string (so a comment between two signal lines is one too). An info
#   string is an entry if it contains a colon: the key is the text between
#   the '#' and the first colon, the value the rest of the line, each without
#   the spaces, tabs, VT, FF and CR at either end. So "#Age:45", "# Age: 45"
#   and "#  Age : 45" all give "Age" => "45". An info string without a colon,
#   or whose key is empty or contains '#', is a free comment: it is not
#   returned, and it is never changed. Only the header file (.hea) is read,
#   not the .info file that getinfo() also reads.
# * Keys are compared without regard to letter case (A-Z and a-z only), so
#   get_metadata(record, "age") finds "Age". If a header holds two entries
#   whose keys differ only in letter case (a file written by other
#   software), reading returns the first, with a warning (@warn);
#   set_metadata and update_metadata refuse to change that key, and
#   remove_metadata removes all of them. A key must not be empty, and must
#   not contain ':', '#', a line break (CR or LF) or a NUL byte; it may
#   contain spaces, as in "Date of birth".
# * Values are text, which may be a whole sentence, without a line break or
#   a NUL byte; the spaces at either end are removed, and the empty value is
#   allowed. Keys and values are bytes, as all the text of a header in
#   WFDB-x (a String argument is taken as its bytes, as given).
# * Writing. An entry is written as "# Key: value" ("# Key:" if the value is
#   empty), with the caller's spelling of the key. A changed entry replaces
#   its line, at the same position, keeping its line ending; a new entry is
#   inserted after the last info string, or, if the header has none, after
#   its last line that is not blank, ending as the record line does (CR LF
#   in the headers written by WFDB). Every other byte of the header is kept.
#   The new header is written to a temporary file in the directory of the
#   destination, which then replaces it (rename), keeping its permissions,
#   so that an error never leaves a partly written header. All the arguments
#   are checked before the header is read, and every change before anything
#   is written. If nothing changes (and dir is not given), nothing is
#   written.
# * Which file. The header is opened as the library opens the header of a
#   record (wfdb_open with type "hea", after removing a trailing ".hea"):
#   under the input directory, or as given for a full path, a ~ path or a
#   URL (only if network access is on). A change is written to the header
#   that was read, or, with dir, to a header of the same name in the
#   directory dir (which must exist), leaving the original unchanged (the
#   signal files are not copied). A header read from a URL can only be
#   written elsewhere, with dir. Only the named header is read or changed:
#   for a multi-segment record, that is the master header, unless the name
#   of a segment is given.
#
# Errors: an invalid argument (an invalid key or value, an empty record name
# or "-", two keys that differ only in letter case in update_metadata, a
# header with more than one entry for a key to set, a header with no record
# line, a header read from a URL without dir) throws an ArgumentError; a
# header that cannot be read or written, or a dir that does not exist,
# throws a WfdbError.
#
# Metadata often holds information about patients. WFDB-x stores it as
# plain text, exactly as given, and does not de-identify it.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 2.1 of the License, or (at
# your option) any later version. See LICENSE.

const _MD_DEFAULT_EOL = b"\r\n"     # line ending of the headers written by WFDB

# ---------------------------------------------------------------------------
# Parsing

# One line of a header: its content (without the line ending) and its line
# ending (CR LF, LF, or empty for a last line without one).
mutable struct _MdLine
    content::Vector{UInt8}
    eol::Vector{UInt8}
end

# A space removed from both ends of keys and values: space, tab, VT, FF, CR.
_md_trimmed(c::UInt8) = c == 0x20 || c == 0x09 || c == 0x0b || c == 0x0c || c == 0x0d

# b without the spaces, tabs, VT, FF and CR at either end.
function _md_trim(b::AbstractVector{UInt8})
    i = firstindex(b)
    j = lastindex(b)
    while i <= j && _md_trimmed(b[i])
        i += 1
    end
    while j >= i && _md_trimmed(b[j])
        j -= 1
    end
    Vector{UInt8}(b[i:j])
end

# key with the letters A-Z changed to a-z (no other byte is changed).
_md_fold(key::AbstractVector{UInt8}) =
    UInt8[UInt8('A') <= c <= UInt8('Z') ? c + 0x20 : c for c in key]

# The lines of data, split after each LF.
function _md_split_lines(data::Vector{UInt8})
    lines = _MdLine[]
    start = 1
    n = length(data)
    while start <= n
        i = findnext(==(UInt8('\n')), data, start)
        if i === nothing
            push!(lines, _MdLine(data[start:n], UInt8[]))
            break
        end
        if i > start && data[i-1] == UInt8('\r')
            push!(lines, _MdLine(data[start:i-2], Vector{UInt8}(b"\r\n")))
        else
            push!(lines, _MdLine(data[start:i-1], Vector{UInt8}(b"\n")))
        end
        start = i + 1
    end
    lines
end

_md_comment(c::Vector{UInt8}) = !isempty(c) && c[1] == UInt8('#')

# (key, value) of an info string (content beginning with '#'), or nothing
# if it is a free comment.
function _md_entry(content::AbstractVector{UInt8})
    i = findnext(==(UInt8(':')), content, 2)
    i === nothing && return nothing
    key = _md_trim(view(content, 2:i-1))
    (isempty(key) || UInt8('#') in key) && return nothing
    (key, _md_trim(view(content, i+1:length(content))))
end

# A parsed header: its lines, the index of the record line (0 if none), the
# indices of the info strings, and the entries as (line index, key, value)
# in file order.
struct _MdHeader
    lines::Vector{_MdLine}
    rec::Int
    info::Vector{Int}
    entries::Vector{Tuple{Int,Vector{UInt8},Vector{UInt8}}}
end

function _MdHeader(data::Vector{UInt8})
    lines = _md_split_lines(data)
    rec = 0
    for (i, ln) in enumerate(lines)
        if !_md_comment(ln.content)
            rec = i
            break
        end
    end
    info = Int[]
    entries = Tuple{Int,Vector{UInt8},Vector{UInt8}}[]
    if rec > 0
        for i in rec+1:length(lines)
            c = lines[i].content
            _md_comment(c) || continue
            push!(info, i)
            e = _md_entry(c)
            e === nothing || push!(entries, (i, e[1], e[2]))
        end
    end
    _MdHeader(lines, rec, info, entries)
end

_md_bytes(h::_MdHeader) = _md_join(h.lines)
function _md_join(lines::Vector{_MdLine})
    out = UInt8[]
    for ln in lines
        append!(out, ln.content)
        append!(out, ln.eol)
    end
    out
end

# The line indices of the entries of h whose key is key, ignoring letter
# case.
function _md_matches(h::_MdHeader, key::Vector{UInt8})
    f = _md_fold(key)
    Int[i for (i, k, _) in h.entries if _md_fold(k) == f]
end

# The line ending of new lines: that of the record line, or of the first
# line that has one, or CR LF.
function _md_eol(h::_MdHeader)
    (h.rec > 0 && !isempty(h.lines[h.rec].eol)) && return copy(h.lines[h.rec].eol)
    for ln in h.lines
        isempty(ln.eol) || return copy(ln.eol)
    end
    Vector{UInt8}(_MD_DEFAULT_EOL)
end

# The index before which new entries are inserted: after the last info
# string, or after the last line that is not blank.
function _md_insertion_point(h::_MdHeader)
    isempty(h.info) || return h.info[end] + 1
    for i in length(h.lines):-1:1
        isempty(_md_trim(h.lines[i].content)) || return i + 1
    end
    length(h.lines) + 1
end

_md_text(b::AbstractVector{UInt8}) = String(copy(b))
_md_quote(x::ByteStr) = repr(_md_text(bytes(x)))
_md_lines_list(idx::Vector{Int}) = join(string.(idx), ", ")

# The entries of h as key => value pairs, one per key (the first); a warning
# for each key that has more than one.
function _md_unique_entries(h::_MdHeader, record::String)
    seen = Dict{Vector{UInt8},Int}()          # folded key => index in groups
    groups = Tuple{Vector{UInt8},Vector{Int}}[]
    out = MetadataEntry[]
    for (i, k, v) in h.entries
        f = _md_fold(k)
        g = get(seen, f, 0)
        if g > 0
            push!(groups[g][2], i)
            continue
        end
        push!(groups, (k, [i]))
        seen[f] = length(groups)
        push!(out, k => v)
    end
    for (k, idx) in groups
        length(idx) > 1 &&
            @warn "header of record $record has more than one entry for key $(_md_text(k)) (lines $(_md_lines_list(idx))); the first is used"
    end
    out
end

# ---------------------------------------------------------------------------
# Arguments

function _md_forbidden(c::UInt8)
    c == UInt8(':') && return "':'"
    c == UInt8('#') && return "'#'"
    (c == UInt8('\r') || c == UInt8('\n')) && return "a line break"
    c == 0x00 && return "a NUL character"
    nothing
end

# key as bytes, without spaces at either end, checked (ArgumentError).
function _md_check_key(key::ByteStr)
    k = _md_trim(bytes(key))
    isempty(k) && throw(ArgumentError("metadata key must not be empty"))
    for c in (UInt8(':'), UInt8('#'), UInt8('\r'), UInt8('\n'), 0x00)
        c in k && throw(ArgumentError("metadata key $(_md_quote(key)) must not contain $(_md_forbidden(c))"))
    end
    k
end

# value as bytes, without spaces at either end, checked (ArgumentError).
function _md_check_value(key::ByteStr, value::ByteStr)
    v = _md_trim(bytes(value))
    for c in (UInt8('\r'), UInt8('\n'), 0x00)
        c in v && throw(ArgumentError("value of metadata key $(_md_quote(key)) must not contain $(_md_forbidden(c))"))
    end
    v
end

# The info string of an entry, as written: "# Key: value" ("# Key:" if the
# value is empty).
function _md_line(key::Vector{UInt8}, value::Vector{UInt8})
    out = UInt8[UInt8('#'), UInt8(' ')]
    append!(out, key)
    push!(out, UInt8(':'))
    if !isempty(value)
        push!(out, UInt8(' '))
        append!(out, value)
    end
    out
end

const _MD_CHANGES_ERROR = "metadata must be a dictionary, or a vector of key => value pairs"

# The (key, value) of one item of a collection of changes.
_md_item(p::Pair) = (p.first, p.second)
_md_item(t::Tuple) = length(t) == 2 ? (t[1], t[2]) : throw(ArgumentError(_MD_CHANGES_ERROR))
_md_item(_) = throw(ArgumentError(_MD_CHANGES_ERROR))

# changes (a dictionary, or a vector or tuple of key => value pairs or
# (key, value) tuples) as a list of (key, value or nothing), checked: valid
# keys and values, and no two keys that differ only in letter case.
function _md_check_changes(changes)
    (changes isa AbstractDict || changes isa AbstractVector || changes isa Tuple) ||
        throw(ArgumentError(_MD_CHANGES_ERROR))
    (changes isa AbstractVector{UInt8}) && throw(ArgumentError(_MD_CHANGES_ERROR))
    out = Tuple{Vector{UInt8},Union{Nothing,Vector{UInt8}}}[]
    seen = Set{Vector{UInt8}}()
    for item in changes
        key, value = _md_item(item)
        key isa ByteStr || throw(ArgumentError("metadata key must be a string"))
        (value === nothing || value isa ByteStr) ||
            throw(ArgumentError("value of metadata key $(_md_quote(key)) must be a string or nothing"))
        k = _md_check_key(key)
        f = _md_fold(k)
        f in seen &&
            throw(ArgumentError("metadata key $(_md_quote(key)) is given more than once (keys are compared without regard to letter case)"))
        push!(seen, f)
        push!(out, (k, value === nothing ? nothing : _md_check_value(key, value)))
    end
    out
end

# The info strings (as putinfo takes them: without the '#') of the entries
# of metadata, for write_record: " Key: value". Throws an ArgumentError if an
# entry is invalid, if two keys differ only in letter case, if a value is
# nothing, or if one of comments (the other info strings) is already an
# entry for one of these keys.
function _md_info_lines(metadata, comments)
    entries = _md_check_changes(metadata)
    folded = Set{Vector{UInt8}}(_md_fold(k) for (k, _) in entries)
    for (k, v) in entries
        v === nothing &&
            throw(ArgumentError("value of metadata key $(_md_quote(k)) must not be nothing"))
    end
    for c in comments
        e = _md_entry(UInt8[UInt8('#'); bytes(c)])
        (e !== nothing && _md_fold(e[1]) in folded) &&
            throw(ArgumentError("metadata key $(_md_quote(e[1])) is also given in comments"))
    end
    Vector{UInt8}[_md_line(k, something(v))[2:end] for (k, v) in entries]
end

# ---------------------------------------------------------------------------
# Files

# True if record names the standard input ("-", or "-.hea").
_md_is_stdin(record::ByteStr) = wfdb_striphea(record) == b"-"

# The record name without a trailing ".hea", checked.
function _md_record_name(record::ByteStr)
    r = cstr(bytes(record))
    isempty(r) && throw(ArgumentError("record name must not be empty"))
    name = wfdb_striphea(r)
    name == b"-" &&
        throw(ArgumentError("the metadata of a header read from the standard input cannot be read or changed"))
    name
end

# (bytes of the header, name of the file it was read from, true if that is a
# URL). Throws a WfdbError if the header cannot be read.
function _md_read(w::Wfdb, record::ByteStr)
    name = _md_record_name(record)
    f = wfdb_open(w, "hea", name, WFDB_READ)
    f === nothing && throw(WfdbError("can't read header for record $(_lossy(record))"))
    path = copy(w.io.filename)
    data = read_to_end(f)
    failed = ferror(f)
    fclose(f)
    failed && throw(WfdbError("can't read header for record $(_lossy(record))"))
    (data, path, _is_url(path))
end

# The file to which a changed header is written.
function _md_destination(w::Wfdb, record::ByteStr, path::Vector{UInt8}, is_url::Bool, dir)
    d = dir === nothing ? UInt8[] : cstr(bytes(dir))
    if isempty(d)
        is_url && throw(ArgumentError("header of record $(_lossy(record)) was read from a URL, and cannot be changed (give dir to write the changed header to a local directory)"))
        return String(copy(path))
    end
    dd = String(copy(_expand_home(copy(d))))
    isdir(dd) || throw(WfdbError("directory $(_md_text(d)) does not exist"))
    i = length(path)
    while i > 0 && path[i] != UInt8('/') && path[i] != UInt8('\\')
        i -= 1
    end
    joinpath(dd, String(path[i+1:end]))
end

# The process's file creation mask (0 on Windows, which has none).
function _md_umask()
    Sys.iswindows() && return UInt32(0)
    m = ccall(:umask, UInt32, (UInt32,), 0)
    ccall(:umask, UInt32, (UInt32,), m)
    m
end

# Rename src to dst, replacing dst (in one step where the platform allows).
function _md_rename(src::String, dst::String)
    @static if isdefined(Base.Filesystem, :rename)
        Base.Filesystem.rename(src, dst)
    else
        r = ccall(:jl_fs_rename, Int32, (Cstring, Cstring), src, dst)
        r < 0 && throw(Base.IOError("rename($(repr(src)), $(repr(dst)))", r))
    end
    nothing
end

# The file descriptor of io, as a C int.
function _md_fd(io::IOStream)
    x = fd(io)
    x isa Integer ? Cint(x) : reinterpret(Cint, x)   # (a RawFD in recent versions)
end

# Write data to dest through a temporary file in the same directory, which
# then replaces dest (keeping its permissions). The temporary file is
# removed on any failure.
function _md_write(dest::String, data::Vector{UInt8}, record::ByteStr)
    msg = "can't write header for record $(_lossy(record))"
    d = dirname(dest)
    isempty(d) && (d = ".")
    tmp, io = try
        mktemp(d; cleanup=false)
    catch e
        e isa InterruptException && rethrow()
        throw(WfdbError(msg))
    end
    try
        write(io, data)
        flush(io)
        Sys.iswindows() || ccall(:fsync, Cint, (Cint,), _md_fd(io)) == 0 ||
            error("fsync failed")
        close(io)
        st = stat(dest)
        chmod(tmp, ispath(st) ? (filemode(st) & 0o7777) : (0o666 & ~_md_umask()))
        _md_rename(tmp, dest)
    catch e
        isopen(io) && close(io)
        rm(tmp; force=true)
        e isa InterruptException && rethrow()
        throw(WfdbError(msg))
    end
    nothing
end

# Apply changes (a checked list of (key, value or nothing)) to the header of
# record; returns the number of lines removed.
function _md_change(w::Wfdb, record::ByteStr, changes, input_dir, network, dir)
    data, path, is_url = _with_input_options(() -> _md_read(w, record), w, input_dir, network)
    dest = _md_destination(w, record, path, is_url, dir)
    h = _MdHeader(data)
    h.rec == 0 && throw(ArgumentError("header of record $(_lossy(record)) has no record line"))
    # (every change is checked before the header is changed)
    for (k, v) in changes
        idx = _md_matches(h, k)
        (v !== nothing && length(idx) > 1) &&
            throw(ArgumentError("header of record $(_lossy(record)) has more than one entry for key $(_md_text(k)) (lines $(_md_lines_list(idx))); remove them first"))
    end
    removed = 0
    for (k, v) in changes
        idx = _md_matches(h, k)
        if v === nothing
            lines = h.lines
            for i in sort(idx; rev=true)
                deleteat!(lines, i)
            end
            h = _MdHeader(_md_join(lines))
            removed += length(idx)
        elseif !isempty(idx)
            ln = h.lines[idx[1]]
            h.lines[idx[1]] = _MdLine(_md_line(k, v), ln.eol)
            h = _MdHeader(_md_bytes(h))
        else
            eol = _md_eol(h)
            at = _md_insertion_point(h)
            (at > 1 && isempty(h.lines[at-1].eol)) && (h.lines[at-1].eol = copy(eol))
            insert!(h.lines, at, _MdLine(_md_line(k, v), eol))
            h = _MdHeader(_md_bytes(h))
        end
    end
    out = _md_bytes(h)
    hasdir = dir !== nothing && !isempty(cstr(bytes(dir)))
    (out != data || hasdir) && _md_write(dest, out, record)
    removed
end

# The entries of the header of record, as read_metadata returns them, with
# the library's current input settings (for read_header).
function _header_metadata(w::Wfdb, record::ByteStr)
    data, _, _ = _md_read(w, record)
    _md_unique_entries(_MdHeader(data), _lossy(record))
end

# ---------------------------------------------------------------------------
# The public functions

const _MD_DIR_DOC = """
- `dir`: an existing directory in which to write the changed header, under
  the same file name, instead of changing the header itself (the signal
  files are not copied). `nothing` or `""`, the default, changes the header
  that was read."""

const _MD_THROWS_DOC = """
Throws an `ArgumentError` if `record` is empty or `"-"` (the standard
input), if `key` or `value` is not valid, if the header has more than one
entry for a key to be set (`"header of record REC has more than one entry
for key KEY (lines N, M); remove them first"`), if it has no record line,
or if it was read from a URL and `dir` is not given. Throws a
[`WfdbError`](@ref) if the header cannot be read (`"can't read header for
record REC"`), if the changed header cannot be written (`"can't write
header for record REC"`), or if `dir` does not exist (`"directory DIR does
not exist"`).

The arguments are checked before the header is read, and every change
before anything is written. The header is replaced in one step (through a
temporary file in its directory, which then replaces it, keeping its
permissions), so that an error leaves it unchanged. If nothing changes,
nothing is written (unless `dir` is given)."""

"""
    read_metadata([w::Wfdb], record; input_dir=nothing, network=nothing)
        -> Vector{Pair{Vector{UInt8},Vector{UInt8}}}

Read the metadata of a record: the `Key: value` entries of its header.

An entry is an info string (a comment line after the record line, as
[`getinfo`](@ref) reads it) that contains a colon. The key is the text
between the `#` and the first colon, and the value is the rest of the line,
each without the spaces and tabs at either end: `#Age:45`, `# Age: 45` and
`#  Age : 45` all give `"Age" => "45"`. An info string without a colon, or
whose key is empty or contains `#`, is a free comment, which is not
returned. Comment lines before the record line are not info strings. Only
the header file (`.hea`) is read, not the `.info` file that `getinfo` also
reads.

$_RECORD_DOC

# Keyword arguments
$_INPUT_DOC

Returns the entries as `key => value` pairs of bytes, in file order. Keys
are compared without regard to letter case (A-Z and a-z): a key that
appears more than once is returned once, with its first value, and a
warning is logged (`@warn`: `"header of record REC has more than one entry
for key KEY (lines N, M); the first is used"`).

Throws a [`WfdbError`](@ref) if the header cannot be found or read
(`"can't read header for record REC"`), and an `ArgumentError` if `record`
is empty or `"-"`.

# Examples
The record `rec` is in the input directory; its header holds the lines
`# Age: 63` and `# Sex: F`:
```julia-repl
julia> [String(k) => String(v) for (k, v) in read_metadata("rec")]
2-element Vector{Pair{String, String}}:
 "Age" => "63"
 "Sex" => "F"
```

Metadata often holds information about patients. WFDB-x stores it as plain
text, exactly as given, and does not de-identify it.

Part of WFDB-x; not in the original WFDB package.
"""
function read_metadata(w::Wfdb, record::ByteStr; input_dir::OptByteStr=nothing,
                       network::Union{Nothing,Bool}=nothing)
    _with_input_options(() -> _header_metadata(w, record), w, input_dir, network)
end
read_metadata(record::ByteStr; kw...) = read_metadata(lib(), record; kw...)

"""
    get_metadata([w::Wfdb], record, key; input_dir=nothing, network=nothing)
        -> Union{Vector{UInt8},Nothing}

Return the value of the metadata entry `key` of a record (see
[`read_metadata`](@ref)), as bytes, or `nothing` if the header has no entry
for `key`. Letter case (A-Z and a-z) is ignored, and the spaces at either
end of `key` are removed: `"age"` finds `Age`. An entry with an empty value
gives an empty vector. If the header has more than one entry for `key`, the
first is returned; as in `read_metadata`, a warning is logged for each key
of the header that has more than one entry.

# Arguments
- `record`: a record name (see [`read_metadata`](@ref)).
- `key`: the key, such as `"Age"` (see [`set_metadata`](@ref) for the
  valid keys).

# Keyword arguments
$_INPUT_DOC

Throws a [`WfdbError`](@ref) if the header cannot be found or read, and an
`ArgumentError` if `record` is empty or `"-"`, or if `key` is not a valid
key (checked before the header is read).

# Examples
```julia-repl
julia> String(get_metadata("rec", "age"))
"63"

julia> get_metadata("rec", "Weight") === nothing
true
```

Part of WFDB-x; not in the original WFDB package.
"""
function get_metadata(w::Wfdb, record::ByteStr, key::ByteStr; input_dir::OptByteStr=nothing,
                      network::Union{Nothing,Bool}=nothing)
    f = _md_fold(_md_check_key(key))
    for (k, v) in read_metadata(w, record; input_dir, network)
        _md_fold(k) == f && return v
    end
    nothing
end
get_metadata(record::ByteStr, key::ByteStr; kw...) = get_metadata(lib(), record, key; kw...)

"""
    set_metadata([w::Wfdb], record, key, value; input_dir=nothing, network=nothing,
                 dir=nothing) -> Nothing

Set the value of the metadata entry `key` in the header of a record.

If the header has an entry for `key` (ignoring letter case), its line is
replaced by `# Key: value` (`# Key:` if the value is empty), at the same
position and with the same line ending, with the spelling of `key` given
here. Otherwise the entry is added after the last info string of the header
(or, if it has none, after its last line that is not blank), ending as the
record line does. Every other byte of the header is kept.

# Arguments
- `record`: a record name (see [`read_metadata`](@ref)). The header is
  changed where it was read, unless `dir` is given; a header read from a
  URL can only be written elsewhere, with `dir`.
- `key`: the key, such as `"Age"` or `"Date of birth"`. The spaces, tabs,
  VT, FF and CR at either end are removed. It must not be empty, and must
  not contain `:`, `#`, a line break or a NUL byte.
- `value`: the value, which may be a sentence. The spaces at either end are
  removed. It must not contain a line break or a NUL byte; it may be empty.

Keys and values are bytes (`String`s are taken as their bytes, as given).

# Keyword arguments
$_INPUT_DOC
$_MD_DIR_DOC

$_MD_THROWS_DOC

# Examples
```julia-repl
julia> set_metadata("rec", "Age", "64")     # writes "# Age: 64"
```

Metadata often holds information about patients. WFDB-x stores it as plain
text, exactly as given, and does not de-identify it.

Part of WFDB-x; not in the original WFDB package.
"""
function set_metadata(w::Wfdb, record::ByteStr, key::ByteStr, value::ByteStr;
                      input_dir::OptByteStr=nothing, network::Union{Nothing,Bool}=nothing,
                      dir::OptByteStr=nothing)
    k = _md_check_key(key)
    changes = Tuple{Vector{UInt8},Union{Nothing,Vector{UInt8}}}[(k, _md_check_value(key, value))]
    _md_change(w, record, changes, input_dir, network, dir)
    nothing
end
set_metadata(record::ByteStr, key::ByteStr, value::ByteStr; kw...) =
    set_metadata(lib(), record, key, value; kw...)

"""
    remove_metadata([w::Wfdb], record, key; input_dir=nothing, network=nothing,
                    dir=nothing) -> Int

Remove the metadata entry `key` from the header of a record. Every entry
for `key` (ignoring letter case) is removed, with its line ending, so this
also repairs a header that has more than one. Every other byte of the
header is kept. Nothing is written if the header has no entry for `key`
(unless `dir` is given).

# Arguments
- `record`: a record name (see [`set_metadata`](@ref)).
- `key`: the key (see [`set_metadata`](@ref)).

# Keyword arguments
$_INPUT_DOC
$_MD_DIR_DOC

Returns the number of lines removed (0 if the header has no entry for
`key`).

$_MD_THROWS_DOC

# Examples
```julia-repl
julia> remove_metadata("rec", "Sex")
1
```

Part of WFDB-x; not in the original WFDB package.
"""
function remove_metadata(w::Wfdb, record::ByteStr, key::ByteStr; input_dir::OptByteStr=nothing,
                         network::Union{Nothing,Bool}=nothing, dir::OptByteStr=nothing)
    changes = Tuple{Vector{UInt8},Union{Nothing,Vector{UInt8}}}[(_md_check_key(key), nothing)]
    _md_change(w, record, changes, input_dir, network, dir)
end
remove_metadata(record::ByteStr, key::ByteStr; kw...) = remove_metadata(lib(), record, key; kw...)

"""
    update_metadata([w::Wfdb], record, changes; input_dir=nothing, network=nothing,
                    dir=nothing) -> Nothing

Make several changes to the metadata of a record in one write.

`changes` is a vector (or tuple) of `key => value` pairs (or `(key, value)`
tuples), or a dictionary. Each change is applied in order, as
[`set_metadata`](@ref)`(record, key, value)` does, or, if `value` is
`nothing`, as [`remove_metadata`](@ref)`(record, key)` does. No two keys may
differ only in letter case. The changes of a `Dict` are applied in its
iteration order, which is not defined: give a vector to fix the order in
which new entries are added.

# Keyword arguments
$_INPUT_DOC
$_MD_DIR_DOC

$_MD_THROWS_DOC
All the changes are checked first: if one is not valid, none is made
(`changes` that is neither a vector, a tuple nor a dictionary of pairs is an
`ArgumentError`, as is a key given more than once).

# Examples
```julia-repl
julia> update_metadata("rec", ["Age" => "65", "Dx" => nothing])
```

Part of WFDB-x; not in the original WFDB package.
"""
function update_metadata(w::Wfdb, record::ByteStr, changes; input_dir::OptByteStr=nothing,
                         network::Union{Nothing,Bool}=nothing, dir::OptByteStr=nothing)
    _md_change(w, record, _md_check_changes(changes), input_dir, network, dir)
    nothing
end
update_metadata(record::ByteStr, changes; kw...) = update_metadata(lib(), record, changes; kw...)

export MetadataEntry, read_metadata, get_metadata, set_metadata, remove_metadata, update_metadata

# (the precompilation workload)
register_workload("metadata") do
    # (the warnings of the duplicate keys below are not shown)
    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
    with_workload_data() do dir
        w = Wfdb()
        write(joinpath(dir, "md.hea"),
              "# a comment\r\nmd 1 360 10\r\nmd.dat 16 200 12 0 0 0 0 a\r\n# Age: 63\r\n#Sex:F\r\n" *
              "#age: 1\r\n# free comment\r\n")
        read_metadata(w, "md"; input_dir=dir, network=false)
        get_metadata(w, "md", "AGE"; input_dir=dir)
        get_metadata(w, "md", b"none"; input_dir=dir)
        set_metadata(w, "md", "Notes", ""; input_dir=dir)
        set_metadata(w, "md", b"Sex", b"M"; input_dir=dir)
        remove_metadata(w, "md", "age"; input_dir=dir)
        update_metadata(w, "md", ["Age" => "64", "Notes" => nothing]; input_dir=dir)
        update_metadata(w, "md", Dict("Dx" => "x"); input_dir=dir)
        update_metadata(w, "md", [("Dx", "y")]; input_dir=dir, dir=dir)
        for f in (() -> set_metadata(w, "md", "a:b", "1"; input_dir=dir),
                  () -> read_metadata(w, "nosuch"; input_dir=dir))
            try
                f()
            catch e
                (e isa ArgumentError || e isa WfdbError) || rethrow()
            end
        end
        read_header(w, "md.hea"; input_dir=dir)
    end
    end
end
