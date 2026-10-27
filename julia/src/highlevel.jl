# highlevel.jl: high-level API: read and write whole records and annotation
# files (read_record, read_header, read_annotations, write_record,
# write_record_physical, write_annotations), built on the C-style API.
#
# These functions read and write exactly what the WFDB library and the
# command-line tools do. Each takes an optional `Wfdb` first argument (the
# default instance otherwise), whose state it uses and resets with
# `wfdbquit`. Errors are thrown as `WfdbError`. In the examples below,
# "100s" is the sample record included with wfdb-x (the first minute of
# record 100 of the MIT-BIH Arrhythmia Database), read from tests/data in a
# copy of the wfdb-x repository, and "new" is a record written by the
# example:
#
#     wfdbx_set_input_dir("/path/to/wfdb-x/tests/data")
#     rec = read_record("100s"; to="0:10")      # the first 10 seconds
#     rec.samples                               # Matrix{Int32}: frame × signal
#     physical(rec)                             # Matrix{Float64} (NaN: invalid)
#     ann = read_annotations("100s", "atr")
#     write_record("new", rec.samples, rec.fs; gains=[200.0], adcres=11,
#                  units="mV", names=["a", "b"])
#
# Finding files: every relative name is read under the input directory and
# written under the output directory -- whatever is set as the input
# directory, a local directory or a URL, prefixes it; a name given as a full
# path (/Users/...), a ~ path or a URL is used as given; nothing else is
# searched. The readers take `input_dir=` (the input directory for the call)
# and `network=` (allow URLs for the call; PhysioNet or any server is
# contacted only if asked for), the writers `dir=` (the output directory:
# the files are created there, and the record opens from there under its
# plain name; see `_with_output_dir`); see also wfdbx_set_input_dir,
# wfdbx_set_output_dir and wfdbx_set_network. The signal files of a record
# are in the directory of its header.
#
# wfdb-x: no sampling frequency, gain, ADC resolution or units are ever
# assumed (the C library assumed 250 Hz, 200 adu/mV, 12 bits or a resolution
# based on the format, and millivolts): see docs/DIVERGENCES.md. Each
# function has a `legacy=false` keyword argument: with `legacy=true`, it
# behaves as the original package did (see `_with_legacy`). A checksum error
# (getvec status -4: the samples are complete, their sum does not match the
# header's checksums) is not an error of read_record but a warning
# (checksum_warning=false: none); the data are returned.
#
# Strings read from files (signal descriptions, comments, annotation
# mnemonics and aux strings) are byte strings (`Vector{UInt8}`), as
# everywhere in the library; string arguments may be `String`s.
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
    WfdbError(msg)

The exception thrown by the high-level functions ([`read_record`](@ref),
[`write_annotations`](@ref), ...) when an operation fails. The field `msg`
says what failed, such as `"can't read record 100x"`. The library may also
print a message on the standard error. [`wfdbquiet`](@ref) turns these
messages off.
"""
struct WfdbError <: Exception
    msg::String
end
Base.showerror(io::IO, e::WfdbError) = print(io, "WfdbError: ", e.msg)

_lossy(b) = String(copy(cstr(bytes(b))))

"""
    Record

The signals of a record, or of part of one, as returned by
[`read_record`](@ref).

# Fields
- `name::String`: the record name.
- `fs::Float64`: the sampling frequency in Hz, or 0 if the header gives
  none.
- `samples::Matrix{Int32}`: the samples in ADC units, one row per sample
  and one column per signal. `samples[i, s]` is sample `i` of signal `s`.
  Invalid samples are `WFDB_INVALID_SAMPLE`. Use [`physical`](@ref) to get
  physical units.
- `siginfo::Vector{Siginfo}`: the specifications of each signal: `desc`,
  `units`, `gain`, `baseline`, `adcres`, `fmt`, ... (see
  [`Siginfo`](@ref)). `units` is `nothing` and `adcres` is 0 when the
  header does not give them.
- `base_time::Union{Nothing,String}`: the start time and date as text, to
  the second, such as `"[14:00:03 21/06/2024]"`.
- `base_time_ms::Union{Nothing,Int64}`: the start time in milliseconds
  after midnight, such as `50403500` for 14:00:03.500.
- `base_date::Union{Nothing,NTuple{3,Int}}`: the start date as
  `(year, month, day)`.
- `sampfrom::Int64`: the number of the first sample returned.
- `comments::Vector{Vector{UInt8}}`: the info strings of the header, as
  bytes.
- `channels::Vector{Int}`: the number of each returned signal in the
  record. `0` is the first signal.
- `checksum_ok::Bool`: `false` if the data do not match the checksums in
  the header. Checksums are only checked when a read reaches the end of
  the record.

`base_time`, `base_time_ms` and `base_date` are `nothing` when the header
does not give them.

See also [`physical`](@ref) and [`signal_names`](@ref).
"""
struct Record
    name::String
    fs::Float64
    samples::Matrix{Int32}
    siginfo::Vector{Siginfo}
    base_time::Union{Nothing,String}
    base_time_ms::Union{Nothing,Int64}
    base_date::Union{Nothing,NTuple{3,Int}}
    sampfrom::Int64
    comments::Vector{Vector{UInt8}}
    channels::Vector{Int}
    checksum_ok::Bool
end

"""
    Header

The header of a record, as returned by [`read_header`](@ref).

# Fields
- `name::String`: the record name, as given.
- `fs::Float64`: the sampling frequency in Hz, or 0 if the header gives
  none.
- `counter_freq::Float64`: the counter frequency, as [`getcfreq`](@ref)
  gives it.
- `base_counter::Float64`: the base counter value, as
  [`getbasecount`](@ref) gives it.
- `nsamples::Int64`: the number of samples per signal, or 0 if the header
  does not give it.
- `nsig::Int`: the number of signals.
- `siginfo::Vector{Siginfo}`: the specifications of each signal: signal
  file name, format, gain, baseline, units, description, ... (see
  [`Siginfo`](@ref)).
- `base_time`, `base_time_ms`, `base_date`, `comments`: as in
  [`Record`](@ref).
