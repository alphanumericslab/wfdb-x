# highlevel.jl: high-level API: read and write whole records and annotation
# files (read_record, read_header, read_annotations, write_record,
# write_record_physical, write_annotations), built on the C-style API.
#
# These functions read and write exactly what the WFDB library and the
# command-line tools do. Each takes an optional `Wfdb` first argument (the
# default instance otherwise), whose state it uses and resets with
# `wfdbquit`. Errors are thrown as `WfdbError`.
#
#     rec = read_record("100s"; to="0:10")      # the first 10 seconds
#     rec.samples                               # Matrix{Int32}: frame × signal
#     physical(rec)                             # Matrix{Float64} (NaN: invalid)
#     ann = read_annotations("100s", "atr")
#     write_record("new", rec.samples, rec.fs; gains=[200.0], adcres=11,
#                  units="mV", names=["a", "b"])
#
# wfdb-x: no sampling frequency, gain, ADC resolution or units are ever
# assumed (the C library assumed 250 Hz, 200 adu/mV, 12 bits or a resolution
# based on the format, and millivolts): see docs/DIVERGENCES.md. Each
# function has a `legacy=false` keyword argument: with `legacy=true`, it
# behaves as the original package did (see `_with_legacy`).
#
# Strings read from files (signal descriptions, comments, annotation
# mnemonics and aux strings) are byte strings (`Vector{UInt8}`), as
# everywhere in the library; string arguments may be `String`s.
#
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV, 12
# bits and millivolts), because a silently assumed value corrupts every result
# derived from it. See docs/DIVERGENCES.md. The original behavior remains
# available with --legacy (see docs/DIVERGENCES.md).
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

"""
    WfdbError(msg)

Exception thrown by the high-level functions ([`read_record`](@ref),
[`write_annotations`](@ref), ...) when an operation fails. `msg` says what
failed, e.g. `"can't read record 100x"`. The WFDB library may also have
printed a more specific message on the standard error (see
[`wfdbquiet`](@ref)).
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
- `fs::Float64`: the sampling frequency (Hz) of the returned samples.
- `samples::Matrix{Int32}`: the samples in ADC units, one row per sample
  time and one column per returned signal: `samples[i, s]` is sample `i`
  of the `s`-th returned signal. Invalid samples are
  `WFDB_INVALID_SAMPLE`. Use [`physical`](@ref) for physical units.
- `siginfo::Vector{Siginfo}`: the description of each returned signal
  (gain, baseline, units, format, ...; see [`Siginfo`](@ref)).
- `base_time::Union{String,Nothing}`: the base time and date of the record,
  as [`timstr`](@ref) formats it (e.g. `"[08:45:00 01/01/2001]"`), or
  `nothing` if the header gives none.
- `sampfrom::Int64`: the sample number of the first returned sample.
- `comments::Vector{Vector{UInt8}}`: the info strings (comment lines) of the
  header and of the `.info` file, if any, as bytes.
- `channels::Vector{Int}`: the number of each returned signal in the record
  (`0` is the first signal of the record).

`fs` is 0 if the header does not specify the sampling frequency; in
`siginfo`, `adcres` is 0 if the header does not specify a signal's ADC
resolution, and `units` is `nothing` if it does not specify its units
(wfdb-x: the C library assumed 250 Hz, a resolution based on the format or
12 bits, and millivolts; see `docs/DIVERGENCES.md`).

See also [`signal_names`](@ref).
"""
struct Record
    name::String
    fs::Float64
    samples::Matrix{Int32}
    siginfo::Vector{Siginfo}
    base_time::Union{Nothing,String}
    sampfrom::Int64
    comments::Vector{Vector{UInt8}}
    channels::Vector{Int}
end

"""
    signal_names(rec::Record) -> Vector{Vector{UInt8}}

Return the description (`desc` field, e.g. `"MLII"`) of each signal of
`rec`, as bytes. Use `String.(signal_names(rec))` to get `String`s.
"""
signal_names(rec::Record) = Vector{UInt8}[copy(_ostr(si.desc)) for si in rec.siginfo]

