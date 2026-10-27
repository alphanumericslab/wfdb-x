# check.jl: check_record, a record checker: it reads a record (its header,
# its signal files and, optionally, annotation files) with the library's
# functions and reports every problem that it finds, each with a severity.
#
# check_record is specified in the same way for the seven languages (the
# messages, their order and the formatting of numbers are identical); the
# Python implementation (python/src/wfdbx/check.py) is the reference. The
# record is read with the library's functions (isigopen, getvec in bulk,
# getseginfo, annopen, getann, annstr); the header file's text is read only
# for the checks of its lines and of the record name. It checks for problems
# similar to those found by Benjamin Moody's wfdbcheck
# (https://github.com/bemoody/wfdbcheck); no code or text of wfdbcheck was
# used.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

"""
    Issue

A problem found by [`check_record`](@ref).

# Fields
- `severity::String`: `"error"`, `"warning"` or `"info"`.
- `code::String`: a stable identifier, such as `"checksum"` or
  `"gain_missing"`.
- `where::String`: `""` (the record), `"signal N"`, `"segment SEG"`,
  `"segment SEG, signal N"` or `"annotator ANN"`.
- `message::String`: the description of the problem.

`string(issue)` is its line of the report: `"SEVERITY: WHERE: MESSAGE"`
(without `"WHERE: "` for the record itself).
"""
struct Issue
    severity::String
    code::String
    where::String
    message::String
end

Base.show(io::IO, i::Issue) =
    print(io, isempty(i.where) ? "$(i.severity): $(i.message)" :
              "$(i.severity): $(i.where): $(i.message)")

"""
    CheckReport

The result of [`check_record`](@ref).

# Fields
- `record::String`: the record name, as given.
- `ok::Bool`: `true` if no issue has the severity `"error"`.
- `issues::Vector{Issue}`: the problems found, in the order of the checks
  (see [`Issue`](@ref)).

[`lines`](@ref)`(report)` returns the text form of the report, one line per
issue (`"SEVERITY: WHERE: MESSAGE"`, without `"WHERE: "` for the record
itself), or `["no problems found"]`. `show` (and `print`) writes these lines.
"""
struct CheckReport
    record::String
    ok::Bool
    issues::Vector{Issue}
end
CheckReport(record::String, issues::Vector{Issue}) =
    CheckReport(record, !any(i -> i.severity == "error", issues), issues)

"""
    lines(report::CheckReport) -> Vector{String}

The text form of a [`CheckReport`](@ref): one line per issue, or
`["no problems found"]`.

Part of wfdb-x; not in the original WFDB package.
"""
lines(r::CheckReport) = isempty(r.issues) ? ["no problems found"] : [string(i) for i in r.issues]

Base.show(io::IO, r::CheckReport) = print(io, join(lines(r), "\n"))
Base.show(io::IO, ::MIME"text/plain", r::CheckReport) = show(io, r)

const _INT32_MAX = Int64(2147483647)
# Bits that each storage format can store (formats 8 and 0: no limit).
const _CAPACITY = Dict{Int32,Int}(80 => 8, 508 => 8, 310 => 10, 311 => 10, 212 => 12,
                                  16 => 16, 61 => 16, 160 => 16, 516 => 16, 24 => 24,
                                  524 => 24, 32 => 32)
const _CHUNK_SAMPLES = 1 << 20      # samples (frames x signals) read at a time

# ---------------------------------------------------------------------------
# Text of the messages

# A name quoted for a message: in double quotes, with each byte below 32 or
# above 126 shown as \xHH (lowercase hex).
function _q(name)
    io = IOBuffer()
    write(io, '"')
    for b in (name === nothing ? UInt8[] : bytes(name))
        if b < 0x20 || b > 0x7e
            print(io, "\\x", string(b; base=16, pad=2))
        else
            write(io, b)
        end
    end
    write(io, '"')
    String(take!(io))
end

# "1 frame", "2 frames"
_n(k::Integer, word::String) = "$k $word$(k == 1 ? "" : "s")"

# A message about k items: "1 NOUN VERB WHAT: ONE" or "K NOUNs VERB WHAT;
# the first is FIRST".
_count(k, noun, verb_one, verb_many, what, x) =
    k == 1 ? "1 $noun $verb_one $what: $x" : "$k $(noun)s $verb_many $what; the first is $x"