"""
struct Header
    name::String
    fs::Float64
    counter_freq::Float64
    base_counter::Float64
    nsamples::Int64
    nsig::Int
    siginfo::Vector{Siginfo}
    base_time::Union{Nothing,String}
    base_time_ms::Union{Nothing,Int64}
    base_date::Union{Nothing,NTuple{3,Int}}
    comments::Vector{Vector{UInt8}}
end

# The base time and date of the record open in w, for a Record or Header:
# (base_time, base_time_ms, base_date). (A header without a sampling
# frequency has no base time either, and timstr would report the missing
# frequency.)
function _base_info(w::Wfdb, fs::Float64)
    bt = fs > 0.0 ? timstr(w, 0) : ""
    base_time = startswith(bt, '[') ? bt : nothing
    base_time_ms = base_time === nothing ? nothing : Int64(w.sig.btime)
    bdate = w.sig.bdate
    base_date = bdate != 0 ? NTuple{3,Int}(_julian_ymd(Int64(bdate))) : nothing
    (base_time, base_time_ms, base_date)
end

# The info strings of record (getinfo).
function _comments(w::Wfdb, record::ByteStr)
    comments = Vector{UInt8}[]
    c = getinfo(w, record)
    while c !== nothing
        push!(comments, c)
        c = getinfo(w, nothing)
    end
    comments
end

"""
    signal_names(rec::Record) -> Vector{Vector{UInt8}}

Return the description of each signal of `rec`, such as `"MLII"`, as
bytes. Use `String.(signal_names(rec))` to get `String`s.

Part of wfdb-x; not in the original WFDB package.
"""
signal_names(rec::Record) = Vector{UInt8}[copy(_ostr(si.desc)) for si in rec.siginfo]

"""
    physical(rec::Record; legacy=false) -> Matrix{Float64}

Return the samples of `rec` in physical units, computed as
`(adc - baseline) / gain` for each signal. Invalid samples become `NaN`. The
result has the same shape as `rec.samples`.

Throws a [`WfdbError`](@ref) (`"signal N of record R is uncalibrated"`) if
the gain of a signal is 0. `legacy=true` behaves as the original package
(see [`wfdbx_set_legacy`](@ref)).

# Examples
The examples read `100s`, the first minute of record 100 of the MIT-BIH
Arrhythmia Database, which is included with wfdb-x in `tests/data` of a copy
of the wfdb-x repository:
```julia-repl
julia> wfdbx_set_input_dir("/path/to/wfdb-x/tests/data");

julia> rec = read_record("100s"; to=2);

julia> physical(rec)
2×2 Matrix{Float64}:
 -0.145  -0.065
 -0.145  -0.065
```

Part of wfdb-x; not in the original WFDB package.
"""
function physical(rec::Record; legacy::Bool=false)
    legacy = _legacy(lib(), legacy)     # the default library's mode
    out = Matrix{Float64}(undef, size(rec.samples))
    for s in 1:size(rec.samples, 2)
        si = rec.siginfo[s]
        g = si.gain
        if g == 0.0
            legacy || throw(WfdbError("signal $(rec.channels[s]) of record $(rec.name) is uncalibrated"))
            g = WFDB_DEFGAIN    # wfdb-x: legacy mode (original behavior)
        end
        b = Float64(si.baseline)
        for i in 1:size(rec.samples, 1)
            v = rec.samples[i, s]
            out[i, s] = v == WFDB_INVALID_SAMPLE ? NaN : (v - b) / g
        end
    end
    out
end

"""
    Annotations(; record="", annotator="", fs=0.0, samples=Int64[], codes=Int32[],
                symbols=Vector{UInt8}[], subtypes=Int32[], chans=Int32[],
                nums=Int32[], aux=Union{Nothing,Vector{UInt8}}[])

The contents of an annotation file, as returned by
[`read_annotations`](@ref) and written by [`write_annotations`](@ref).
Element `k` of each vector field describes annotation `k`. `length(ann)` is
the number of annotations.

# Fields
- `record::String`, `annotator::String`: the names that were read. They
  are not used by `write_annotations`.
- `fs::Float64`: the frequency in which `samples` are counted, or 0 if it
  is unknown.
- `samples::Vector{Int64}`: the annotation times, in samples.
- `codes::Vector{Int32}`: the annotation codes (`WFDBX.NORMAL`,
  `WFDBX.PVC`, ...).
- `symbols::Vector{Vector{UInt8}}`: the annotation mnemonics (`"N"`, `"V"`,
  ...), as bytes. When writing, a non-empty mnemonic is used instead of the
  code, and an empty one means "use `codes`".
- `subtypes`, `chans`, `nums` (`Vector{Int32}`): the subtype, channel and
  annotator number of each annotation.
- `aux::Vector{Union{Nothing,Vector{UInt8}}}`: the auxiliary text of each
  annotation as bytes, or `nothing`.

When writing, `codes`, `subtypes`, `chans`, `nums` and `aux` may be shorter
than `samples`. The missing elements are taken as 0, or no auxiliary text.

# Examples
The example writes the annotation file `100s.test` in the current directory
(the output directory), for the record `100s` (the sample record of
wfdb-x, the first minute of record 100 of the MIT-BIH Arrhythmia Database):
```julia-repl
julia> ann = Annotations(samples=[100, 460], symbols=[b"N", b"V"]);

julia> write_annotations("100s", "test", ann; fs=360)
```
"""
Base.@kwdef mutable struct Annotations
    record::String = ""
    annotator::String = ""
    fs::Float64 = 0.0
    samples::Vector{Int64} = Int64[]
    codes::Vector{Int32} = Int32[]
    symbols::Vector{Vector{UInt8}} = Vector{UInt8}[]
    subtypes::Vector{Int32} = Int32[]
    chans::Vector{Int32} = Int32[]
    nums::Vector{Int32} = Int32[]
    aux::Vector{Union{Nothing,Vector{UInt8}}} = Union{Nothing,Vector{UInt8}}[]
end
Base.length(a::Annotations) = length(a.samples)

function _hl_fail(w::Wfdb, msg::String)
    wfdbquit(w)
    throw(WfdbError(msg))
end

# wfdb-x: legacy mode (original behavior). A high-level call behaves as the
# original package if it asks for it (legacy=true) or if the library is in
# legacy mode (wfdbx_set_legacy).
_legacy(w::Wfdb, legacy::Bool) = legacy || wfdbx_get_legacy(w) != 0

# With legacy, run f() with the
# library's legacy mode on (see wfdbx_set_legacy), restoring the previous
# setting afterwards, also on errors; otherwise just run f().
function _with_legacy(f::Function, w::Wfdb, legacy::Bool)
    legacy || return f()
    previous = wfdbx_set_legacy(w, true)
    try
        f()
    finally
        wfdbx_set_legacy(w, previous)
    end
end

# wfdb-x: the dir keyword argument of the writers. With a directory, run f()
# with the library's output directory (wfdbx_set_output_dir) set to it,
# restoring the previous one afterwards, also on errors; the record name must
# not contain a directory, and the directory must exist (both checked before
# anything is written). Without one (nothing or ""), just run f().
function _with_output_dir(f::Function, w::Wfdb, record::ByteStr, dir)
    d = dir === nothing ? "" : String(copy(cstr(bytes(dir))))
    isempty(d) && return f()
    rec = cstr(bytes(record))
    (UInt8('/') in rec || (Sys.iswindows() && UInt8('\\') in rec)) &&
        throw(WfdbError("record name must not contain a directory when dir is given"))
    isdir(d) || throw(WfdbError("directory $d does not exist"))
    previous = wfdbx_set_output_dir(w, d)
    try
        f()
    finally
        wfdbx_set_output_dir(w, previous)
    end
end

# wfdb-x: the input_dir and network keyword arguments of the readers: if
# given (not nothing), the library's input directory (wfdbx_set_input_dir)
# and network permission (wfdbx_set_network) are set for the duration of
# f(), and the previous values restored afterwards (also on errors).
function _with_input_options(f::Function, w::Wfdb, input_dir, network)
    previous_dir = input_dir === nothing ? nothing : wfdbx_set_input_dir(w, input_dir)
    previous_net = network === nothing ? nothing : wfdbx_set_network(w, network)
    try
        f()
    finally
        network === nothing || wfdbx_set_network(w, previous_net)
        input_dir === nothing || wfdbx_set_input_dir(w, previous_dir)
    end
end

const _INPUT_DOC = """
- `input_dir`: the input directory for this call only: a local directory,
  a `~` path or a URL (see [`wfdbx_set_input_dir`](@ref)). `nothing`, the
  default, keeps the current setting.
