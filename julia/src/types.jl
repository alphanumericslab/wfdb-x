# types.jl: types, constants and structures of the WFDB library API
# (<wfdb/wfdb.h>), and the abstract library type `Wfdb`.
#
# The structures have the C field names and C's zero values as defaults.
# Strings are byte strings (`Vector{UInt8}`); a field that C may set to
# `NULL` is a `Union{Nothing,Vector{UInt8}}`.
#
# Copyright (C) 1983-2013 George B. Moody (original C header, lib/wfdb.h;
# revised 2010-2020 by Benjamin Moody).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

"""
    Wfdb

The state of the WFDB library: the input and output directories, network
access, the open record, signals and annotation files, error settings, and
so on (what the C library keeps in
global variables).

`Wfdb()` creates a new, independent state, as at the start of a C program.
Every function of the C-style API takes a `Wfdb` as an optional first
argument (`getwfdb(w)`); without it, the function uses the default instance
returned by [`lib()`](@ref) (`getwfdb()`). Separate instances can have
different records open at the same time.

`Wfdb` is an abstract type; `Wfdb()` returns a [`WfdbLib`](@ref). Annotate
arguments as `w::Wfdb`.

# Examples
```julia-repl
julia> w = Wfdb();

julia> setwfdb(w, "/path/to/data")

julia> isigopen(w, "100s", nothing, 0)   # number of signals of record 100s
2
```
"""
abstract type Wfdb end

"Version of the WFDB Software Package implemented."
const WFDB_MAJOR = Int32(10)
const WFDB_MINOR = Int32(7)
const WFDB_RELEASE = Int32(0)

"A sample value, in ADC units (C `WFDB_Sample`)."
const WFDB_Sample = Int32
"A time, in sample intervals (C `WFDB_Time`; 64 bits, as in a C library built with `WFDB_LARGETIME`)."
const WFDB_Time = Int64
"A date, as a Julian day number (C `WFDB_Date`)."
const WFDB_Date = Int64
const WFDB_Frequency = Float64
const WFDB_Gain = Float64
"A signal group number (C `unsigned int`)."
const WFDB_Group = UInt32
"A signal number (C `unsigned int`)."
const WFDB_Signal = UInt32
"An annotator number (C `unsigned int`)."
const WFDB_Annotator = UInt32

const WFDB_SAMPLE_MIN = typemin(Int32)
const WFDB_SAMPLE_MAX = typemax(Int32)
const WFDB_TIME_MIN = typemin(Int64)
const WFDB_TIME_MAX = typemax(Int64)

"The value that `getvec`, `getframe` and `read_record` return for an invalid (missing) sample."
const WFDB_INVALID_SAMPLE = Int32(-32768)

# Array sizes used by older applications; since WFDB 10.2 the library has no
# fixed limits.
"Number of annotators (C `WFDB_MAXANN`; not a limit of the library)."
const WFDB_MAXANN = Int32(2)
"Number of signals (C `WFDB_MAXSIG`; not a limit of the library)."
const WFDB_MAXSIG = Int32(32)
"Samples per signal per frame (C `WFDB_MAXSPF`; not a limit of the library)."
const WFDB_MAXSPF = Int32(4)
"Maximum length of a record name."
const WFDB_MAXRNL = 50
"Maximum length of a units string."
const WFDB_MAXUSL = 50
"Maximum length of a signal description."
const WFDB_MAXDSL = 100

# File modes (annotator `stat`, `wfdb_open` mode).
"Mode: read a (MIT format) file."
const WFDB_READ = Int32(0)
"Mode: write a (MIT format) file."
const WFDB_WRITE = Int32(1)
"Annotator mode: read an AHA format annotation file."
const WFDB_AHA_READ = Int32(2)
"Annotator mode: write an AHA format annotation file."
const WFDB_AHA_WRITE = Int32(3)
"Mode: append to a file (`wfdb_open`)."
const WFDB_APPEND = Int32(4)

"The signal storage formats (C `WFDB_FMT_LIST`)."
const WFDB_FMT_LIST = Int32[0, 8, 16, 61, 80, 160, 212, 310, 311, 24, 32, 508, 516, 524]
const WFDB_NFMTS = Int32(14)