_g(x::Real) = String(cformat("%g", Float64(x)))

function _int16(x::Integer)
    x = Int64(x) & 0xFFFF
    x & 0x8000 != 0 ? x - 0x10000 : x
end

_has_control(s) = any(b -> b < 0x20 || b == 0x7f, s)

# True if s is only a number: an optional sign, digits with at most one
# '.', and at least one digit.
function _is_number(s::AbstractVector{UInt8})
    i = 1
    !isempty(s) && (s[1] == UInt8('+') || s[1] == UInt8('-')) && (i = 2)
    rest = s[i:end]
    count(==(UInt8('.')), rest) > 1 && return false
    digits = filter(!=(UInt8('.')), rest)
    !isempty(digits) && all(b -> UInt8('0') <= b <= UInt8('9'), digits)
end

_str(b) = b === nothing ? "" : String(copy(bytes(b)))

# "segment s1" + "signal 0" -> "segment s1, signal 0"
_at(prefix::String, sub::String) =
    (!isempty(prefix) && !isempty(sub)) ? prefix * ", " * sub : isempty(prefix) ? sub : prefix

_add!(rep::Vector{Issue}, severity, code, where, message) =
    push!(rep, Issue(severity, code, where, message))

# ---------------------------------------------------------------------------
# The header file

# The bytes of the header file that the library reads for record `name`,
# the record name that its file name gives (the file name without directory
# and ".hea") and its path; nothing if there is none (no such file, or a
# record read from another format, such as EDF).
function _header_text(w::Wfdb, name::Vector{UInt8})
    q = length(name)
    while q > 1 && !(name[q] in b"./:\\")
        q -= 1
    end
    if q >= 1 && name[q] == UInt8('.')
        name[q+1:end] == b"hea" || return nothing     # (EDF: no WFDB header)
        f = wfdb_open(w, nothing, name, WFDB_READ)
    else
        f = wfdb_open(w, "hea", name, WFDB_READ)
    end
    f === nothing && return nothing
    path = wfdb_filename(w)
    isempty(path) && (path = copy(name))
    text = UInt8[]
    buf = Vector{UInt8}(undef, 1 << 16)
    while true
        k = fread!(f, buf)
        k <= 0 && break
        append!(text, @view buf[1:k])
    end
    fclose(f)
    base = path[length(wfdbx_dirname(path))+1:end]
    if length(base) >= 4 && base[end-3:end] == b".hea"
        base = base[1:end-4]
    elseif length(base) >= 4 && base[1:4] == b"hea."
        base = base[5:end]
    end
    (text, base, path)
end

# v split at each byte of seps.
function _split(v::AbstractVector{UInt8}, seps)
    out = Vector{Vector{UInt8}}()
    i = 1
    for j in 1:length(v)+1
        if j > length(v) || v[j] in seps
            push!(out, v[i:j-1])
            i = j + 1
        end
    end
    out
end

# The fields of the record line of a header (the first line whose first
# field does not begin with '#'), or nothing.
function _record_line(text::Vector{UInt8})
    for line in _split(text, (UInt8('\n'),))
        fields = _split_fields(line)
        (!isempty(fields) && fields[1][1] != UInt8('#')) && return fields
    end
    nothing
end
# The fields of a header line, separated by spaces, tabs and CRs.
_split_fields(line) = filter(!isempty, _split(line, (UInt8(' '), UInt8('\t'), UInt8('\r'))))

# Checks 1.5-1.7: the lines of the header file and its record name.
function _check_text(hdr, where::String, rep::Vector{Issue})
    text, base, _ = hdr
    ls = _split(text, (UInt8('\n'),))
    (!isempty(ls) && isempty(ls[end])) && pop!(ls)     # (after the final newline)
    for (k, line) in enumerate(ls)
        (!isempty(line) && line[end] == UInt8('\r')) && (line = line[1:end-1])
        length(line) > 255 &&
            _add!(rep, "error", "header_line_long", where,
                  "line $k of the header is longer than 255 characters")
    end
    for (k, line) in enumerate(ls)
        if any(>(0x7f), line)
            _add!(rep, "warning", "header_not_ascii", where,
                  "line $k of the header contains non-ASCII characters")
            break
        end
    end
    fields = _record_line(text)
    if fields !== nothing
        f = fields[1]
        # (up to the first '/' after the first character)
        k = findnext(==(UInt8('/')), f, 2)
        x = k === nothing ? f : f[1:k-1]
        x != base &&
            _add!(rep, "warning", "header_name", where,
                  "the header names the record $(_q(x)), but its file name is $(_q(base))")
    end