- `network`: `true` turns network access on for this call only, and
  `false` turns it off (see [`wfdbx_set_network`](@ref)). `nothing`, the
  default, keeps the current setting."""

const _DIR_DOC = """
- `dir`: the directory in which to write, for this call only
  (see [`wfdbx_set_output_dir`](@ref)). It must exist, and `record` must
  not then contain a directory."""

const _LEGACY_DOC = """
- `legacy`: `true` behaves as the original WFDB package, for this call
  only (see [`wfdbx_set_legacy`](@ref)). Use it only to reproduce old
  results."""

# A time: a sample number, or a WFDB time string ("0:10", "s1000",
# "[12:00:00]", "e" for the end of the record; see strtim), converted for
# the record open in w (times of day give their absolute value). wfdb-x: a
# time string that needs the sampling frequency is an error if the record
# does not specify one (rname: the record name, for the message).
_resolve_time(w::Wfdb, t::Integer, rname::String) = Int64(t)
function _resolve_time(w::Wfdb, t::ByteStr, rname::String)
    if _tfreq(w.sig) <= 0.0 && wfdbx_time_needs_freq(w, t) != 0
        _hl_fail(w, "sampling frequency of record $rname is not specified")
    end
    x = strtim(w, t)
    x < 0 ? -x : x
end

"""
    read_header([w::Wfdb], record; input_dir=nothing, network=nothing,
                legacy=false) -> Header

Read the header of `record` without opening its signal files, and return it
as a [`Header`](@ref). `record` is a record name, which is read from the
input directory, or a full path, `~` path or URL.

# Keyword arguments
$_INPUT_DOC
$_LEGACY_DOC

Throws a [`WfdbError`](@ref) if the header cannot be read.

# Examples
The examples read `100s`, the first minute of record 100 of the MIT-BIH
Arrhythmia Database, which is included with wfdb-x in `tests/data` of a copy
of the wfdb-x repository:
```julia-repl
julia> wfdbx_set_input_dir("/path/to/wfdb-x/tests/data");

julia> h = read_header("100s");

julia> h.fs, h.nsamples, h.nsig
(360.0, 21600, 2)

julia> [String(s.desc) for s in h.siginfo]
2-element Vector{String}:
 "MLII"
 "V5"

julia> si = h.siginfo; si[1].fmt, si[1].gain, si[1].adcres, si[1].nsamp
(212, 200.0, 11, 21600)
```

Part of wfdb-x; not in the original WFDB package.
"""
function read_header(w::Wfdb, record::ByteStr; input_dir::OptByteStr=nothing,
                     network::Union{Nothing,Bool}=nothing, legacy::Bool=false)
    _with_legacy(w, legacy) do
        _with_input_options(() -> _read_header(w, record), w, input_dir, network)
    end
end
function _read_header(w::Wfdb, record::ByteStr)
    wfdbquit(w)
    n = isigopen(w, record, nothing, 0)
    n < 0 && _hl_fail(w, "can't read header for record $(_lossy(record))")
    si = [Siginfo() for _ in 1:n]
    n > 0 && isigopen(w, record, si, -n)
    st = w.sig
    fs = sampfreq(w, nothing)
    nsamples = st.in_msrec != 0 ? st.msnsamples : st.nsamples
    base_time, base_time_ms, base_date = _base_info(w, fs)
    h = Header(_lossy(record), fs, getcfreq(w), getbasecount(w), nsamples, Int(n), si,
               base_time, base_time_ms, base_date, Vector{UInt8}[])
    append!(h.comments, _comments(w, record))
    wfdbquit(w)
    h
end
read_header(record::ByteStr; kw...) = read_header(lib(), record; kw...)

"Number of frames read per call of `getvecs` by `read_record`."
const READ_BLOCK = 65536

"""
    read_record([w::Wfdb], record; channels=nothing, from=0, to=nothing,
                highres=false, pad=false, checksum_warning=true,
                input_dir=nothing, network=nothing, legacy=false) -> Record

Read the signals of `record`, or of part of it, and return them as a
[`Record`](@ref). The samples are in ADC units. Use [`physical`](@ref) to
convert them to physical units. `record` is a record name, which is read
from the input directory, or a full path, `~` path or URL.

# Keyword arguments
- `channels`: the signals to read, in the order given, by number (`0` is
  the first signal) or by name, such as `"V5"`. `nothing`, the default,
  reads all signals.
- `from`, `to`: the first sample, and the sample after the last one. An
  integer is a sample number. A string is a WFDB time string: `"0:10"`
  (10 seconds), `"1:02:03.5"`, `"s3600"` (sample 3600) or `"e"` (the end
  of the record). `to=nothing`, the default, reads to the end of the
  record.
- `highres`: `true` reads a multi-frequency record at its highest sampling
  frequency. `fs` is then that frequency.
- `pad`: `true` replaces each invalid sample by the previous valid sample
  of the same signal.
- `checksum_warning`: `true`, the default, logs a warning when the data do
  not match the checksums in the header. `false` turns it off.
$_INPUT_DOC
$_LEGACY_DOC

When the data do not match the checksums in the header, all the data are
returned, `checksum_ok` is `false`, and a warning is logged: `"checksum
error in record REC: the signal data do not match the checksums in its
header"`. Checksums are only checked when a read reaches the end of the
record.