"""
    physical(rec::Record; legacy=false) -> Matrix{Float64}

Return the samples of `rec` converted to physical units (e.g. mV):
`(adc - baseline) / gain` for each signal. Invalid samples become `NaN`. The
result has the same shape as `rec.samples`.

Throws a [`WfdbError`](@ref) (`"signal N of record R is uncalibrated"`) if
the gain of a signal of `rec` is 0 (wfdb-x: no default gain; the C library
assumed 200 adu/mV; see `docs/DIVERGENCES.md`). With `legacy=true`, a gain
of 0 is taken as `WFDB_DEFGAIN` (200), as in the original package (kept
for compatibility only: see [`read_record`](@ref)).

# Examples
```julia-repl
julia> rec = read_record("100s"; to=2);

julia> physical(rec)
2×2 Matrix{Float64}:
 -0.145  -0.065
 -0.145  -0.065
```
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
Annotation `k` is described by element `k` of each vector field;
`length(ann)` is the number of annotations.

# Fields
- `record::String`, `annotator::String`: the record and annotator names
  (set by `read_annotations`; not used by `write_annotations`).
- `fs::Float64`: the time resolution of the annotation times (ticks per
  second; usually the sampling frequency).
- `samples::Vector{Int64}`: the annotation times, in ticks (sample numbers).
- `codes::Vector{Int32}`: the annotation type codes (e.g. 1 for a normal
  beat, `N`).
- `symbols::Vector{Vector{UInt8}}`: the annotation mnemonics (e.g. `"N"`),
  as [`annstr`](@ref) returns them. When writing, a non-empty mnemonic takes
  precedence over the code; an empty one means "use `codes`".
- `subtypes`, `chans`, `nums` (`Vector{Int32}`): the `subtyp`, `chan` and
  `num` fields of each annotation.
- `aux::Vector{Union{Nothing,Vector{UInt8}}}`: the auxiliary data of each
  annotation (without the leading length byte of
  [`Annotation`](@ref)`.aux`), or `nothing` if it has none.

When writing, missing trailing elements of `codes`, `subtypes`, `chans`,
`nums` and `aux` are taken as 0 (or no aux data).

# Examples
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

const _LEGACY_DOC = """
`legacy=true` reproduces the original package (wfdb-x legacy mode, see
`docs/DIVERGENCES.md`): the library's legacy mode is on during the call
(see [`wfdbx_set_legacy`](@ref)), and the defaults removed by wfdb-x apply
again (250 Hz, 200 adu per physical unit, an ADC resolution based on the
format). Kept for compatibility only: the values it assumes are exactly
the silent defaults wfdb-x removed, so results produced with it carry the
same risks."""

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
    read_header([w::Wfdb], record; legacy=false) -> Vector{Siginfo}

Read the header file of `record` and return the description of each of its
signals (file name, format, gain, baseline, units, description, ...; see
[`Siginfo`](@ref)). The signal files are not opened. A record with no
signals gives an empty vector.

Throws a [`WfdbError`](@ref) if the header cannot be found or read.

$_LEGACY_DOC

# Examples
```julia-repl
julia> si = read_header("100s");

julia> [String(s.desc) for s in si]
2-element Vector{String}:
 "MLII"
 "V5"

julia> si[1].fmt, si[1].gain, si[1].adcres, si[1].nsamp
(212, 200.0, 11, 21600)
```
"""
read_header(w::Wfdb, record::ByteStr; legacy::Bool=false) =
    _with_legacy(() -> _read_header(w, record), w, legacy)
function _read_header(w::Wfdb, record::ByteStr)
    wfdbquit(w)
    n = isigopen(w, record, nothing, 0)
    n < 0 && _hl_fail(w, "can't read header for record $(_lossy(record))")
    si = [Siginfo() for _ in 1:n]
    n > 0 && isigopen(w, record, si, -n)
    wfdbquit(w)
    si
end
read_header(record::ByteStr; kw...) = read_header(lib(), record; kw...)

"Number of frames read per call of `getvecs` by `read_record`."
const READ_BLOCK = 65536