end

# The length (number of samples) on the record line: 0 if not given.
function _header_length(text)
    fields = text === nothing ? nothing : _record_line(text)
    (fields === nothing || length(fields) < 4) && return Int64(0)
    v = fields[4]
    k = 0
    while k < length(v) && UInt8('0') <= v[k+1] <= UInt8('9')
        k += 1
    end
    k == 0 && return Int64(0)
    x = tryparse(Int64, String(v[1:k]))
    x === nothing ? typemax(Int64) : x
end

# ---------------------------------------------------------------------------
# Signal specifications (section 2)

function _adc_range(info::Siginfo)
    b = Int(info.adcres)
    (Int64(info.adczero) - (Int64(1) << (b - 1)), Int64(info.adczero) + (Int64(1) << (b - 1)) - 1)
end

_file_char(b::UInt8) = UInt8('a') <= b <= UInt8('z') || UInt8('A') <= b <= UInt8('Z') ||
                       UInt8('0') <= b <= UInt8('9') || b in b"_-./"

# Checks 2.1-2.13 of the signals si of a record opened under the name
# opened_as. skip_null: signals of format 0 are not checked (a segment of a
# multi-segment record).
function _check_specs(si::Vector{Siginfo}, opened_as::Vector{UInt8}, prefix::String,
                      rep::Vector{Issue}, skip_null::Bool)
    descs = Vector{Vector{UInt8}}()     # descriptions of the signals checked
    for (k, info) in enumerate(si)
        s = k - 1
        null = info.fmt == 0
        (null && skip_null) && continue
        where = _at(prefix, "signal $s")
        desc = info.desc
        if desc === nothing || isempty(desc) ||
           desc == [b"record "; opened_as; Vector{UInt8}(", signal $s")]
            _add!(rep, "warning", "desc_missing", where, "the signal has no description")
        else
            push!(descs, desc)
            _is_number(desc) &&
                _add!(rep, "warning", "desc_number", where,
                      "the description $(_q(desc)) is only a number")
            _has_control(desc) &&
                _add!(rep, "error", "desc_control", where,
                      "the description $(_q(desc)) contains control characters")
        end
        info.fmt == 8 &&
            _add!(rep, "warning", "format_difference", where,
                  "format 8 stores first differences, which cannot follow steep slopes")
        if info.gain == 0
            _add!(rep, "warning", "gain_missing", where,
                  "the signal is uncalibrated (no gain is given)")
        elseif info.gain < 0
            _add!(rep, "info", "gain_negative", where, "the gain is negative ($(_g(info.gain)))")
        end
        units_given = info.units !== nothing && !isempty(info.units)
        (info.gain != 0 && !units_given) &&
            _add!(rep, "warning", "units_missing", where, "the units are not specified")
        (units_given && _has_control(info.units)) &&
            _add!(rep, "error", "units_control", where,
                  "the units $(_q(info.units)) contain control characters")
        b = Int(info.adcres)
        cap = null ? nothing : get(_CAPACITY, info.fmt, nothing)
        if b == 0
            _add!(rep, "warning", "adcres_missing", where, "the ADC resolution is not specified")
        elseif cap !== nothing && b > cap
            _add!(rep, "error", "adcres_too_large", where,
                  "the ADC resolution ($b bits) exceeds what format $(info.fmt) can store ($cap bits)")
        elseif cap !== nothing && b >= 1
            lo, hi = _adc_range(info)
            fmin, fmax = -(Int64(1) << (cap - 1)), (Int64(1) << (cap - 1)) - 1
            (lo < fmin || hi > fmax) &&
                _add!(rep, "error", "adc_range", where,
                      "the ADC range ($lo to $hi) does not fit in format $(info.fmt) ($fmin to $fmax)")
        end
        fname = info.fname === nothing ? UInt8[] : info.fname
        if !null && fname != b"-" && fname != b"~" && !all(_file_char, fname)
            _add!(rep, "warning", "filename", where,
                  "the signal file name $(_q(fname)) contains characters other than " *
                  "letters, digits, '_', '-' and '.'")
        end
    end
    order = Vector{Vector{UInt8}}()
    seen = Dict{Vector{UInt8},Int}()
    for d in descs
        haskey(seen, d) || push!(order, d)
        seen[d] = get(seen, d, 0) + 1
    end
    for d in order
        seen[d] > 1 &&
            _add!(rep, "warning", "desc_duplicate", prefix,
                  "$(seen[d]) signals have the description $(_q(d))")
    end