Throws a [`WfdbError`](@ref) if:
- the record cannot be read, or has no signals;
- a signal in `channels` does not exist;
- `from` is beyond the end of the record;
- `from` or `to` is a time string that needs the sampling frequency, and
  the header gives none (`"sampling frequency of record REC is not
  specified"`);
- a signal file cannot be read to the length its header gives (`"can't
  read signal data of record REC (getvec status -3)"`).

# Examples
The examples read `100s`, the first minute of record 100 of the MIT-BIH
Arrhythmia Database, which is included with wfdb-x in `tests/data` of a copy
of the wfdb-x repository:
```julia-repl
julia> wfdbx_set_input_dir("/path/to/wfdb-x/tests/data");

julia> rec = read_record("100s"; to="0:10");   # the first 10 seconds

julia> size(rec.samples), rec.fs
((3600, 2), 360.0)

julia> rec.samples[1:3, :]
3×2 Matrix{Int32}:
 995  1011
 995  1011
 995  1011

julia> v5 = read_record("100s"; channels=["V5"], from="0:1", to="0:2");

julia> size(v5.samples), v5.sampfrom
((360, 1), 360)

julia> rec = read_record("100"; input_dir="https://physionet.org/files/mitdb/1.0.0/",
                         network=true);     # record 100 of the MIT-BIH Arrhythmia Database, from PhysioNet
```

Part of wfdb-x; not in the original WFDB package.
"""
function read_record(w::Wfdb, record::ByteStr; channels=nothing, from=0, to=nothing,
                     highres::Bool=false, pad::Bool=false, input_dir::OptByteStr=nothing,
                     network::Union{Nothing,Bool}=nothing, legacy::Bool=false,
                     checksum_warning::Bool=true)
    _with_legacy(w, legacy) do
        _with_input_options(w, input_dir, network) do
            _read_record(w, record, channels, from, to, highres, pad, checksum_warning)
        end
    end
end
function _read_record(w::Wfdb, record::ByteStr, channels, from, to, highres::Bool, pad::Bool,
                      checksum_warning::Bool)
    rname = _lossy(record)
    wfdbquit(w)
    nsig = isigopen(w, record, nothing, 0)
    nsig <= 0 && _hl_fail(w, "can't read record $rname")
    si = [Siginfo() for _ in 1:nsig]
    nsig = isigopen(w, record, si, nsig)
    nsig <= 0 && _hl_fail(w, "can't open signals of record $rname")
    nsig = Int(nsig)
    setgvmode(w, (highres ? WFDB_HIGHRES : WFDB_LOWRES) | (pad ? WFDB_GVPAD : Int32(0)))
    fs = sampfreq(w, nothing)
    t0 = _resolve_time(w, from, rname)
    t1 = to === nothing ? nothing : _resolve_time(w, to, rname)

    cols = Int[]
    if channels === nothing
        append!(cols, 1:nsig)
    else
        for c in channels
            k = findsig(w, c isa Integer ? string(c) : c)
            (k < 0 || k >= nsig) && _hl_fail(w, "record $rname has no signal $c")
            push!(cols, k + 1)
        end
    end
    base_time, base_time_ms, base_date = _base_info(w, fs)
    isigsettime(w, t0) < 0 && _hl_fail(w, "can't seek to sample $t0 of record $rname")

    # getvec returns one value per signal in either mode. The frames are
    # read straight into `all` (one column per frame), allocated once for
    # the number of frames to read if it is known (to, or the length of the
    # record), and grown only if more are read.
    st = w.sig
    remaining = t1 === nothing ? nothing : max(t1 - t0, Int64(0))
    rlen = (st.in_msrec != 0 ? st.msnsamples : st.nsamples) *
           ((st.gvmode & WFDB_HIGHRES) == WFDB_HIGHRES ? Int64(st.spfmax) : Int64(1))
    expect = remaining !== nothing ? remaining : rlen > t0 ? rlen - t0 : Int64(READ_BLOCK)
    expect = remaining !== nothing && rlen > t0 ? min(expect, rlen - t0) : expect
    # (not more than about 1 GiB at first: a header may overstate the length)
    expect = clamp(expect, Int64(1), max(Int64(1), (Int64(1) << 28) ÷ nsig))
    all = Vector{Int32}(undef, expect * nsig)
    nframes = Int64(0)
    cksum_error = false
    st.cksum_quiet = true
    try
        while remaining === nothing || remaining > 0
            n = remaining === nothing ? Int64(READ_BLOCK) : min(remaining, Int64(READ_BLOCK))
            nframes + n > length(all) ÷ nsig &&
                resize!(all, max(2 * length(all), (nframes + n) * nsig))
            got, stat = _getvecs_into(w, all, Int(nframes * nsig), n, true)
            got = max(got, Int64(0))
            nframes += got
            remaining === nothing || (remaining -= got)
            # wfdb-x: -4, a checksum error: the vector is complete, only the
            # sum of the samples does not match the header: a warning (see
            # below), not an error. In high-resolution mode each of the spf
            # vectors of the checksum frame has status -4: read on until -1
            # (the end of the data) or the requested end.
            if stat == -4
                cksum_error = true
                got > 0 && continue
                break
            end
            if got < n
                # wfdb-x: a status below -1 (e.g. -3, unexpected EOF: a
                # signal file shorter than its header says, or a decoder or
                # I/O error) is an error, not the end of the data (-1).
                stat < -1 && _hl_fail(w, "can't read signal data of record $rname (getvec status $stat)")
                break
            end
        end
    finally
        w.sig.cksum_quiet = false
    end
    (cksum_error && checksum_warning) &&
        @warn "checksum error in record $rname: the signal data do not match the checksums in its header"
    samples = _frames_to_samples(all, nsig, Int(nframes), cols)
    comments = _comments(w, record)
    wfdbquit(w)
    Record(rname, fs, samples, Siginfo[si[k] for k in cols], base_time, base_time_ms,
           base_date, t0, comments, Int[k - 1 for k in cols], !cksum_error)
end

# The samples matrix (one row per frame, one column per element of cols)
# of the first nframes frames stored in v (nsig values per frame).
function _frames_to_samples(v::Vector{Int32}, nsig::Int, nframes::Int, cols::Vector{Int})
    frames = reshape(view(v, 1:nsig*nframes), nsig, nframes)
    cols == 1:nsig && return permutedims(frames)
    samples = Matrix{Int32}(undef, nframes, length(cols))
    for (j, c) in enumerate(cols)
        @inbounds for i in 1:nframes
            samples[i, j] = frames[c, i]
        end
    end
    samples
end
read_record(record::ByteStr; kw...) = read_record(lib(), record; kw...)

"""
    read_annotations([w::Wfdb], record, annotator; from=nothing, to=nothing,
                     fs=nothing, input_dir=nothing, network=nothing,
                     legacy=false) -> Annotations