"""
C's default sampling frequency (Hz). wfdb-x: kept for compatibility but used only in legacy mode: no sampling frequency is otherwise assumed (see `docs/DIVERGENCES.md`).
"""
const WFDB_DEFFREQ = 250.0
"""
C's default gain (ADC units per physical unit). wfdb-x: kept for
compatibility but used only in legacy mode: no gain is otherwise assumed (see
`docs/DIVERGENCES.md`).
"""
const WFDB_DEFGAIN = 200.0
"""
C's default ADC resolution (bits). wfdb-x: kept for compatibility but used only in legacy mode: no ADC resolution is otherwise assumed (see `docs/DIVERGENCES.md`).
"""
const WFDB_DEFRES = Int32(12)

# getvec modes (setgvmode), combined with `|`.
"getvec mode: one sample per signal per frame (oversampled signals are decimated)."
const WFDB_LOWRES = Int32(0)
"getvec mode: every sample of oversampled signals (others are replicated)."
const WFDB_HIGHRES = Int32(1)
"getvec mode flag: replace invalid samples with the previous valid sample."
const WFDB_GVPAD = Int32(2)

# Calibration pulse types (`Calinfo.caltype`): coupling (bit 0) | shape.
"Calibration: AC-coupled signal."
const WFDB_AC_COUPLED = Int32(0)
"Calibration: DC-coupled signal."
const WFDB_DC_COUPLED = Int32(1)
"Calibration pulse shape: square wave."
const WFDB_CAL_SQUARE = Int32(2)
"Calibration pulse shape: sine wave."
const WFDB_CAL_SINE = Int32(4)
"Calibration pulse shape: sawtooth."
const WFDB_CAL_SAWTOOTH = Int32(6)
"Calibration pulse shape: undefined."
const WFDB_CAL_UNDEF = Int32(8)

"""
Default WFDB path, used in legacy mode when the environment variable `WFDB`
is not set (the value of a release build of the C library 10.7.0 installed
in `/usr/local`; legacy mode opens no URLs, so there is no default URL
anywhere in wfdb-x).
"""
const DEFWFDB = b". /usr/local/database http://physionet.org/physiobank/database"
"Default calibration file name."
const DEFWFDBCAL = b"wfdbcal"
"Default value of `WFDBANNSORT`."
const DEFWFDBANNSORT = Int32(1)
"Default getvec mode (`WFDBGVMODE`)."
const DEFWFDBGVMODE = WFDB_LOWRES

"Type of a WFDB path component: a local directory (`WFDB_LOCAL`) or a URL (`WFDB_NET`)."
const WFDB_LOCAL = Int32(0)
const WFDB_NET = Int32(1)

"""
    Siginfo(; fname=nothing, desc=nothing, units=nothing, gain=0.0, initval=0,
            group=0, fmt=0, spf=0, bsize=0, adcres=0, adczero=0, baseline=0,
            nsamp=0, cksum=0)

The description of a signal (C `WFDB_Siginfo`), as read from a header by
[`isigopen`](@ref) or [`read_header`](@ref), or given to
[`osigfopen`](@ref). The fields have the C names; strings are byte vectors
(`nothing` for C's `NULL`).

# Fields
- `fname`: the name of the signal file.
- `desc`: the signal description (e.g. `"MLII"`).
- `units`: the physical units (`nothing`: not specified; wfdb-x: never
  assumed to be millivolts).
- `gain`: ADC units per physical unit (0: uncalibrated).
- `initval`: the value of the first sample.
- `group`: the signal group number (signals of a group share a file).
- `fmt`: the storage format (16, 212, ...).
- `spf`: samples per frame (more than 1 for an oversampled signal).
- `bsize`: the block size of the signal file (0 for ordinary files).
- `adcres`: the ADC resolution in bits (0: not specified).
- `adczero`: the ADC value corresponding to 0 V.
- `baseline`: the ADC value corresponding to 0 physical units.
- `nsamp`: the number of samples (0: unspecified).
- `cksum`: the 16-bit checksum of all samples.
"""
Base.@kwdef mutable struct Siginfo
    fname::Union{Nothing,Vector{UInt8}} = nothing   # signal file name
    desc::Union{Nothing,Vector{UInt8}} = nothing    # signal description
    units::Union{Nothing,Vector{UInt8}} = nothing   # physical units (nothing: unspecified)
    gain::Float64 = 0.0         # adu/physical unit (0: uncalibrated)
    initval::Int32 = 0          # initial value
    group::UInt32 = 0           # signal group number
    fmt::Int32 = 0              # storage format
    spf::Int32 = 0              # samples per frame
    bsize::Int32 = 0            # block size
    adcres::Int32 = 0           # ADC resolution in bits
    adczero::Int32 = 0          # ADC output given 0 VDC input
    baseline::Int32 = 0         # ADC output given 0 physical units input
    nsamp::Int64 = 0            # number of samples (0: unspecified)
    cksum::Int32 = 0            # 16-bit checksum of all samples