end

# ---------------------------------------------------------------------------
# Signal data (section 3)

# The size of the local file of signal group ig, or nothing.
function _file_size(ig::IgData)
    f = ig.fp
    (f === nothing || f.kind != _K_FILE || f.remote || f.fd < 0) && return nothing
    try
        return Int64(stat(RawFD(f.fd)).size)
    catch
        return nothing
    end
end
# (replaced by the tests, to simulate a large file)
const _CHECK_FILE_SIZE = Ref{Function}(_file_size)

# Checks 3.1-3.9: read the signals of the record opened as `name` (header
# signals si, header length ns).
function _check_data(w::Wfdb, name::Vector{UInt8}, si::Vector{Siginfo}, prefix::String,
                     ns::Int64, length_missing::Bool, rep::Vector{Issue})
    n = length(si)
    n == 0 && return
    any(s -> s.fname == b"-" && s.fmt != 0, si) && return  # (the standard input: not read)
    wfdbquit(w)
    opened = [Siginfo() for _ in 1:n]
    k = isigopen(w, name, opened, n)
    if k < n
        have = Set(opened[j].fname for j in 1:max(k, 0))
        reported = Vector{Union{Nothing,Vector{UInt8}}}()
        for s in si
            if s.fmt != 0 && !(s.fname in have) && !(s.fname in reported)
                push!(reported, s.fname)
                _add!(rep, "error", "file_unreadable", prefix,
                      "the signal file $(_q(s.fname)) cannot be read")
            end
        end
        isempty(reported) &&
            _add!(rep, "error", "file_unreadable", prefix,
                  "the signal file $(_q(si[1].fname)) cannot be read")
        wfdbquit(w)
        return
    end
    st = w.sig
    for g in 1:min(length(st.igd), st.nigroup)
        size = _CHECK_FILE_SIZE[](st.igd[g])
        if size !== nothing && size > _INT32_MAX
            j = findfirst(s -> s.group == g - 1, si)
            j === nothing && continue
            _add!(rep, "warning", "file_large", prefix,
                  "the signal file $(_q(si[j].fname)) has more than 2147483647 bytes, " *
                  "which 32-bit applications cannot handle")
        end
    end
    setgvmode(w, WFDB_LOWRES)
    inv = WFDB_INVALID_SAMPLE
    ranges = [(1 <= info.adcres <= 32 && info.fmt != 0) ? _adc_range(info) : nothing
              for info in si]
    n_out = zeros(Int64, n)
    first_out = Vector{Union{Nothing,Tuple{Int64,Int64}}}(nothing, n)
    n_inv = zeros(Int64, n)
    first_inv = Vector{Union{Nothing,Int64}}(nothing, n)
    rows = max(1024, _CHUNK_SAMPLES ÷ n)
    buf = Vector{Int32}(undef, rows * n)
    m = Int64(0)                        # frames read
    stat = Int32(n)
    residual = nothing                  # checksum residuals after ns frames
    # (the checksums: not for EDF, nor for a record with skewed signals,
    # whose samples the library reads ahead)
    checked = ns > 0 && st.isedf == 0 && all(s -> wfdbgetskew(w, s) == 0, 0:n-1)
    st.cksum_quiet = true
    try
        while true
            want = Int64(rows)
            (checked && residual === nothing) && (want = min(want, ns - m))
            got, stat = _getvecs_into(w, buf, 0, want, true)
            got = max(got, Int64(0))
            if got > 0
                for s in 1:n
                    si[s].fmt == 0 && continue      # (a null signal: no data)
                    r = ranges[s]
                    for j in 1:got
                        v = Int64(buf[(j-1)*n+s])
                        if v == inv
                            first_inv[s] === nothing && (first_inv[s] = m + j - 1)
                            n_inv[s] += 1
                        elseif r !== nothing && (v < r[1] || v > r[2])
                            first_out[s] === nothing && (first_out[s] = (m + j - 1, v))
                            n_out[s] += 1
                        end
                    end
                end
                m += got
            end
            (checked && residual === nothing && m >= ns) &&
                (residual = [Int64(st.isd[s].info.cksum) for s in 1:n])
            stat == -4 && continue
            got < want && break
        end
    finally
        st.cksum_quiet = false
    end
    # (with skewed signals, getvec returns the frames of the files less the
    # largest skew)
    skew = maximum(s -> Int64(wfdbgetskew(w, s)), 0:n-1)
    wfdbquit(w)
    (skew != 0 && m > 0) && (m += skew)
    for s in 1:n
        where = _at(prefix, "signal $(s - 1)")
        if n_out[s] > 0
            lo, hi = ranges[s]
            j, v = first_out[s]
            _add!(rep, "error", "sample_range", where,
                  _count(n_out[s], "sample", "is", "are", "outside the ADC range ($lo to $hi)",
                         "sample $j (value $v)"))
        end
        if n_inv[s] > 0
            _add!(rep, "info", "invalid_samples", where,
                  _count(n_inv[s], "sample", "is", "are", "invalid (missing data)",
                         "sample $(first_inv[s])"))
        end
    end
    if residual !== nothing
        for (s, info) in enumerate(si)
            if info.nsamp > 0 && info.fmt != 0 && residual[s] & 0xFFFF != 0
                _add!(rep, "error", "checksum", _at(prefix, "signal $(s - 1)"),
                      "the checksum does not match: the header gives $(_int16(info.cksum)), " *
                      "the samples sum to $(_int16(Int64(info.cksum) - residual[s]))")
            end
        end
    end
    end_ok = stat == -1 || stat >= 0
    short = ns > 0 && m < ns && (stat == -1 || stat == -3)
    short && _add!(rep, "error", "length_short", prefix,
                   "the signal files end after $(_n(m, "frame")), before the $ns given in the header")
    (ns > 0 && m > ns) &&
        _add!(rep, "warning", "length_long", prefix,
              "the signal files hold $(_n(m, "frame")), more than the $ns given in the header")
    (length_missing && end_ok) &&
        _add!(rep, "info", "length_unspecified_frames", prefix,
              "the signal files hold $(_n(m, "frame"))")
    (!end_ok && !short) &&
        _add!(rep, "error", "read_error", prefix,
              "the signal data cannot be read after $(_n(m, "frame")) (getvec status $stat)")
    nothing