Read the annotation file of `record` written by `annotator`, and return its
annotations as an [`Annotations`](@ref) object, in file order. `annotator`
is the file suffix: `"atr"` reads `100s.atr` for record `"100s"`.

# Keyword arguments
- `from`, `to`: return only the annotations from `from` up to, but not
  including, `to`. Each is a sample number or a time string, as in
  [`read_record`](@ref). `nothing` means the beginning or the end of the
  file.
- `fs`: the sampling frequency to use when the record has no header, or
  its header gives none. It must be positive.
$_INPUT_DOC
$_LEGACY_DOC

Throws a [`WfdbError`](@ref) if the annotation file cannot be read, if `fs`
is not positive, if `from` or `to` is a time string that needs a
sampling frequency and none is known (`"sampling frequency of record REC is
not specified"`), or if reading ends with an error before `to` is reached,
such as a truncated file (`"can't read annotation file ANN of record REC
(getann status -3)"`).

# Examples
The examples read `100s`, the first minute of record 100 of the MIT-BIH
Arrhythmia Database, which is included with wfdb-x in `tests/data` of a copy
of the wfdb-x repository:
```julia-repl
julia> wfdbx_set_input_dir("/path/to/wfdb-x/tests/data");

julia> ann = read_annotations("100s", "atr");

julia> length(ann), ann.fs
(75, 360.0)

julia> ann.samples[1:3], String.(ann.symbols[1:3])
([18, 77, 370], ["+", "N", "N"])

julia> length(read_annotations("100s", "atr"; from="0:10", to="0:20"))
12
```

Part of wfdb-x; not in the original WFDB package.
"""
function read_annotations(w::Wfdb, record::ByteStr, annotator::ByteStr; from=nothing,
                          to=nothing, fs::Union{Nothing,Real}=nothing,
                          input_dir::OptByteStr=nothing, network::Union{Nothing,Bool}=nothing,
                          legacy::Bool=false)
    fs === nothing || fs > 0.0 || throw(WfdbError("read_annotations: fs must be > 0"))
    legacy = _legacy(w, legacy)
    _with_legacy(w, legacy) do
        _with_input_options(w, input_dir, network) do
            _read_annotations(w, record, annotator, from, to, fs, legacy)
        end
    end
end
function _read_annotations(w::Wfdb, record::ByteStr, annotator::ByteStr, from, to,
                           fs::Union{Nothing,Real}, legacy::Bool)
    rname = _lossy(record)
    wfdbquit(w)
    # wfdb-x: no default sampling frequency (C tools assumed 250 Hz).
    sf = sampfreq(w, record)
    if sf <= 0.0 && fs !== nothing
        setsampfreq(w, fs)
    elseif sf < 0.0 && legacy
        setsampfreq(w, WFDB_DEFFREQ)    # wfdb-x: legacy mode (original behavior)
    end
    ai = [Anninfo(annotator, WFDB_READ)]
    if annopen(w, record, ai, 1) < 0
        _hl_fail(w, "can't read annotator $(_lossy(annotator)) for record $rname")
    end
    t0 = from === nothing ? Int64(0) : _resolve_time(w, from, rname)
    t1 = to === nothing ? nothing : _resolve_time(w, to, rname)
    if t0 != 0 && iannsettime(w, t0) < 0
        _hl_fail(w, "can't seek in annotator $(_lossy(annotator))")
    end
    res = Annotations(record=_lossy(record), annotator=_lossy(annotator))
    a = Annotation()
    stat = Int32(0)
    while (stat = getann(w, 0, a)) == 0
        (t1 !== nothing && a.time >= t1) && break
        push!(res.samples, a.time)
        push!(res.codes, Int32(a.anntyp))
        sym = annstr(w, Int32(a.anntyp))
        push!(res.symbols, sym === nothing ? UInt8[] : Vector{UInt8}(sym))
        push!(res.subtypes, Int32(a.subtyp))
        push!(res.chans, Int32(a.chan))
        push!(res.nums, Int32(a.num))
        x = a.aux
        if x !== nothing && !isempty(x)
            len = Int(x[1])
            push!(res.aux, copy(cstr(x[2:min(1 + len, length(x))])))
        else
            push!(res.aux, nothing)
        end
    end
    # wfdb-x: a status other than 0 and -1 (e.g. -3, unexpected EOF, or an
    # I/O error) is an error, not the end of the file.
    (stat == 0 || stat == -1) ||
        _hl_fail(w, "can't read annotation file $(_lossy(annotator)) of record $rname (getann status $stat)")
    res.fs = getiafreq(w, 0)
    wfdbquit(w)
    res
end
read_annotations(record::ByteStr, annotator::ByteStr; kw...) =
    read_annotations(lib(), record, annotator; kw...)

# The value of a per-signal option for signal k: a scalar applies to every
# signal; a vector holds one value for all signals or one per signal.
_per_signal(v, k::Int, dflt) = v
_per_signal(::Nothing, k::Int, dflt) = dflt
function _per_signal(v::AbstractVector, k::Int, dflt)
    isempty(v) && return dflt
    length(v) == 1 ? v[1] : k <= length(v) ? v[k] : dflt
end

_optbytes(x) = x === nothing ? nothing : copy(cstr(bytes(x)))

# wfdb-x: the gain of signal k (0-based k-1 in messages) is required (the C
# tools assumed WFDB_DEFGAIN, 200 adu/mV, as legacy mode does); 0 means
# uncalibrated.
function _gain(gains, k::Int, legacy::Bool)
    g = _per_signal(gains, k, legacy ? WFDB_DEFGAIN : nothing)
    g === nothing && throw(WfdbError("write_record: gains must be specified"))
    Float64(g)
end

# The ADC resolution that write_record used by default for signal format
# fmt before wfdb-x (legacy mode): 8 for formats 80 and 508, 10 for 310 and
# 311, 12 for 212, 24 for 24 and 524, 32 for 32, and 16 otherwise.
_legacy_write_adcres(fmt::Integer) =
    (fmt == 80 || fmt == 508) ? Int32(8) : fmt == 212 ? Int32(12) :
    (fmt == 310 || fmt == 311) ? Int32(10) : (fmt == 24 || fmt == 524) ? Int32(24) :
    fmt == 32 ? Int32(32) : Int32(16)

# wfdb-x: the ADC resolution of signal k is required (the C tools inferred
# it from the format or assumed WFDB_DEFRES, 12 bits, as legacy mode does);
# it must be >= 1.
function _adcres(adcres, k::Int, fmt::Integer, legacy::Bool)
    legacy && return Int32(_per_signal(adcres, k, _legacy_write_adcres(fmt)))
    r = _per_signal(adcres, k, nothing)
    (r === nothing || r < 1) &&
        throw(WfdbError("write_record: ADC resolution(s) must be specified"))
    Int32(r)
end

# wfdb-x: the units of a calibrated signal (gain != 0) are required (the C
# tools left them out, and readers assumed millivolts; legacy mode does not
# require them).
function _units(units, k::Int, gain::Float64, legacy::Bool)
    u = _optbytes(_per_signal(units, k, nothing))
    (!legacy && gain != 0.0 && (u === nothing || isempty(u))) &&
        throw(WfdbError("write_record: units must be specified"))
    u
end

# Each frame holds samps_per_frame[k] >= 1 samples of signal k, and each row
# of samples is one frame (checked before the other arguments).
function _check_samps_per_frame(samples::AbstractMatrix, samps_per_frame)
    samps_per_frame === nothing && return nothing
    nsig = samps_per_frame isa AbstractVector ? length(samps_per_frame) : size(samples, 2)
    framesize = 0
    for k in 1:nsig
        n = _per_signal(samps_per_frame, k, 1)
        (n isa Real && isinteger(n) && n >= 1) ||
            throw(WfdbError("write_record: samps_per_frame must hold integers >= 1"))
        framesize += Int(n)
    end
    size(samples, 2) == framesize ||
        throw(WfdbError("write_record: signals has $(size(samples, 2)) columns, but " *
                        "samps_per_frame adds up to $framesize"))
    nothing
end

function _check_fs(fs::Real)
    fs > 0.0 || throw(WfdbError("write_record: the sampling frequency must be > 0"))
    nothing
end

function _write_adc(w::Wfdb, record::ByteStr, frames::AbstractMatrix{<:Integer}, fs::Real;
                    nsig::Integer, fmt::Integer, gains, baselines, adczeros, adcres, units,
                    names, samps_per_frame, base_time, comments, legacy::Bool)
    nsig == 0 && throw(WfdbError("write_record: no signals"))
    legacy || _check_fs(fs)
    rec = copy(cstr(bytes(record)))
    fname = vcat(rec, b".dat")
    si = [Siginfo() for _ in 1:nsig]
    framesize = 0
    for k in 1:nsig
        s = si[k]
        s.fname = copy(fname)
        s.desc = something(_optbytes(_per_signal(names, k, nothing)), UInt8[])
        s.gain = _gain(gains, k, legacy)
        s.adcres = _adcres(adcres, k, fmt, legacy)
        s.units = _units(units, k, s.gain, legacy)
        s.fmt = Int32(fmt)
        s.spf = Int32(_per_signal(samps_per_frame, k, 1))
        s.adczero = Int32(_per_signal(adczeros, k, 0))
        s.baseline = Int32(_per_signal(baselines, k, s.adczero))
        framesize += max(s.spf, 1)
    end
    size(frames, 2) == framesize ||
        throw(WfdbError("write_record: the number of columns is not the frame size ($framesize)"))
    wfdbquit(w)
    errors = wfdbx_write_errors()
    osigfopen(w, si, nsig) != nsig && _hl_fail(w, "can't create signal file for record $(_lossy(rec))")
    setsampfreq(w, fs)
    # The counter frequency and base count survive wfdbquit() (as in the C
    # library); a new record written here has neither.
    setcfreq(w, 0.0)
    setbasecount(w, 0.0)
    base_time === nothing || setbasetime(w, base_time)
    v = zeros(Int32, framesize)
    for i in 1:size(frames, 1)
        for j in 1:framesize
            v[j] = frames[i, j] % Int32
        end
        putvec(w, v)
    end
    newheader(w, rec) < 0 && _hl_fail(w, "can't create header for record $(_lossy(rec))")
    for c in comments
        putinfo(w, c)
    end
    wfdbquit(w)
    wfdbx_write_errors() > errors && throw(WfdbError("write error on record $(_lossy(rec))"))
    nothing
end

"""
    write_record([w::Wfdb], record, samples::AbstractMatrix{<:Integer}, fs;
                 gains, adcres, units, fmt=16, baselines=nothing, adczeros=0,
                 names=nothing, samps_per_frame=nothing, base_time=nothing,
                 comments=(), dir=nothing, legacy=false)