end

"""
    Calinfo(; low=0.0, high=0.0, scale=0.0, sigtype=nothing, units=nothing, caltype=0)

An entry of the calibration list (C `WFDB_Calinfo`; see [`calopen`](@ref)
and [`getcal`](@ref)): for signals whose description begins with
`sigtype` and whose units are `units`, the calibration pulse goes from
`low` to `high` (physical units), with pulse type `caltype`
(`WFDB_AC_COUPLED` or `WFDB_DC_COUPLED`, plus a `WFDB_CAL_*` shape), and
`scale` is the customary plotting scale (physical units per cm).
"""
Base.@kwdef mutable struct Calinfo
    low::Float64 = 0.0
    high::Float64 = 0.0
    scale::Float64 = 0.0
    sigtype::Union{Nothing,Vector{UInt8}} = nothing
    units::Union{Nothing,Vector{UInt8}} = nothing
    caltype::Int32 = 0
end

"""
    Anninfo(name, stat)

An annotator to open with [`annopen`](@ref) (C `WFDB_Anninfo`): `name` is
the annotator name (the suffix of the annotation file, e.g. `"atr"`), and
`stat` is the mode (`WFDB_READ`, `WFDB_WRITE`, `WFDB_AHA_READ` or
`WFDB_AHA_WRITE`).
"""
Base.@kwdef mutable struct Anninfo
    name::Vector{UInt8} = UInt8[]
    stat::Int32 = 0
end
Anninfo(name::ByteStr, stat::Integer) = Anninfo(bytes(name), Int32(stat))

"""
    Annotation(; time=0, anntyp=0, subtyp=0, chan=0, num=0, aux=nothing)

An annotation (C `WFDB_Annotation`), as read by [`getann`](@ref) or written
by [`putann`](@ref).

# Fields
- `time::Int64`: the time, in sample intervals (ticks).
- `anntyp::Int8`: the annotation code (e.g. 1, `N`; see [`annstr`](@ref)).
- `subtyp::Int8`, `chan::UInt8`, `num::Int8`: the subtype, channel and
  annotator number fields.
- `aux`: `nothing` (C's `NULL`), or the auxiliary data *preceded by a byte
  that gives their length*, as in C: `aux[1]` is the length `n` and
  `aux[2:n+1]` are the data.
"""
Base.@kwdef mutable struct Annotation
    time::Int64 = 0             # time in sample intervals
    anntyp::Int8 = 0            # annotation type (C char, signed)
    subtyp::Int8 = 0            # subtype (signed char)
    chan::UInt8 = 0             # channel number (unsigned char)
    num::Int8 = 0               # annotator number (signed char)
    aux::Union{Nothing,Vector{UInt8}} = nothing
end

"""
    Seginfo

A segment of a multi-segment record (C `WFDB_Seginfo`; see
[`getseginfo`](@ref)): `recname` is the segment's record name, `nsamp` its
length in samples, and `samp0` the sample number of its first sample in
the multi-segment record.
"""
Base.@kwdef mutable struct Seginfo
    recname::Vector{UInt8} = UInt8[]
    nsamp::Int64 = 0
    samp0::Int64 = 0
end

for T in (:Siginfo, :Calinfo, :Anninfo, :Annotation, :Seginfo)
    @eval Base.copy(x::$T) = $T((let v = getfield(x, f)
        v isa Vector ? copy(v) : v
    end for f in fieldnames($T))...)
    @eval Base.:(==)(a::$T, b::$T) = all(getfield(a, f) == getfield(b, f) for f in fieldnames($T))
    @eval Base.hash(a::$T, h::UInt) = hash(Tuple(getfield(a, f) for f in fieldnames($T)), h)
end