end

# ---------------------------------------------------------------------------
# A record (sections 1-4)

# Open the header of record `name` (wfdbquit first). Returns (nsig, siginfo
# vector, fs, nsamples, segments) or nothing if the header cannot be read;
# segments is a vector of (name, length).
function _open_header(w::Wfdb, name::Vector{UInt8})
    wfdbquit(w)
    n = isigopen(w, name, nothing, 0)
    if n < 0
        wfdbquit(w)
        return nothing
    end
    si = [Siginfo() for _ in 1:n]
    n > 0 && isigopen(w, name, si, -n)
    st = w.sig
    sr = Ref{Any}(nothing)
    getseginfo(w, sr)
    segs = Tuple{Vector{UInt8},Int64}[(copy(x.recname), x.nsamp) for x in something(sr[], Seginfo[])]
    nsamples = (st.in_msrec != 0 || !isempty(segs)) ? st.msnsamples : st.nsamples
    fs = sampfreq(w, nothing)
    wfdbquit(w)
    (Int(n), si, fs, Int64(nsamples), segs)
end

const _LENGTH_LARGE = "the record has more than 2147483647 samples, which 32-bit " *
                      "applications cannot handle"

# Sections 1.2-1.8 and 2 for a single-segment record. Returns true if the
# header gives no length (length_missing).
function _check_single(record::Vector{UInt8}, info, hdr, rep::Vector{Issue})
    n, si, fs, nsamples, _ = info
    n == 0 && _add!(rep, "info", "no_signals", "", "the record has no signals")
    fs == 0 && _add!(rep, "warning", "fs_missing", "", "the sampling frequency is not specified")
    nsamples == 0 && _add!(rep, "warning", "length_missing", "", "the record length is not specified")
    hdr === nothing || _check_text(hdr, "", rep)
    nsamples > _INT32_MAX && _add!(rep, "info", "length_large", "", _LENGTH_LARGE)
    n > 0 && _check_specs(si, record, "", rep, false)
    nsamples == 0