Write a record: the header `RECORD.hea` and the signal file `RECORD.dat`.
The files are created in the output directory, or in `dir`. Existing files
are overwritten. Returns `nothing`.

`samples` holds the samples in ADC units, one row per sample and one
column per signal. `fs` is the sampling frequency in Hz. To write samples
in physical units, use [`write_record_physical`](@ref).

You must give the gain and ADC resolution of each signal, and the units of
each calibrated signal; there are no defaults. Per-signal options take one
value for all signals, or a vector with one value per signal.

# Keyword arguments
- `gains` (required): ADC units per physical unit. A gain of 0 marks a
  signal as uncalibrated.
- `adcres` (required): the ADC resolution in bits, at least 1.
- `units` (required unless the gain is 0): the physical units, such as
  `"mV"`.
- `fmt`: the storage format, such as 16, 212, 24 or 516 (FLAC), for all
  signals. The default is 16.
- `baselines`: the ADC value of 0 physical units. The default is the
  signal's `adczero`.
- `adczeros`: the ADC value of 0 volts. The default is 0.
- `names`: the signal descriptions. The default is none.
- `samps_per_frame`: the number of samples per frame of each signal, for a
  multi-frequency record. Each row of `samples` then holds
  `samps_per_frame[s]` consecutive columns for signal `s`. The default is 1.
- `base_time`: the start time and date, as `"hh:mm:ss dd/mm/yyyy"`.
- `comments`: info strings, written at the end of the header.
$_DIR_DOC
$_LEGACY_DOC

Throws a [`WfdbError`](@ref) if:
- `gains`, `adcres` or `units` is missing (`"write_record: gains must be
  specified"`, `"write_record: ADC resolution(s) must be specified"`,
  `"write_record: units must be specified"`);
- a `samps_per_frame` value is not an integer >= 1 (`"write_record:
  samps_per_frame must hold integers >= 1"`), or the number of columns of
  `samples` is not their sum (`"write_record: signals has N columns, but
  samps_per_frame adds up to M"`); these are checked first, and nothing is
  written;
- `fs` is not positive;
- the number of columns of `samples` does not match the signals;
- a file cannot be created, or cannot be written completely (for example,
  when the disk is full: `"write error on record R"`);
- `dir` does not exist, or `record` contains a directory and `dir` is given.