"""
    read_record([w::Wfdb], record; channels=nothing, from=0, to=nothing,
                highres=false, pad=false, legacy=false) -> Record

Read the signals of `record` (all of them, or a time interval and a subset
of the signals) and return them as a [`Record`](@ref). The samples are in
ADC units; use [`physical`](@ref) to convert them.

# Keyword arguments
- `channels`: the signals to return, in the order given, by number (`0` is
  the first signal) or by description (e.g. `"V5"`); all signals if
  `nothing`.
- `from`, `to`: the interval to read, from `from` (inclusive) to `to`
  (exclusive). Each is a sample number or a WFDB time string as accepted by
  [`strtim`](@ref) (`"0:10"` is 10 s, `"s1000"` is sample 1000, `"e"` is
  the end of the record; a time of day in brackets, such as
  `"[12:00:00]"`, is also accepted). `to=nothing` reads to the end of the
  record. If the record does not specify its sampling frequency (`fs` is
  0), only sample numbers and the strings that do not need a frequency
  (see [`wfdbx_time_needs_freq`](@ref): `"s1000"`, `"e"`, ...) are
  accepted.
- `highres`: for a multi-frequency record, return every sample of the
  oversampled signals at the highest sampling frequency (`WFDB_HIGHRES`
  mode) rather than one (averaged) sample per signal per frame. `fs` is
  then the high-resolution frequency.
- `pad`: replace each invalid sample by the previous valid sample of the
  same signal (`WFDB_GVPAD`).
- `legacy`: see below.

Throws a [`WfdbError`](@ref) if the record cannot be read or has no
signals, if a signal in `channels` does not exist, if `from` is beyond
the end of the record, or if `from` or `to` is a time string that needs
the sampling frequency of a record that does not specify one (`"sampling
frequency of record R is not specified"`).

$_LEGACY_DOC (With it, a header without a sampling frequency gives 250 Hz,
and time strings are converted at 250 Hz, or at 1 sample per second without
a frequency; use `physical(rec; legacy=true)` for gain 200 for
uncalibrated signals.)

# Examples
```julia-repl
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
```
"""
function read_record(w::Wfdb, record::ByteStr; channels=nothing, from=0, to=nothing,
                     highres::Bool=false, pad::Bool=false, legacy::Bool=false)
    _with_legacy(() -> _read_record(w, record, channels, from, to, highres, pad), w, legacy)
end
function _read_record(w::Wfdb, record::ByteStr, channels, from, to, highres::Bool, pad::Bool)
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
    # (A header without a sampling frequency has no base time either, and
    # timstr would report the missing frequency.)
    bt = fs > 0.0 ? timstr(w, 0) : ""
    base_time = startswith(bt, '[') ? bt : nothing
    isigsettime(w, t0) < 0 && _hl_fail(w, "can't seek to sample $t0 of record $rname")

    # getvec returns one value per signal in either mode.
    all = Int32[]
    buf = Int32[]
    remaining = t1 === nothing ? nothing : max(t1 - t0, Int64(0))
    while remaining === nothing || remaining > 0
        n = remaining === nothing ? Int64(READ_BLOCK) : min(remaining, Int64(READ_BLOCK))
        resize!(buf, n * nsig)
        got = max(getvecs(w, buf, n), Int64(0))
        append!(all, view(buf, 1:got*nsig))
        remaining === nothing || (remaining -= got)
        got < n && break
    end
    nframes = length(all) ÷ nsig
    frames = reshape(all, nsig, nframes)
    samples = Matrix{Int32}(undef, nframes, length(cols))
    for (j, c) in enumerate(cols), i in 1:nframes
        samples[i, j] = frames[c, i]
    end
    comments = Vector{UInt8}[]
    c = getinfo(w, record)
    while c !== nothing
        push!(comments, c)
        c = getinfo(w, nothing)
    end
    wfdbquit(w)
    Record(rname, fs, samples, Siginfo[si[k] for k in cols], base_time, t0, comments,
           Int[k - 1 for k in cols])
end
read_record(record::ByteStr; kw...) = read_record(lib(), record; kw...)

"""
    read_annotations([w::Wfdb], record, annotator; from=nothing, to=nothing,
                     fs=nothing, legacy=false) -> Annotations

Read the annotation file of `record` written by `annotator` (the file
`RECORD.ANNOTATOR`, e.g. `100s.atr` for annotator `"atr"`) and return its
annotations as an [`Annotations`](@ref) object.

`from` and `to` restrict the result to annotations with times in
`[from, to)`. Each is a sample number or a time string as accepted by
[`strtim`](@ref) (e.g. `"0:10"`); `nothing` means the beginning or the end
of the file. Times are interpreted using the sampling frequency in the
record's header.

`fs` (> 0) is the sampling frequency to use if the record has no header or
its header does not specify one (like the `-F` option of `rdann`). Without
it, the result's `fs` is the time resolution recorded in the annotation
file, or 0 (wfdb-x: the C tools assumed 250 Hz; see `docs/DIVERGENCES.md`).

Throws a [`WfdbError`](@ref) if the annotation file cannot be read, if `fs`
is given and is not positive, or if `from` or `to` is a time string that
needs the sampling frequency when none is known (`"sampling frequency of
record R is not specified"`).

$_LEGACY_DOC (With it, a record without a header, or whose header does not
specify a sampling frequency, is taken as 250 Hz unless `fs` is given.)

# Examples
```julia-repl
julia> ann = read_annotations("100s", "atr");

julia> length(ann), ann.fs
(75, 360.0)

julia> ann.samples[1:3], String.(ann.symbols[1:3])
([18, 77, 370], ["+", "N", "N"])

julia> length(read_annotations("100s", "atr"; from="0:10", to="0:20"))
12
```
"""
function read_annotations(w::Wfdb, record::ByteStr, annotator::ByteStr; from=nothing,
                          to=nothing, fs::Union{Nothing,Real}=nothing, legacy::Bool=false)
    fs === nothing || fs > 0.0 || throw(WfdbError("read_annotations: fs must be > 0"))
    legacy = _legacy(w, legacy)
    _with_legacy(() -> _read_annotations(w, record, annotator, from, to, fs, legacy), w, legacy)
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
    while getann(w, 0, a) == 0
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
    nothing