end

# Sections 1-4. Returns the record length in samples for the annotation
# checks (0 if unknown), or nothing if the header cannot be read.
function _check_record_signals(w::Wfdb, record::Vector{UInt8}, rep::Vector{Issue})
    hdr = _header_text(w, record)
    info = _open_header(w, record)
    if info === nothing
        _add!(rep, "error", "header_unreadable", "", "the header cannot be read")
        hdr === nothing || _check_text(hdr, "", rep)
        return nothing
    end
    n, si, fs, nsamples, segs = info
    if isempty(segs)
        length_missing = _check_single(record, info, hdr, rep)
        n > 0 && _check_data(w, record, si, "", nsamples, length_missing, rep)
        return nsamples
    end
    # A multi-segment record: the master header
    n == 0 && _add!(rep, "info", "no_signals", "", "the record has no signals")
    fs == 0 && _add!(rep, "warning", "fs_missing", "", "the sampling frequency is not specified")
    given = hdr !== nothing ? _header_length(hdr[1]) : nsamples
    given == 0 && _add!(rep, "warning", "length_missing", "", "the record length is not specified")
    hdr === nothing || _check_text(hdr, "", rep)
    nsamples > _INT32_MAX && _add!(rep, "info", "length_large", "", _LENGTH_LARGE)
    # The segments, next to the master header
    hpath = hdr !== nothing ? hdr[3] : something(wfdbfile(w, "hea", record), UInt8[])
    d = wfdbx_dirname(hpath)
    if !isempty(d) && !_is_url(d) && !isabspath(String(copy(d)))
        d = Vector{UInt8}(joinpath(abspath(String(copy(d))), ""))
    elseif isempty(d)
        d = Vector{UInt8}(joinpath(pwd(), ""))
    end
    variable = segs[1][2] == 0
    layout_descs = nothing
    done = Set{Vector{UInt8}}()
    for (k, (seg, _)) in enumerate(segs)
        (seg == b"~" || seg in done) && continue
        push!(done, seg)
        prefix = "segment " * _str(seg)
        is_layout = variable && k == 1
        if !_in_header_dir(seg)
            _add!(rep, "error", "segment_unreadable", prefix, "the segment cannot be read")
            continue
        end
        path = [d; seg]
        seg_hdr = _header_text(w, path)
        sinfo = _open_header(w, path)
        if sinfo !== nothing && !isempty(sinfo[5])
            _add!(rep, "error", "nested", prefix, "the segment is itself a multi-segment record")
            continue
        end
        if sinfo === nothing
            _add!(rep, "error", "segment_unreadable", prefix, "the segment cannot be read")
            continue
        end
        sn, ssi, sfs, sns, _ = sinfo
        (sfs > 0 && fs > 0 && sfs != fs) &&
            _add!(rep, "error", "segment_fs", prefix,
                  "the segment's sampling frequency ($(_g(sfs))) differs from the record's ($(_g(fs)))")
        sn == 0 && _add!(rep, "info", "no_signals", prefix, "the record has no signals")
        seg_hdr === nothing || _check_text(seg_hdr, prefix, rep)
        sns > _INT32_MAX && _add!(rep, "info", "length_large", prefix, _LENGTH_LARGE)
        sn > 0 && _check_specs(ssi, path, prefix, rep, !is_layout)
        if is_layout
            layout_descs = Set{Union{Nothing,Vector{UInt8}}}(s.desc for s in ssi)
            continue
        end
        if variable
            for (s, x) in enumerate(ssi)
                if x.fmt != 0 && (layout_descs === nothing || !(x.desc in layout_descs))
                    _add!(rep, "error", "layout_missing_signal", _at(prefix, "signal $(s - 1)"),
                          "the signal $(_q(x.desc)) is not in the layout")
                end
            end
        else
            _check_layout(ssi, si, prefix, rep)
        end
        sn > 0 && _check_data(w, path, ssi, prefix, sns, false, rep)
    end
    total = sum(x[2] for x in segs)
    (given > 0 && total != given) &&
        _add!(rep, "warning", "segment_lengths", "",
              "the segment lengths add up to $(_n(total, "sample")), but the master header gives $given")
    total               # (the end of the signals)