# Examples
The examples read `100s`, the first minute of record 100 of the MIT-BIH
Arrhythmia Database, which is included with wfdb-x in `tests/data` of a copy
of the wfdb-x repository; the record `new` is written by the example, in
the current directory (the output directory):
```julia-repl
julia> wfdbx_set_input_dir("/path/to/wfdb-x/tests/data");

julia> rec = read_record("100s"; to="0:10");

julia> write_record("new", rec.samples, rec.fs; fmt=212, gains=200.0, adcres=11,
                    units="mV", names=["MLII", "V5"])

julia> print(read("new.hea", String))
new 2 360 3600
new.dat 212 200/mV 11 0 995 -17352 0 MLII
new.dat 212 200/mV 11 0 1011 1171 0 V5
```

Part of wfdb-x; not in the original WFDB package.
"""
function write_record(w::Wfdb, record::ByteStr, samples::AbstractMatrix{<:Integer}, fs::Real;
                      fmt::Integer=16, gains=nothing, baselines=nothing, adczeros=0,
                      adcres=nothing, units=nothing, names=nothing, samps_per_frame=nothing,
                      base_time=nothing, comments=(), dir=nothing, legacy::Bool=false)
    _check_samps_per_frame(samples, samps_per_frame)
    legacy = _legacy(w, legacy)
    nsig = samps_per_frame isa AbstractVector ? length(samps_per_frame) : size(samples, 2)
    _with_legacy(w, legacy) do
        _with_output_dir(w, record, dir) do
            _write_adc(w, record, samples, fs; nsig, fmt, gains, baselines, adczeros, adcres,
                       units, names, samps_per_frame, base_time, comments, legacy)
        end
    end
end
write_record(record::ByteStr, samples::AbstractMatrix{<:Integer}, fs::Real; kw...) =
    write_record(lib(), record, samples, fs; kw...)

"""
    write_record_physical([w::Wfdb], record, samples::AbstractMatrix{<:Real}, fs;
                          gains, adcres, units, options...)

Write a record as [`write_record`](@ref) does, from samples in physical
units. Each value `v` is stored as `round(v * gain) + baseline`, with
halfway cases rounded away from zero. `NaN` is stored as an invalid
sample. The keyword arguments are those of `write_record`. Returns
`nothing`.

Throws a [`WfdbError`](@ref) in the cases listed for `write_record`, and if
a gain is 0 (`"write_record: signal N is uncalibrated"`, where `N` counts
from 0).

# Examples
The example writes the record `rand` (random samples), in the current
directory (the output directory):
```julia-repl
julia> x = randn(3600, 2);

julia> write_record_physical("rand", x, 360; gains=1000, adcres=16, units="mV",
                             names=["A", "B"])
```

Part of wfdb-x; not in the original WFDB package.
"""
function write_record_physical(w::Wfdb, record::ByteStr, samples::AbstractMatrix{<:Real}, fs::Real;
                               fmt::Integer=16, gains=nothing, baselines=nothing,
                               adczeros=0, adcres=nothing, units=nothing, names=nothing,
                               samps_per_frame=nothing, base_time=nothing, comments=(),
                               dir=nothing, legacy::Bool=false)
    _check_samps_per_frame(samples, samps_per_frame)
    legacy = _legacy(w, legacy)
    # wfdb-x: the dir checks come first (after those of samps_per_frame)
    _with_output_dir(w, record, dir) do
        nsig = samps_per_frame isa AbstractVector ? length(samps_per_frame) : size(samples, 2)
        # Gain and baseline of each column of a frame
        g = Float64[]
        b = Int32[]
        for k in 1:nsig
            gain = _gain(gains, k, legacy)
            if gain == 0.0
                legacy || throw(WfdbError("write_record: signal $(k - 1) is uncalibrated"))
                gain = WFDB_DEFGAIN     # wfdb-x: legacy mode (original behavior)
            end
            zero_ = Int32(_per_signal(adczeros, k, 0))
            base = Int32(_per_signal(baselines, k, zero_))
            for _ in 1:max(Int(_per_signal(samps_per_frame, k, 1)), 1)
                push!(g, gain)
                push!(b, base)
            end
        end
        isempty(g) && throw(WfdbError("write_record: no signals"))
        legacy || _check_fs(fs)
        size(samples, 2) == length(g) ||
            throw(WfdbError("write_record: the number of columns is not the frame size ($(length(g)))"))
        adc = Matrix{Int32}(undef, size(samples))
        for c in 1:size(samples, 2), i in 1:size(samples, 1)
            v = samples[i, c] * g[c]
            adc[i, c] = isnan(v) ? WFDB_INVALID_SAMPLE :
                        d2i((v >= 0.0 ? trunc(v + 0.5) : trunc(v - 0.5)) + b[c])
        end
        _with_legacy(w, legacy) do
            _write_adc(w, record, adc, fs; nsig, fmt, gains, baselines, adczeros, adcres,
                       units, names, samps_per_frame, base_time, comments, legacy)
        end
    end
end
write_record_physical(record::ByteStr, samples::AbstractMatrix{<:Real}, fs::Real; kw...) =
    write_record_physical(lib(), record, samples, fs; kw...)

"""
    write_annotations([w::Wfdb], record, annotator, ann::Annotations; fs=0.0,
                      sort=nothing, dir=nothing, legacy=false)

Write the annotations `ann` to the annotation file `RECORD.ANNOTATOR`, in
the output directory or in `dir`. An existing file is overwritten. Returns
`nothing`.

The type of each annotation is its mnemonic in `ann.symbols` if that is not
empty, and its code in `ann.codes` otherwise. Auxiliary text longer than
255 bytes is truncated.

# Keyword arguments
- `fs`: if positive, it is recorded in the file as the frequency in which
  the annotation times are counted. Otherwise readers use the record's
  sampling frequency. `ann.fs` is not used.