end

"""
    write_record([w::Wfdb], record, samples::AbstractMatrix{<:Integer}, fs;
                 gains, adcres, units, fmt=16, baselines=nothing, adczeros=0,
                 names=nothing, samps_per_frame=nothing, base_time=nothing,
                 comments=(), legacy=false)

Write a new record in the current directory: the signal file `RECORD.dat`
and the header file `RECORD.hea`. Existing files are overwritten.

`samples` holds the samples in ADC units, one row per frame. Normally it
has one column per signal. For a multi-frequency record, pass
`samps_per_frame` as a vector giving the number of samples per frame of
each signal; each row then holds `samps_per_frame[s]` consecutive columns
for signal `s`. `fs` is the sampling frequency (frames per second, > 0).

# Keyword arguments
Each per-signal option may be a single value used for every signal, or a
vector with one value per signal (a one-element vector also applies to
every signal).

- `fmt`: the storage format of the signal file (16, 212, 80, ...; one for
  all signals).
- `gains` (required): ADC units per physical unit; 0 declares a signal
  uncalibrated (wfdb-x: there is no default gain; the C tools assumed
  200 adu/mV; see `docs/DIVERGENCES.md`).
- `adczeros`: the ADC value corresponding to 0 V (default 0).
- `baselines`: the ADC value corresponding to 0 physical units (default:
  the signal's `adczero`).
- `adcres` (required): the ADC resolution in bits, >= 1 (wfdb-x: there is
  no default; the C tools inferred it from `fmt` or assumed 12 bits).
- `units` (required for every signal whose gain is not 0): the physical
  units, e.g. `"mV"` (wfdb-x: there is no default; the C tools wrote none,
  and readers assumed millivolts). For an uncalibrated signal, `nothing`
  (or `""`) writes no units.
- `names`: the signal descriptions (default: none).
- `samps_per_frame`: samples per frame of each signal (default 1).
- `base_time`: the base time and date, e.g. `"12:00:00 01/01/2020"` (see
  [`setbasetime`](@ref)); `nothing` for none.
- `comments`: info strings written as comment lines after the signal
  lines of the header.
- `legacy`: see below.

Returns `nothing`. Throws a [`WfdbError`](@ref) if `gains` is missing
(`"write_record: gains must be specified"`), if an ADC resolution is
missing or less than 1 (`"write_record: ADC resolution(s) must be
specified"`), if the units of a signal with a non-zero gain are missing
(`"write_record: units must be specified"`), if `fs` is not positive, if
the number of columns does not match the signals, or if a file cannot be
created.

$_LEGACY_DOC (With it, `gains` defaults to 200, `adcres` to a resolution
based on `fmt` (8 for formats 80 and 508, 10 for 310 and 311, 12 for 212,
24 for 24 and 524, 32 for 32, 16 otherwise), `units` are not required, and
`fs` is not checked.)

# Examples
```julia-repl
julia> rec = read_record("100s"; to="0:10");

julia> write_record("new", rec.samples, rec.fs; fmt=212, gains=200.0, adcres=11,
                    units="mV", names=["MLII", "V5"])

julia> print(read("new.hea", String))
new 2 360 3600
new.dat 212 200/mV 11 0 995 -17352 0 MLII
new.dat 212 200/mV 11 0 1011 1171 0 V5
```
"""
function write_record(w::Wfdb, record::ByteStr, samples::AbstractMatrix{<:Integer}, fs::Real;
                      fmt::Integer=16, gains=nothing, baselines=nothing, adczeros=0,
                      adcres=nothing, units=nothing, names=nothing, samps_per_frame=nothing,
                      base_time=nothing, comments=(), legacy::Bool=false)
    legacy = _legacy(w, legacy)
    nsig = samps_per_frame isa AbstractVector ? length(samps_per_frame) : size(samples, 2)
    _with_legacy(w, legacy) do
        _write_adc(w, record, samples, fs; nsig, fmt, gains, baselines, adczeros, adcres,
                   units, names, samps_per_frame, base_time, comments, legacy)
    end