end

# Check 4.4: the signals of a segment of a fixed-layout record match the
# record's signals.
function _check_layout(ssi::Vector{Siginfo}, si::Vector{Siginfo}, prefix::String,
                       rep::Vector{Issue})
    length(ssi) != length(si) &&
        _add!(rep, "error", "layout_signals", prefix,
              "the segment has $(_n(length(ssi), "signal")), but the record has $(length(si))")
    for s in 1:min(length(ssi), length(si))
        a, b = ssi[s], si[s]
        a.fmt == 0 && continue
        where = _at(prefix, "signal $(s - 1)")
        for (field, x, y) in (("description", _q(a.desc), _q(b.desc)),
                              ("units", _q(a.units), _q(b.units)),
                              ("gain", _g(a.gain), _g(b.gain)),
                              ("baseline", string(a.baseline), string(b.baseline)),
                              ("samples per frame", string(a.spf), string(b.spf)))
            x != y &&
                _add!(rep, "error", "layout_mismatch", where,
                      "the signal differs from the record's signal $(s - 1) in its $field ($x, expected $y)")
        end
    end
end

# ---------------------------------------------------------------------------
# Annotators (section 5)

function _check_annotator(w::Wfdb, record::Vector{UInt8}, an::Vector{UInt8}, len,
                          rep::Vector{Issue})
    where = "annotator " * _str(an)
    (!isempty(an) && all(b -> UInt8('0') <= b <= UInt8('9'), an)) &&
        _add!(rep, "warning", "annotator_name", where, "the annotator name consists only of digits")
    wfdbquit(w)
    len === nothing || sampfreq(w, record)     # (the record's frequency, for getann)
    a_ = w.ann
    saved = (deepcopy(a_.astring), deepcopy(a_.tstring), copy(a_.modified))
    count = 0
    prev = nothing
    order = [0]; order_first = nothing
    code = [0]; code_first = nothing
    null = [0]; null_first = nothing
    undef = [0]; undef_first = nothing
    after = [0]; after_first = nothing
    stat = Int32(0)
    try
        if annopen(w, record, [Anninfo(an, WFDB_READ)], 1) < 0
            _add!(rep, "error", "annotations_unreadable", where, "the annotation file cannot be read")
            return
        end
        a = Annotation()
        while true
            stat = getann(w, 0, a)
            stat != 0 && break
            count += 1
            t, c = a.time, Int(a.anntyp)
            if prev !== nothing && t < prev
                order[1] += 1
                order_first === nothing && (order_first = (t, prev))
            end
            prev = t
            if c > ACMAX
                code[1] += 1
                code_first === nothing && (code_first = (t, c))
            elseif c == 0
                null[1] += 1
                null_first === nothing && (null_first = t)
            elseif annstr(w, c) == Vector{UInt8}("[$c]")
                undef[1] += 1
                undef_first === nothing && (undef_first = (t, c))
            end
            if len !== nothing && len != 0 && t >= len
                after[1] += 1
                after_first === nothing && (after_first = t)
            end
        end
    finally
        wfdbquit(w)
        a_.astring, a_.tstring, a_.modified = saved
    end
    stat != -1 &&
        _add!(rep, "error", "annotations_truncated", where,
              "the annotation file ends unexpectedly after $(_n(count, "annotation"))")
    if order[1] > 0
        s, p = order_first
        _add!(rep, "error", "annotations_order", where,
              _count(order[1], "annotation", "is", "are", "out of order",
                     "at sample $s, after sample $p"))
    end
    if code[1] > 0
        s, c = code_first
        _add!(rep, "error", "annotation_code", where,
              _count(code[1], "annotation", "has", "have", "an invalid code",
                     "at sample $s (code $c)"))
    end
    null[1] > 0 &&
        _add!(rep, "warning", "annotation_null", where,
              _count(null[1], "annotation", "has", "have", "code 0 (NOTQRS)",
                     "at sample $null_first"))
    if undef[1] > 0
        s, c = undef_first
        x = "at sample $s (code $c)"
        _add!(rep, "warning", "annotation_undefined", where,
              undef[1] == 1 ? "1 annotation uses a code without a mnemonic: " * x :
              "$(undef[1]) annotations use codes without a mnemonic; the first is " * x)
    end
    after[1] > 0 &&
        _add!(rep, "warning", "annotations_after_end", where,
              _count(after[1], "annotation", "is", "are",
                     "after the end of the record ($(_n(len, "sample")))",
                     "at sample $after_first"))
    nothing