- `sort`: if the annotations are not in time order, the file is sorted
  when it is written. `false` keeps the order you gave (without the
  library's advice to run `sortann`) and `true` always sorts, for this
  call only. With `nothing`, the default, the environment
  variable `WFDBANNSORT` decides: sorting is on unless it is `0`.
$_DIR_DOC
$_LEGACY_DOC

Throws a [`WfdbError`](@ref) if the file cannot be created, or cannot be
written completely (`"write error on annotator A for record R"`), if `dir`
does not exist, or if `record` contains a directory and `dir` is given.

# Examples
The examples read `100s`, the first minute of record 100 of the MIT-BIH
Arrhythmia Database, which is included with wfdb-x in `tests/data` of a copy
of the wfdb-x repository; the annotation files `100s.cpy` and `100s.qrs`
are written by the example, in the current directory (the output directory):
```julia-repl
julia> wfdbx_set_input_dir("/path/to/wfdb-x/tests/data");

julia> ann = read_annotations("100s", "atr");

julia> write_annotations("100s", "cpy", ann; fs=360)   # writes ./100s.cpy

julia> read_annotations("100s", "cpy"; input_dir=".").samples == ann.samples
true

julia> write_annotations("100s", "qrs", Annotations(samples=[100, 460], symbols=[b"N", b"V"]))
```

Part of wfdb-x; not in the original WFDB package.
"""
function write_annotations(w::Wfdb, record::ByteStr, annotator::ByteStr, ann::Annotations;
                           fs::Real=0.0, sort::Union{Nothing,Bool}=nothing, dir=nothing,
                           legacy::Bool=false)
    _with_legacy(w, legacy) do
        _with_output_dir(w, record, dir) do
            # wfdb-x: the sort option, read by oannclose (see AnnState)
            previous = w.ann.sort_override
            w.ann.sort_override = sort
            try
                _write_annotations(w, record, annotator, ann, fs)
            finally
                w.ann.sort_override = previous
            end
        end
    end
end
function _write_annotations(w::Wfdb, record::ByteStr, annotator::ByteStr, ann::Annotations,
                            fs::Real)
    n = length(ann.samples)
    wfdbquit(w)
    errors = wfdbx_write_errors()
    fs > 0.0 && setafreq(w, fs)
    ai = [Anninfo(annotator, WFDB_WRITE)]
    if annopen(w, record, ai, 1) < 0
        fs > 0.0 && setafreq(w, 0.0)
        _hl_fail(w, "can't create annotator $(_lossy(annotator)) for record $(_lossy(record))")
    end
    for k in 1:n
        a = Annotation(time=ann.samples[k])
        if k <= length(ann.symbols) && !isempty(ann.symbols[k])
            a.anntyp = strann(w, ann.symbols[k]) % Int8
        elseif k <= length(ann.codes)
            a.anntyp = ann.codes[k] % Int8
        end
        k <= length(ann.subtypes) && (a.subtyp = ann.subtypes[k] % Int8)
        k <= length(ann.chans) && (a.chan = ann.chans[k] % UInt8)
        k <= length(ann.nums) && (a.num = ann.nums[k] % Int8)
        if k <= length(ann.aux) && ann.aux[k] !== nothing
            x = bytes(ann.aux[k])
            data = x[1:min(length(x), AUX_MAX)]
            a.aux = vcat(UInt8(length(data)), data)
        end
        putann(w, 0, a)
    end
    wfdbquit(w)
    fs > 0.0 && setafreq(w, 0.0)
    wfdbx_write_errors() > errors &&
        throw(WfdbError("write error on annotator $(_lossy(annotator)) for record $(_lossy(record))"))
    nothing
end
write_annotations(record::ByteStr, annotator::ByteStr, ann::Annotations; kw...) =
    write_annotations(lib(), record, annotator, ann; kw...)

export WfdbError, Record, Header, Annotations, read_header, read_record, read_annotations,
       write_record, write_record_physical, write_annotations, physical, signal_names

function _workload_hl_error(f::Function)
    try
        f()
    catch e
        e isa WfdbError || rethrow()
    end
    nothing
end

register_workload("highlevel") do
    with_workload_data() do dir
        w = Wfdb()
        wfdbquiet(w)
        setwfdb(w, ".")
        read_header(w, "100s")
        rec = read_record(w, "100s"; to="0:1")
        physical(rec); signal_names(rec)
        read_record(w, "100s"; channels=[1], from=10, to=20, highres=true, pad=true)
        write_record(w, "hlw", rec.samples, rec.fs; gains=[200.0], adcres=[11], units="mV",
                     names=["a", "b"], comments=["c"], base_time="12:00:00 01/01/2020")
        write_record_physical(w, "hlp", physical(rec), rec.fs; fmt=212, units="mV",
                              gains=200.0, adcres=12)
        read_annotations(w, "100s", "atr"; from="0:1", to="0:2")
        _workload_hl_error(() -> read_record(w, "nosuch"))
    end
    # wfdb-x: the paths without a default sampling frequency or gain
    with_workload_data(files=NODEFAULTS_FILES) do dir
        w = Wfdb()
        wfdbquiet(w)
        setwfdb(w, ".")
        cp("100s.atr", "nh.atr")
        r = read_record(w, "nf"; from="s2", to=5)
        physical(r)
        _workload_hl_error(() -> read_record(w, "nf"; to="0:1"))
        u = read_record(w, "uc"; to=3)
        _workload_hl_error(() -> physical(u))
        x = Int32[1 2; 3 4]
        _workload_hl_error(() -> write_record(w, "wn", x, 100.0))
        _workload_hl_error(() -> write_record(w, "wn", x, 0.0; gains=200.0, adcres=16,
                                              units="mV"))
        _workload_hl_error(() -> write_record(w, "wn", x, 100.0; gains=200.0))
        _workload_hl_error(() -> write_record(w, "wn", x, 100.0; gains=200.0, adcres=[16, 0]))
        _workload_hl_error(() -> write_record(w, "wn", x, 100.0; gains=200.0, adcres=16))
        write_record(w, "wn", x, 100.0; gains=[0.0, 50.0], adcres=16, units=[nothing, "uV"])
        read_record(w, "nr"; to=3)
        _workload_hl_error(() -> write_record_physical(w, "wp", [1.0 2.0], 100.0;
                                                       gains=[200.0, 0.0], adcres=16,
                                                       units="mV"))
        read_annotations(w, "nh", "atr")
        read_annotations(w, "nh", "atr"; fs=360, from="0:1", to=1000)
        read_annotations(w, "nh", "atr"; fs=360.0)
        _workload_hl_error(() -> read_annotations(w, "nh", "atr"; to="0:10"))
        _workload_hl_error(() -> read_annotations(w, "nh", "atr"; fs=0))
        # wfdb-x: legacy mode (original behavior)
        read_header(w, "nr"; legacy=true)
        r = read_record(w, "nf"; to="0:1", legacy=true)
        physical(read_record(w, "uc"; to=3, legacy=true); legacy=true)
        write_record(w, "wl", x, 100.0; legacy=true)
        write_record(w, "wl", x, 100.0; fmt=212, gains=[0.0, 50.0], legacy=true)
        write_record_physical(w, "wl", [1.0 2.0], 100.0; gains=[0.0, 100.0], legacy=true)
        read_annotations(w, "nh", "atr"; to="0:10", legacy=true)
        read_annotations(w, "nh", "atr"; legacy=true)
        write_annotations(w, "nh", "cpy", read_annotations(w, "nh", "atr"; fs=360); legacy=true)
        write_annotations(w, "nh", "srt", Annotations(samples=[2, 1], codes=Int32[1, 1]);
                          sort=true)
        _workload_hl_error(() -> read_record(w, "nosuch"; legacy=true))
    end
end