end
write_record(record::ByteStr, samples::AbstractMatrix{<:Integer}, fs::Real; kw...) =
    write_record(lib(), record, samples, fs; kw...)

"""
    write_record_physical([w::Wfdb], record, samples::AbstractMatrix{<:Real}, fs;
                          options...)

Like [`write_record`](@ref), but `samples` are in physical units (e.g. mV).
Each value `v` is converted to ADC units as `round(v * gain) + baseline`
(halfway cases rounded away from zero, as [`physadu`](@ref) does), using
the `gains` and `baselines` options; `NaN` is written as an invalid sample.
The keyword arguments are those of `write_record` (`gains`, `adcres` and
`units` are required).
A gain of 0 (uncalibrated) is an error here (`"write_record: signal N is
uncalibrated"`, `N` counting from 0): physical values cannot be converted
without a gain (wfdb-x: the C library assumed 200 adu/mV, as
`legacy=true` does).

# Examples
```julia-repl
julia> rec = read_record("100s"; to="0:10");

julia> write_record_physical("newp", physical(rec), rec.fs; gains=[200.0, 100.0], adcres=16,
                             units="mV")
```
"""
function write_record_physical(w::Wfdb, record::ByteStr, samples::AbstractMatrix{<:Real}, fs::Real;
                               fmt::Integer=16, gains=nothing, baselines=nothing,
                               adczeros=0, adcres=nothing, units=nothing, names=nothing,
                               samps_per_frame=nothing, base_time=nothing, comments=(),
                               legacy::Bool=false)
    legacy = _legacy(w, legacy)
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
write_record_physical(record::ByteStr, samples::AbstractMatrix{<:Real}, fs::Real; kw...) =
    write_record_physical(lib(), record, samples, fs; kw...)

"""
    write_annotations([w::Wfdb], record, annotator, ann::Annotations; fs=0.0,
                      legacy=false)

Write the annotations `ann` to the annotation file `RECORD.ANNOTATOR` in
the current directory (an existing file is overwritten), in MIT format.

The type of each annotation is given by its mnemonic in `ann.symbols` if
that entry is non-empty (see [`strann`](@ref)), otherwise by its code in
`ann.codes`. Auxiliary data longer than 255 bytes are truncated. If the
annotations are not in time order, the file is sorted when it is closed,
as the C library does (by running `sortann`).

If `fs > 0`, it is recorded in the file as the time resolution of the
annotation times (ticks per second); otherwise no resolution is recorded,
and readers use the record's sampling frequency. `ann.fs` is not used.

Returns `nothing`. Throws a [`WfdbError`](@ref) if the file cannot be
created.

$_LEGACY_DOC (Writing annotations is the same in both modes.)

# Examples
```julia-repl
julia> ann = read_annotations("100s", "atr");

julia> write_annotations("100s", "cpy", ann; fs=360)   # writes 100s.cpy

julia> read_annotations("100s", "cpy").samples == ann.samples
true
```
"""
function write_annotations(w::Wfdb, record::ByteStr, annotator::ByteStr, ann::Annotations;
                           fs::Real=0.0, legacy::Bool=false)
    _with_legacy(() -> _write_annotations(w, record, annotator, ann, fs), w, legacy)
end
function _write_annotations(w::Wfdb, record::ByteStr, annotator::ByteStr, ann::Annotations,
                            fs::Real)
    n = length(ann.samples)
    wfdbquit(w)
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
    nothing
end
write_annotations(record::ByteStr, annotator::ByteStr, ann::Annotations; kw...) =
    write_annotations(lib(), record, annotator, ann; kw...)

export WfdbError, Record, Annotations, read_header, read_record, read_annotations,
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
        _workload_hl_error(() -> read_record(w, "nosuch"; legacy=true))
    end
end