end

# ---------------------------------------------------------------------------

"""
    check_record([w::Wfdb], record; annotators=String[], input_dir=nothing,
                 network=nothing) -> CheckReport

Check a record and its annotation files, and report every problem.

The header, the signal specifications, the signal files (all samples are
read) and the annotation files of `annotators` are checked. Problems in the
record never throw an exception: they are reported in the returned
[`CheckReport`](@ref). `report.ok` is `true` if there is no error;
`report.issues` lists the problems ([`Issue`](@ref)s, with `severity`,
`code`, `where` and `message`); `print(report)` prints one line per
problem, such as

    error: signal 1: the checksum does not match: the header gives 12, the samples sum to 13

or `no problems found` ([`lines`](@ref)`(report)` returns the lines).

Severities: `"error"` (the record is damaged or does not follow the WFDB
format), `"warning"` (something is missing or unusual, and may give wrong
results) and `"info"` (a fact worth knowing). The checks run in normal
mode, even if legacy mode is on, and the library prints no messages during
the call.

# Arguments
- `record`: the record name: a name in the input directory, or a full
  path, `~` path or URL (as for [`read_record`](@ref)).
- `annotators`: the annotator names to check, such as `["atr"]` (one name
  may be given as a string). The default is none.
$_INPUT_DOC

Throws an `ArgumentError` if `record` is empty or an annotator name is not
a string.

It checks for problems similar to those found by Benjamin Moody's
[wfdbcheck](https://github.com/bemoody/wfdbcheck).

# Examples
The examples read `100s`, the first minute of record 100 of the MIT-BIH
Arrhythmia Database, which is included with wfdb-x in `tests/data` of a copy
of the wfdb-x repository:
```julia-repl
julia> wfdbx_set_input_dir("/path/to/wfdb-x/tests/data");

julia> report = check_record("100s"; annotators=["atr"])
warning: signal 0: the units are not specified
warning: signal 1: the units are not specified

julia> report.ok
true
```

Part of wfdb-x; not in the original WFDB package.
"""
function check_record(w::Wfdb, record::ByteStr; annotators=String[],
                      input_dir::OptByteStr=nothing, network::Union{Nothing,Bool}=nothing)
    rec = copy(bytes(record))
    isempty(rec) && throw(ArgumentError("record must not be empty"))
    anns = annotators isa ByteStr ? [annotators] : collect(annotators)
    for a in anns
        a isa ByteStr || throw(ArgumentError("annotator names must be strings"))
    end
    anns = Vector{UInt8}[copy(bytes(a)) for a in anns]
    rep = Issue[]
    _with_input_options(w, input_dir, network) do
        legacy = wfdbx_set_legacy(w, false)
        printing = w.io.error_print
        w.io.error_print = false
        try
            wfdbquit(w)
            len = _check_record_signals(w, rec, rep)
            for a in anns
                _check_annotator(w, rec, a, len, rep)
            end
        finally
            wfdbquit(w)
            w.io.error_print = printing
            wfdbx_set_legacy(w, legacy)
        end
    end
    CheckReport(String(rec), rep)
end
check_record(record::ByteStr; kw...) = check_record(lib(), record; kw...)
