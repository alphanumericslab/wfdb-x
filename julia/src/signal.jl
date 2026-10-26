# signal.jl: signals and headers (port of lib/signal.c): header files
# (including EDF headers), signal files in every storage format (0, 8, 16,
# 61, 80, 160, 212, 310, 311, 24, 32, and the FLAC formats 508, 516 and
# 524), multi-segment and multi-frequency records, header and info files,
# and conversion of times, dates and amplitudes.
#
# This is a translation of the C library (by way of the Rust port of
# wfdb-x, rust/src/signal.rs), with the same integer types and the same
# state (`SigState`, the `sig` field of a `Wfdb`), so that its behavior is
# that of the C library in every detail. Arrays of the C library (signal
# and group tables) are Julia vectors indexed by the C index plus one;
# signal and group numbers (as in messages and `Siginfo.group`) are C's.
#
# Functions that fill a caller's array take a vector: `getvec` stores one
# sample per signal, `getframe` one frame (the sum of the samples per frame
# of all signals); a vector that is too short receives what fits.
#
# Copyright (C) 1989-2013 George B. Moody (original C implementation,
# lib/signal.c; revised 2011-2022 by Benjamin Moody, including FLAC support,
# 2020).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): the signal files named in a
# header, and the segments named in the header of a multi-segment record,
# are in the directory of that header (on disk or at its URL) or below it; a
# name that is absolute, begins with '~', is a URL or contains a ".."
# component is refused ("~" as a segment, a null segment, and "-" as a
# signal file remain). Nothing is searched: a search can silently open the
# wrong file, and a header must not make the library read other local files
# or contact other servers. The original behavior remains available with
# --legacy (see docs/DIVERGENCES.md).
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
# 12 bits and millivolts), because a silently assumed value corrupts every
# result derived from it. See docs/DIVERGENCES.md. The original behavior
# remains available with --legacy (see docs/DIVERGENCES.md).
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

"`BUFSIZ` of the reference platform (default buffer sizes)."
const WFDB_BUFSIZ = Int32(8192)
"Size of the `sample()` buffer (a power of 2)."
const BUFLN = Int64(4096)
"Token separators of header lines."
const _HSEP = b" \t\n\r"
"Length of the buffer into which `edfparse` reads header fields."
const EDF_FIELD_BUFLEN = 81
"FLAC formats: 500 plus the number of bits per sample (up to 32)."
const FLAC_FMT_BASE = Int32(500)
const FLAC_FMT_MAX = Int32(532)
"Bytes of an EDF header per signal (and of its fixed-size part)."
const EDF_HEADER_BLOCK = 256
"EDF years (two digits) before this one are in the 21st century."
const EDF_YEAR_PIVOT = 1985
"Maximum total length of a signal's file name and description (osigfopen)."
const OSIG_NAME_DESC_MAX = 200
"Milliseconds per day."
const MS_PER_DAY = 24.0 * 60.0 * 60.0 * 1000.0
"Julian date of the start of the Gregorian calendar (15 October 1582)."
const JD_GREGORIAN = 2299161
"The same date (15/10/1582) as `d + 31 * (m + 12 * y)` (`IGREG` of *Numerical Recipes*)."
const IGREG = 15 + 31 * (10 + 12 * 1582)
"Maximum lengths of the strings built by `mstimstr` and `datstr` (C buffers)."
const TIME_STRING_MAX = 61
const DATE_STRING_MAX = 36

# Invalid-sample codes (the lowest value of each format).
const INVALID_8 = Int32(-128)
const INVALID_10 = Int32(-512)
const INVALID_12 = Int32(-2048)
const INVALID_16 = Int32(-32768)
const INVALID_24 = Int32(-8388608)
const INVALID_32 = typemin(Int32)

# Where putinfo writes.
const OUTINFO_NONE = Int32(0)
const OUTINFO_HEADER = Int32(1)
const OUTINFO_FILE = Int32(2)

# ---------------------------------------------------------------------------
# Data structures

"Signal information from a header (C `struct hsdata`)."
mutable struct HsData
    info::Siginfo
    start::Int64        # signal file byte offset to sample 0
    skew::Int32         # intersignal skew (in frames)
end
HsData() = HsData(Siginfo(), 0, 0)

"An open input signal (C `struct isdata`)."
mutable struct IsData
    info::Siginfo
    samp::Int32         # most recent sample read
    skew::Int32         # intersignal skew (in frames)
    gvindex::Int32      # current high-resolution sample number
    gvcount::Int32      # counter for updating gvindex
end
IsData() = IsData(Siginfo(), 0, 0, 0, 0)

"Decoded FLAC input (one signal group)."
mutable struct FlacIn
    nsig::Int32
    datb::Int32                     # bits per sample
    spf::Int32
    decoded::Bool
    failed::Bool
    chans::Vector{Vector{Int32}}
    total::Int64                    # samples per channel
    base::Int64
    nfr::Int64
    leftover::Int64
    f::Int64                        # next frame
    c::Int                          # next channel (0-based)
    k::Int32                        # next sample within the frame
    md5_check::Bool
    has_md5::Bool
    md5::Vector{UInt8}
    have_decoded_md5::Bool
    decoded_md5::Vector{UInt8}
    seeked::Bool
    # State of the libFLAC decoder of the C library, which decodes one FLAC
    # block at a time: the end of each block (in samples per channel), the
    # end of the blocks decoded so far, whether the buffered samples were
    # discarded by a failed seek, and whether decoding was aborted (after a
    # failed seek, iflac_samples() aborts the decoding of the next block, and
    # libFLAC then refuses to seek).
    block_ends::Vector{Int64}
    dec_end::Int64
    discarded::Bool
    aborted::Bool
end
FlacIn(nsig::Integer, datb::Integer, spf::Integer, md5_check::Bool) =
    FlacIn(nsig, datb, spf, false, false, Vector{Int32}[], 0, 0, 0, 0, 0, 0, 0,
           md5_check, false, UInt8[], false, UInt8[], false, Int64[], 0, false, false)

# The end of the FLAC block that contains sample n - 1 (n > 0): the number of
# samples (per channel) decoded once sample n - 1 is.
function _flac_block_end(fi::FlacIn, n::Int64)
    k = searchsortedfirst(fi.block_ends, n)
    k <= length(fi.block_ends) ? fi.block_ends[k] : fi.total
end

"Shared by all signals in an input group (file) (C `struct igdata`)."
mutable struct IgData
    data::Int32                     # bit-packed formats: buffered bytes
    datb::Int32
    fp::Union{Nothing,WfdbFile}
    start::Int64                    # signal file byte offset to sample 0
    bsize::Int32                    # block size (bytes)
    buf::Vector{UInt8}
    bp::Int                         # bytes of buf consumed
    be::Int                         # bytes of buf holding data
    flac::Union{Nothing,FlacIn}
    count::Int32                    # bit-packed formats: samples in data
    seek::Int32                     # 1: seekable, 0: not, -1: not
    initial_skip::Int32             # 1 if the prolog must be skipped
    stat::Int32                     # latest read status
end
IgData() = IgData(0, 0, nothing, 0, 0, UInt8[], 0, 0, nothing, 0, 0, 0, 0)

"An open output signal (C `struct osdata`)."
mutable struct OsData
    info::Siginfo
    samp::Int32         # most recent sample written
    skew::Int32
end
OsData() = OsData(Siginfo(), 0, 0)

"FLAC output of a signal group."
mutable struct FlacOut
    enc::FlacEncoder
    header_pos::Int64
    pending::Vector{UInt8}
end

"Shared by all signals in an output group (file) (C `struct ogdata`)."
mutable struct OgData
    data::Int32
    datb::Int32
    fp::Union{Nothing,WfdbFile}
    start::Int64
    bsize::Int32
    buf::Vector{UInt8}
    bp::Int                         # bytes of buf filled
    be::Int                         # size of buf
    flac::Union{Nothing,FlacOut}
    count::Int32
    seek::Int32
    force_flush::Int32
    nrewind::Int32
end
OgData() = OgData(0, 0, nothing, 0, 0, UInt8[], 0, 0, nothing, 0, 0, 0, 0)

"An entry of the signal map of a variable-layout record (C `struct sigmapinfo`)."
mutable struct SigMapInfo
    desc::Vector{UInt8}
    gain::Float64
    scale::Float64
    offset::Float64
    sample_offset::Int32
    baseline::Int32
    index::Int32
    spf::Int32
end
SigMapInfo() = SigMapInfo(UInt8[], 0.0, 0.0, 0.0, 0, 0, 0, 0)
Base.copy(m::SigMapInfo) = SigMapInfo(copy(m.desc), m.gain, m.scale, m.offset,
                                      m.sample_offset, m.baseline, m.index, m.spf)

"The state of signal.c (the `sig` field of a `Wfdb`)."
mutable struct SigState
    # Set by readheader
    hsd::Vector{HsData}
    hheader::Union{Nothing,WfdbFile}
    linebuf::Vector{UInt8}
    ffreq::Float64          # frame rate (frames/second)
    ifreq::Float64          # getvec sampling frequency (setifreq)
    sfreq::Float64          # sampling frequency (samples/second)
    cfreq::Float64          # counter frequency (ticks/second)
    spfmax::Int32           # max number of samples per frame
    btime::Int64            # base time (milliseconds since midnight)
    bdate::Int64            # base date (Julian date)
    nsamples::Int64         # duration of signals (in samples)
    bcount::Float64         # base count (counter value at sample 0)
    prolog_bytes::Int64     # length of prolog, as told to wfdbsetstart

    # Multi-segment records
    segments::Int32
    in_msrec::Int32
    msbtime::Int64
    msbdate::Int64
    msnsamples::Int64
    segarray::Vector{Seginfo}
    have_segarray::Bool
    segp::Int32             # current segment (C index)
    segend::Int32           # last segment (C index)

    # Open input signals
    isd::Vector{IsData}
    igd::Vector{IgData}
    nisig::Int
    nigroup::Int
    ispfmax::Int
    tvector::Vector{Int32}
    uvector::Vector{Int32}
    vvector::Vector{Int32}
    tuvlen::Int32
    istime::Int64           # time of next input sample
    ibsize::Int32           # default input buffer size
    skewmax::Int
    dsbuf::Vector{Int32}    # deskewing buffer
    have_dsbuf::Bool
    dsbi::Int32             # index to oldest sample in dsbuf (-1: invalid)
    dsblen::Int
    framelen::Int           # total number of samples per frame
    gvmode::Int32           # getvec mode
    gvc::Int32              # getvec sample-within-frame counter
    isedf::Int32
    sbuf::Vector{Int32}     # sample() buffer
    have_sbuf::Bool
    sample_vflag::Int32

    # Output signals
    osd::Vector{OsData}
    ogd::Vector{OgData}
    nosig::Int
    nogroup::Int
    oheader::Union{Nothing,WfdbFile}
    outinfo_file::Union{Nothing,WfdbFile}
    outinfo::Int32
    ostime::Int64           # time of next output sample
    obsize::Int32           # default output buffer size

    # Info strings
    pinfo::Vector{Vector{UInt8}}
    have_pinfo::Bool
    ninfo::Int32
    info_i::Int32

    # Variable-layout multi-segment records
    need_sigmap::Int32
    nvsig::Int32
    tspf::Int32
    vspfmax::Int32
    vsd::Vector{IsData}
    ovec::Vector{Int32}
    smi::Vector{SigMapInfo}

    # getvec resampling (setifreq)
    mticks::Int64
    nticks::Int64
    mnticks::Int64
    rgvstat::Int32
    rgvtime::Int64
    gvtime::Int64
    gv0::Vector{Int32}
    gv1::Vector{Int32}
    rgetvec_stat::Int32

    # Time and date strings
    date_string::Vector{UInt8}
    pdays::Int64

    # sample()
    sample_tt::Int64

    # wfdb-x: legacy mode (the original library's built-in defaults)
    legacy::Bool

    # wfdb-x: the directory of the header read last (see wfdbx_dirname;
    # nothing if unknown: the standard input), and the directory and name of
    # the header of the current multi-segment record (msrec_name is nothing
    # if there is none); user_segments while setmsheader reads the headers
    # of the segments it was given
    hdr_dir::Union{Nothing,Vector{UInt8}}
    msrec_dir::Union{Nothing,Vector{UInt8}}
    msrec_name::Union{Nothing,Vector{UInt8}}
    user_segments::Bool

    # wfdb-x: true while a high-level reader reads (getvec's checksum
    # message is then not printed: the reader warns instead)
    cksum_quiet::Bool
end

SigState() = SigState(
    HsData[], nothing, UInt8[], 0.0, 0.0, 0.0, 0.0, 0, 0, 0, 0, 0.0, 0,
    0, 0, 0, 0, 0, Seginfo[], false, -1, -1,
    IsData[], IgData[], 0, 0, 0, Int32[], Int32[], Int32[], 0, 0, 0, 0, Int32[], false,
    0, 0, 0, DEFWFDBGVMODE, 0, 0, Int32[], false, 0,
    OsData[], OgData[], 0, 0, nothing, nothing, OUTINFO_NONE, 0, 0,
    Vector{UInt8}[], false, 0, 0,
    0, 0, 0, 0, IsData[], Int32[], SigMapInfo[],
    0, 0, 0, 0, 0, 0, Int32[], Int32[], 0,
    UInt8[], -1,
    0,
    false,
    nothing, nothing, nothing, false,
    false)

# ---------------------------------------------------------------------------
# Legacy mode (wfdb-x)

"""
    wfdbx_set_legacy([w], on) -> Int32

wfdb-x addition: turn legacy mode on (if `on` is true or nonzero) or off,
and return the previous setting (1: on, 0: off). In legacy mode, the
library behaves exactly as the original WFDB library 10.7.0, with its
built-in defaults: `WFDB_DEFFREQ` (250 Hz) for a header without a sampling
frequency, an ADC resolution inferred from the format or `WFDB_DEFRES`,
1 sample per second in the time conversions when no frequency is known,
and `WFDB_DEFGAIN` (with a baseline of 0 for invalid signal numbers) in the
unit conversions. The setting belongs to the library state `w` (default:
[`lib()`](@ref)); it is off by default. Kept for compatibility only: the
values it assumes are exactly the silent defaults wfdb-x removed (see
`docs/DIVERGENCES.md`, "Legacy mode").
"""
function wfdbx_set_legacy(w::Wfdb, on::Union{Bool,Integer})
    previous = Int32(w.sig.legacy)
    w.sig.legacy = on != 0
    previous
end

"""
    wfdbx_get_legacy([w]) -> Int32

wfdb-x addition: 1 if legacy mode is on (see [`wfdbx_set_legacy`](@ref)),
0 otherwise.
"""
wfdbx_get_legacy(w::Wfdb) = Int32(w.sig.legacy)

"""
    wfdbx_legacy_args([w], args::Vector{String}) -> Int32

wfdb-x addition, called by the tools before anything else: if the first
element of `args` (the arguments without the program name) is exactly
`"--legacy"`, remove it, turn legacy mode on, and return 1; the tool then
behaves exactly as the original one. Otherwise, change nothing and return
0. Only the first argument is recognized.
"""
function wfdbx_legacy_args(w::Wfdb, args::Vector{String})
    (isempty(args) || args[1] != "--legacy") && return Int32(0)
    popfirst!(args)
    wfdbx_set_legacy(w, true)
    Int32(1)
end

# The ADC resolution of a header without one, in legacy mode (the original
# library inferred it from the format, or assumed WFDB_DEFRES).
_legacy_adcres(f::Integer) =
    f == 80 ? Int32(8) : f == 160 ? Int32(16) : f == 212 ? Int32(12) :
    (f == 310 || f == 311) ? Int32(10) : WFDB_DEFRES

# ---------------------------------------------------------------------------
# Helpers

"Is `f` a supported signal storage format?"
isfmt(f::Integer) = f in WFDB_FMT_LIST
"Is `f` a FLAC format (508, 516, 524)?"
isflacfmt(f::Integer) = FLAC_FMT_BASE <= f <= FLAC_FMT_MAX

# The C string of an optional string (empty if NULL).
_ostr(s::Union{Nothing,Vector{UInt8}}) = s === nothing ? UInt8[] : cstr(s)
# `%s` of an optional string (glibc prints `(null)`).
_str_or_null(s::Union{Nothing,Vector{UInt8}}) = s === nothing ? Vector{UInt8}(b"(null)") : cstr(s)
# strtol(s, NULL, 10) and strtod(s, NULL).
_strtol10(s::AbstractVector{UInt8}) = strtol(s, 10)[1]
_strtod0(s::AbstractVector{UInt8}) = strtod(s)[1]
# The first n bytes of a C string.
function _strn(s::AbstractVector{UInt8}, n::Integer)
    c = cstr(Vector{UInt8}(s))
    c[1:min(length(c), Int(n))]
end
# The byte at 0-based index i of v, or 0 (C's terminating NUL) past its end.
@inline _byte0(v::Vector{UInt8}, i::Int) = i < length(v) ? v[i+1] : 0x00
_close!(f::Union{Nothing,WfdbFile}) = (f === nothing || fclose(f); nothing)

"""
    _strtok_inplace!(s, delim) -> Union{Vector{UInt8},Nothing}

`strtok(s, delim)` applied in place: the first token, if any, leaving `s`
as C's `strtok` leaves it (ending after the token).
"""
function _strtok_inplace!(s::Vector{UInt8}, delim::AbstractVector{UInt8})
    c = cstr(s)
    i = findfirst(x -> !(x in delim), c)
    i === nothing && return nothing
    j = findnext(x -> x in delim, c, i)
    j = j === nothing ? length(c) + 1 : j
    tok = c[i:j-1]
    resize!(s, j - 1)
    copyto!(s, 1, c, 1, j - 1)
    tok
end

# ---------------------------------------------------------------------------
# Low-level input routines (signal group as argument)

@noinline function r8_fill(ig::IgData)
    buf = ig.buf
    n = ig.bsize > 0 ? Int(ig.bsize) : length(buf)
    n = min(n, length(buf))
    fp = ig.fp
    got = fp === nothing ? 0 : fread!(fp, buf, n)
    ig.stat = Int32(got)
    ig.be = got
    c = isempty(buf) ? Int32(0) : Int32(reinterpret(Int8, buf[1]))
    ig.bp = 1
    c
end

"Format 8 (and the byte reader of the others): a signed byte."
@inline function r8(ig::IgData)
    bp = ig.bp
    if bp < ig.be
        ig.bp = bp + 1
        return Int32(reinterpret(Int8, @inbounds ig.buf[bp+1]))
    end
    r8_fill(ig)
end

"Format 16: 16-bit two's complement, little-endian."
@inline function r16(ig::IgData)
    bp = ig.bp
    if bp + 2 <= ig.be
        buf = ig.buf
        @inbounds v = UInt16(buf[bp+1]) | UInt16(buf[bp+2]) << 8
        ig.bp = bp + 2
        return Int32(reinterpret(Int16, v))
    end
    l = r8(ig)
    h = r8(ig)
    Int32(((h << 8) | (l & Int32(0xff))) % Int16)
end

"Format 61: 16-bit two's complement, big-endian."
@inline function r61(ig::IgData)
    bp = ig.bp
    if bp + 2 <= ig.be
        buf = ig.buf
        @inbounds v = UInt16(buf[bp+1]) << 8 | UInt16(buf[bp+2])
        ig.bp = bp + 2
        return Int32(reinterpret(Int16, v))
    end
    h = r8(ig)
    l = r8(ig)
    Int32(((l & Int32(0xff)) | (h << 8)) % Int16)
end

"Format 24: 24-bit two's complement, little-endian."
@inline function r24(ig::IgData)
    bp = ig.bp
    if bp + 3 <= ig.be
        buf = ig.buf
        @inbounds v = UInt32(buf[bp+1]) | UInt32(buf[bp+2]) << 8 | UInt32(buf[bp+3]) << 16
        ig.bp = bp + 3
        return reinterpret(Int32, v << 8) >> 8
    end
    lw = r16(ig)
    h = r8(ig)
    reinterpret(Int32, (h % UInt32) << 16 | ((lw % UInt32) & 0xffff))
end

"Format 32: 32-bit two's complement, little-endian."
@inline function r32(ig::IgData)
    bp = ig.bp
    if bp + 4 <= ig.be
        buf = ig.buf
        @inbounds v = UInt32(buf[bp+1]) | UInt32(buf[bp+2]) << 8 |
                      UInt32(buf[bp+3]) << 16 | UInt32(buf[bp+4]) << 24
        ig.bp = bp + 4
        return reinterpret(Int32, v)
    end
    lw = r16(ig)
    h = r16(ig)
    reinterpret(Int32, (h % UInt32) << 16 | ((lw % UInt32) & 0xffff))
end

"Format 80: 8-bit offset binary."
@inline r80(ig::IgData) = (r8(ig) & Int32(0xff)) - Int32(1 << 7)
"Format 160: 16-bit offset binary."
@inline r160(ig::IgData) = (r16(ig) & Int32(0xffff)) - Int32(1 << 15)

"Format 212: 2 12-bit samples bit-packed in 3 bytes."
@inline function r212(ig::IgData)
    c = ig.count
    ig.count = c + Int32(1)
    if c == 0
        ig.data = r16(ig)
        v = ig.data
    else
        ig.count = 0
        v = ((ig.data >> 4) & Int32(0xf00)) | (r8(ig) & Int32(0xff))
    end
    (v & Int32(0x800)) != 0 ? v | ~Int32(0xfff) : v & Int32(0xfff)
end

"Format 310: 3 10-bit samples bit-packed in 4 bytes."
@inline function r310(ig::IgData)
    c = ig.count
    ig.count = c + Int32(1)
    if c == 0
        ig.data = r16(ig)
        v = ig.data >> 1
    elseif c == 1
        ig.datb = r16(ig)
        v = ig.datb >> 1
    else
        ig.count = 0
        v = ((ig.data & Int32(0xf800)) >> 11) | ((ig.datb & Int32(0xf800)) >> 6)
    end
    (v & Int32(0x200)) != 0 ? v | ~Int32(0x3ff) : v & Int32(0x3ff)
end

"Format 311: 3 10-bit samples bit-packed in 4 bytes."
@inline function r311(ig::IgData)
    c = ig.count
    ig.count = c + Int32(1)
    if c == 0
        ig.data = r16(ig)
        v = ig.data
    elseif c == 1
        ig.datb = r8(ig) & Int32(0xff)
        v = ((ig.data & Int32(0xfc00)) >> 10) | ((ig.datb & Int32(0xf)) << 6)
    else
        ig.count = 0
        ig.datb |= r8(ig) << 8
        v = ig.datb >> 4
    end
    (v & Int32(0x200)) != 0 ? v | ~Int32(0x3ff) : v & Int32(0x3ff)
end

# ---------------------------------------------------------------------------
# Low-level output routines

@noinline function w8_flush(og::OgData, obsize::Int32)
    n = og.bsize > 0 ? Int(og.bsize) : Int(obsize)
    og.bp = 0
    n = min(n, length(og.buf))
    fp = og.fp
    fp === nothing || fwrite(fp, view(og.buf, 1:n))
    nothing
end

@inline function w8(og::OgData, v::Int32, obsize::Int32)
    bp = og.bp + 1
    @inbounds og.buf[bp] = v % UInt8
    og.bp = bp
    bp == og.be && w8_flush(og, obsize)
    nothing
end
@inline w16(og::OgData, v::Int32, ob::Int32) = (w8(og, v, ob); w8(og, v >> 8, ob))
@inline w61(og::OgData, v::Int32, ob::Int32) = (w8(og, v >> 8, ob); w8(og, v, ob))
@inline w24(og::OgData, v::Int32, ob::Int32) = (w16(og, v, ob); w8(og, v >> 16, ob))
@inline w32(og::OgData, v::Int32, ob::Int32) = (w16(og, v, ob); w16(og, v >> 16, ob))
@inline w80(og::OgData, v::Int32, ob::Int32) = w8(og, (v & Int32(0xff)) + Int32(1 << 7), ob)
@inline w160(og::OgData, v::Int32, ob::Int32) = w16(og, (v & Int32(0xffff)) + Int32(1 << 15), ob)

function w212(og::OgData, v::Int32, ob::Int32)
    c = og.count
    og.count = c + Int32(1)
    if c == 0
        og.data = v & Int32(0xfff)
    else
        og.count = 0
        og.data |= (v << 4) & Int32(0xf000)
        w16(og, og.data, ob)
        w8(og, v, ob)
    end
    nothing
end

"Write out a partial group of format 212 samples."
function f212(og::OgData, ob::Int32)
    if og.count == 1
        w16(og, og.data, ob)
        og.nrewind = 2
    end
    nothing
end

function w310(og::OgData, v::Int32, ob::Int32)
    c = og.count
    og.count = c + Int32(1)
    if c == 0
        og.data = (v << 1) & Int32(0x7fe)
    elseif c == 1
        og.datb = (v << 1) & Int32(0x7fe)
    else
        og.count = 0
        og.data |= v << 11
        w16(og, og.data, ob)
        og.datb |= (v << 6) & ~Int32(0x7fe)
        w16(og, og.datb, ob)
    end
    nothing
end

"Write out a partial group of format 310 samples."
function f310(og::OgData, ob::Int32)
    if og.count == 1
        w16(og, og.data, ob)
        og.nrewind = 2
    elseif og.count != 0
        w16(og, og.data, ob)
        w16(og, og.datb, ob)
        og.nrewind = 4
    end
    nothing
end

function w311(og::OgData, v::Int32, ob::Int32)
    c = og.count
    og.count = c + Int32(1)
    if c == 0
        og.data = v & Int32(0x3ff)
    elseif c == 1
        og.data |= v << 10
        w16(og, og.data, ob)
        og.datb = (v >> 6) & Int32(0xf)
    else
        og.count = 0
        og.datb |= v << 4
        og.datb &= Int32(0x3fff)
        w16(og, og.datb, ob)
    end
    nothing
end

"Write out a partial group of format 311 samples."
function f311(og::OgData, ob::Int32)
    if og.count == 1
        w16(og, og.data, ob)
        og.nrewind = 2
    elseif og.count != 0
        w16(og, og.datb, ob)
        og.nrewind = 2
    end
    nothing
end

# ---------------------------------------------------------------------------

"""
    meansamp(s, off, n) -> Int32

The mean of the `n` samples `s[off+1:off+n]`, rounded to the nearest
integer (halfway cases rounded up); invalid if any of them is.
"""
function meansamp(s::Vector{Int32}, off::Int, n::Int32)
    sum = Int64(n ÷ Int32(2))
    for i in 1:max(Int(n), 0)
        x = s[off+i]
        x == WFDB_INVALID_SAMPLE && return WFDB_INVALID_SAMPLE
        sum += x
    end
    neg = Int64(sum < 0)
    if n & (n - Int32(1)) != 0
        return ((sum + neg) ÷ n - neg) % Int32
    end
    m = n
    while true
        m ÷= Int32(2)
        m == 0 && break
        sum = (sum - (sum < 0)) ÷ 2
    end
    sum % Int32
end

"Range of the sample values of a storage format (for `sigmap_init`)."
function fmt_range(fmt::Int32)
    if fmt == 508 || fmt == 80
        (Int32(-0x80), Int32(0x7f))
    elseif fmt == 310 || fmt == 311
        (Int32(-0x200), Int32(0x1ff))
    elseif fmt == 212
        (Int32(-0x800), Int32(0x7ff))
    elseif fmt == 16 || fmt == 61 || fmt == 516 || fmt == 160
        (Int32(-0x8000), Int32(0x7fff))
    elseif fmt == 524 || fmt == 24
        (Int32(-0x800000), Int32(0x7fffff))
    else
        (WFDB_SAMPLE_MIN, WFDB_SAMPLE_MAX)
    end
end

"""
Read a fixed-size EDF header field into `buf` (the 81-byte buffer that C's
`edfparse` reads every field into, so that stale bytes may follow a field)
and remove its trailing spaces.
"""
function _edf_read_str!(buf::Vector{UInt8}, size::Int, f::WfdbFile)
    if fread!(f, buf, size) != size
        buf[1] = 0x00
    else
        n = size
        while n > 0 && buf[n] == UInt8(' ')
            n -= 1
        end
        buf[n+1] = 0x00
    end
    nothing
end

# ---------------------------------------------------------------------------
# Signal maps (variable-layout multi-segment records)

function sigmap_cleanup(w::Wfdb)
    st = w.sig
    st.need_sigmap = 0
    st.nvsig = 0
    st.tspf = 0
    st.vspfmax = 0
    empty!(st.ovec)
    empty!(st.smi)
    empty!(st.vsd)
    nothing
end

function make_vsd(w::Wfdb)
    st = w.sig
    if st.nvsig != st.nisig
        wfdb_error(w, "make_vsd: oops! nvsig = %d, nisig = %d\n", st.nvsig, Int32(st.nisig))
        return Int32(-1)
    end
    n = Int(st.nvsig)
    while length(st.vsd) < n
        push!(st.vsd, IsData())
    end
    for i in 1:n
        st.vsd[i].info = copy(st.isd[i].info)
        st.vsd[i].skew = st.isd[i].skew
    end
    st.nvsig
end

function _segname(st::SigState)
    if st.have_segarray && 0 <= st.segp < length(st.segarray)
        copy(st.segarray[st.segp+1].recname)
    else
        UInt8[]
    end
end

function sigmap_init(w::Wfdb, first_segment::Bool)
    st = w.sig
    if st.in_msrec != 0 && first_segment && st.have_segarray && !isempty(st.segarray) &&
       st.segarray[1].nsamp == 0
        # This is the layout segment: set up the output side of the map.
        st.need_sigmap = 1
        st.nvsig = st.nisig
        st.vspfmax = st.ispfmax
        st.tspf = 0
        for s in 1:st.nisig
            st.tspf += st.isd[s].info.spf
        end
        st.smi = [SigMapInfo() for _ in 1:max(Int(st.tspf), 0)]
        s = 0
        for i in 1:st.nisig
            m = st.smi[s+1]
            m.desc = _ostr(st.isd[i].info.desc)
            m.gain = st.isd[i].info.gain
            m.baseline = st.isd[i].info.baseline
            k = Int(st.isd[i].info.spf)
            m.spf = k
            for j in 1:k-1
                st.smi[s+j+1] = copy(m)
            end
            s += max(k, 0)
        end
        st.ovec = zeros(Int32, max(Int(st.tspf), 0))
        return make_vsd(w)
    elseif st.need_sigmap != 0
        # Set up the input side of the map.
        for m in st.smi
            m.index = 0
            m.scale = 0.0
            m.offset = 0.0
            m.sample_offset = WFDB_INVALID_SAMPLE
        end
        st.ispfmax = st.vspfmax
        if st.isd[1].info.fmt == 0 && st.nisig == 1
            return Int32(0)     # the current segment is a null record
        end
        segname = _segname(st)
        tspf = st.tspf
        j = Int32(0)
        for i in 1:st.nisig
            ii = st.isd[i].info
            idesc = _ostr(ii.desc)
            s = Int32(0)
            while s < tspf
                if st.smi[s+1].desc == idesc
                    kmax = st.smi[s+1].spf
                    if kmax != ii.spf
                        wfdb_error(w, "sigmap_init: unexpected spf for signal %d in segment %s\n",
                                   Int32(i - 1), segname)
                        kmax > ii.spf && (kmax = ii.spf)
                    end
                    for k in Int32(0):kmax-Int32(1)
                        ps = st.smi[s+k+1]
                        ps.index = j + k
                        ps.scale = ps.gain / ii.gain
                        if ps.scale < 1.0
                            wfdb_error(w, "sigmap_init: loss of precision in signal %d in segment %s\n",
                                       Int32(i - 1), segname)
                        end
                        ps.offset = ps.baseline - ps.scale * ii.baseline + 0.5
                        # If it is possible to add an additional offset such
                        # that all possible output values will fit into a
                        # positive signed integer, the "fast" case can be
                        # used in sigmap.
                        ivmin, ivmax = fmt_range(ii.fmt)
                        ovmin = ivmin * ps.scale + ps.offset
                        ovmax = ivmax * ps.scale + ps.offset
                        if ovmin < ovmax && ovmin >= WFDB_SAMPLE_MIN + 1.0 &&
                           ovmax <= Float64(WFDB_SAMPLE_MAX) &&
                           ovmax - ovmin + 1.0 < Float64(WFDB_SAMPLE_MAX)
                            ps.sample_offset = d2i(ovmin - 1.0)
                            ps.offset -= ps.sample_offset
                        else
                            ps.sample_offset = 0
                        end
                    end
                    break
                end
                s += st.smi[s+1].spf
            end
            j += ii.spf
        end
        if j > tspf
            wfdb_error(w, "sigmap_init: frame size too large in segment %s\n", segname)
            return Int32(-1)
        end
    elseif st.in_msrec != 0 && !first_segment && st.framelen == 0
        # Opening a new segment of a fixed-layout multisegment record.
        st.ispfmax = st.vspfmax
        if st.nisig > st.nvsig
            wfdb_error(w, "sigmap_init: wrong number of signals in segment %s\n", _segname(st))
            return Int32(-1)
        end
        for i in 1:st.nisig
            if st.isd[i].info.spf != st.vsd[i].info.spf
                wfdb_error(w, "sigmap_init: wrong spf for signal %d in segment %s\n",
                           Int32(i - 1), _segname(st))
                return Int32(-1)
            end
        end
    else
        # Normal record, or multisegment record without a layout.
        st.nvsig = st.nisig
        st.vspfmax = st.ispfmax
        st.tspf = 0
        for s in 1:st.nisig
            st.tspf += st.isd[s].info.spf
        end
        return make_vsd(w)
    end
    Int32(0)
end

# ---------------------------------------------------------------------------
# Header files

"Get header information from an EDF file (C `edfparse`)."
function edfparse(w::Wfdb)
    st = w.sig
    buf = zeros(UInt8, EDF_FIELD_BUFLEN)
    s_(b) = cstr(b)
    day, month, year = Ref{Int32}(0), Ref{Int32}(0), Ref{Int32}(0)
    hour, minute, second = Ref{Int32}(0), Ref{Int32}(0), Ref{Int32}(0)
    nsig, offset = Ref{Int32}(0), Ref{Int32}(0)
    nframes = Ref{Int64}(0)
    spr = Ref{Float64}(0.0)

    fnamebuf = wfdb_filename(w)
    ifile = st.hheader
    ifile === nothing && return Int32(-1)

    # Read the first 8 bytes and check for the magic string.
    fread!(ifile, buf, 8)
    if view(buf, 1:8) == b"0       "
        format = Int32(16)      # EDF or EDF+
    elseif view(buf, 2:8) == b"BIOSEMI"
        format = Int32(24)      # BDF
    else
        wfdb_error(w, "init: '%s' is not EDF or EDF+\n", fnamebuf)
        return Int32(-2)
    end

    # Read the remainder of the fixed-size section of the header.
    _edf_read_str!(buf, 80, ifile)     # patient ID (ignored)
    _edf_read_str!(buf, 80, ifile)     # recording ID (ignored)
    _edf_read_str!(buf, 8, ifile)      # recording date
    csscanf(s_(buf), "%d%*c%d%*c%d", day, month, year)
    year[] += Int32(1900)               # EDF has only two-digit years
    year[] < EDF_YEAR_PIVOT && (year[] += Int32(100))
    _edf_read_str!(buf, 8, ifile)      # recording time
    csscanf(s_(buf), "%d%*c%d%*c%d", hour, minute, second)
    _edf_read_str!(buf, 8, ifile)      # number of bytes in header
    csscanf(s_(buf), "%d", offset)
    _edf_read_str!(buf, 44, ifile)     # free space (ignored)
    _edf_read_str!(buf, 8, ifile)      # number of frames (EDF blocks)
    csscanf(s_(buf), "%ld", nframes)
    nframes[] < 0 && (nframes[] = 0)
    st.nsamples = nframes[]
    spr[] = 0.0
    _edf_read_str!(buf, 8, ifile)      # data record duration (seconds)
    csscanf(s_(buf), "%lf", spr)
    spr[] <= 0.0 && (spr[] = 1.0)
    fread!(ifile, view(buf, 5:8), 4)   # number of signals
    csscanf(cstr(buf[5:end]), "%d", nsig)

    if nsig[] < 1 || (Int64(nsig[]) + 1) * EDF_HEADER_BLOCK != offset[]
        wfdb_error(w, "init: '%s' is not EDF or EDF+\n", fnamebuf)
        return Int32(-2)
    end
    ns = Int(nsig[])

    # Allocate workspace.
    while length(st.hsd) < ns
        push!(st.hsd, HsData())
    end
    dmax = zeros(Int64, ns)
    dmin = zeros(Int64, ns)
    pmax = zeros(Float64, ns)
    pmin = zeros(Float64, ns)
    lv = Ref{Int64}(0)
    dv = Ref{Float64}(0.0)
    iv = Ref{Int32}(0)

    # Strip off any path info from the EDF file name.
    fname = cstr(fnamebuf)
    edf_fname = fname
    p = length(fname) - 5     # (0-based index)
    while p > 0
        if fname[p+1] == UInt8('/')
            edf_fname = fname[p+2:end]
            break
        end
        p -= 1
    end

    # Read the variable-size section of the header.
    for s in 1:ns
        h = st.hsd[s]
        h.start = offset[]
        h.skew = 0
        h.info.fname = copy(edf_fname)
        h.info.group = 0
        h.info.bsize = 0
        h.info.cksum = 0
        h.info.fmt = format
        h.info.nsamp = nframes[]
        _edf_read_str!(buf, 16, ifile)  # signal type
        h.info.desc = s_(buf)
    end
    for _ in 1:ns
        _edf_read_str!(buf, 80, ifile)  # transducer type (ignored)
    end
    for s in 1:ns
        _edf_read_str!(buf, 8, ifile)   # signal units
        st.hsd[s].info.units = s_(buf)
    end
    for s in 1:ns
        _edf_read_str!(buf, 8, ifile)   # physical minimum
        dv[] = pmin[s]
        csscanf(s_(buf), "%lf", dv)
        pmin[s] = dv[]
    end
    for s in 1:ns
        _edf_read_str!(buf, 8, ifile)   # physical maximum
        dv[] = pmax[s]
        csscanf(s_(buf), "%lf", dv)
        pmax[s] = dv[]
    end
    for s in 1:ns
        _edf_read_str!(buf, 8, ifile)   # digital minimum
        lv[] = dmin[s]
        csscanf(s_(buf), "%ld", lv)
        dmin[s] = lv[]
    end
    for s in 1:ns
        _edf_read_str!(buf, 8, ifile)   # digital maximum
        lv[] = dmax[s]
        csscanf(s_(buf), "%ld", lv)
        dmax[s] = lv[]
        h = st.hsd[s]
        z = ((dmax[s] + 1 + dmin[s]) ÷ 2) % Int32
        h.info.initval = z
        h.info.adczero = z
        adcrange = dmax[s] - dmin[s]
        i = Int32(0)
        while adcrange > 0
            adcrange ÷= 2
            i += Int32(1)
        end
        h.info.adcres = i
        if pmax[s] != pmin[s]
            h.info.gain = (dmax[s] - dmin[s]) / (pmax[s] - pmin[s])
            baseline = dmax[s] - pmax[s] * h.info.gain
            h.info.baseline = baseline >= 0.0 ? d2i(baseline + 0.5) : d2i(baseline - 0.5)
        else
            # gain is undefined
            h.info.gain = 0.0
            h.info.baseline = 0
        end
    end
    for _ in 1:ns
        _edf_read_str!(buf, 80, ifile)  # filtering information (ignored)
    end
    for s in 1:ns
        _edf_read_str!(buf, 8, ifile)   # samples per frame (EDF block)
        iv[] = 0
        csscanf(s_(buf), "%d", iv)
        st.hsd[s].info.spf = iv[]
        iv[] > st.spfmax && (st.spfmax = iv[])
    end

    # Close the file (don't bother reading nsig*32 bytes of free space);
    # getinfo must not try to read the EDF file.
    fclose(ifile)
    st.hheader = nothing

    st.ffreq = 1.0 / spr[]      # frame frequency = 1/(seconds per EDF block)
    st.cfreq = st.ffreq         # set sampling and counter frequencies to match
    st.sfreq = st.ffreq * st.spfmax
    getafreq(w) == 0.0 && setafreq(w, st.sfreq)
    st.gvmode |= WFDB_HIGHRES
    tb = cformat("%02d:%02d:%02d %02d/%02d/%04d", hour[], minute[], second[], day[], month[], year[])
    length(tb) > 80 && resize!(tb, 80)
    setbasetime(w, tb)

    st.isedf = 1
    nsig[]
end

"""
    readheader(w, record) -> Int32

Read the header of a record (C `readheader`): the number of signals, 0 for
a multi-segment record's master header, or a negative error code.
"""
function readheader(w::Wfdb, record0::AbstractVector{UInt8})
    st = w.sig
    record = copy(cstr(Vector{UInt8}(record0)))

    # If another input header file was opened, close it.
    _close!(st.hheader)
    st.hheader = nothing

    st.spfmax = 1
    st.sfreq = st.ffreq
    st.isedf = 0
    if record == b"~"
        if st.in_msrec != 0 && !isempty(st.vsd)
            h = HsData()
            h.info.desc = Vector{UInt8}(b"~")
            h.info.spf = 1
            h.info.fmt = 0
            st.nsamples = st.segarray[st.segp+1].nsamp
            h.info.nsamp = st.nsamples
            st.hsd = [h]
            return Int32(1)
        end
        return Int32(0)
    end

    # If the final component of the record name includes a '.', assume it
    # is a file name.
    q = length(record)
    while q > 1 && !(record[q] in b"./:\\")
        q -= 1
    end
    if q >= 1 && record[q] == UInt8('.')
        f = _open_header(w, nothing, record)
        if f === nothing
            wfdb_error(w, "init: can't open %s\n", record)
            return Int32(-1)
        end
        st.hheader = f
        if view(record, q+1:length(record)) != b"hea"
            return edfparse(w)  # assume EDF if not '.hea'
        end
    else
        # Otherwise, assume the file name is record.hea.
        f = _open_header(w, "hea", record)
        if f === nothing
            wfdb_error(w, "init: can't open header for record %s\n", record)
            return Int32(-1)
        end
        st.hheader = f
    end
    readheader_body(w, record, st.linebuf)
end

# Open the header (of type s: "hea", or nothing for a file name) of a
# record, or of a segment named in the header of the current multi-segment
# record (wfdb-x: in that header's directory), and note its directory.
function _open_header(w::Wfdb, s::OptByteStr, record::Vector{UInt8})
    st = w.sig
    wfdbx_get_legacy(w) != 0 && return wfdb_open(w, s, record, WFDB_READ)
    if st.in_msrec == 0
        st.msrec_dir = nothing
        st.msrec_name = nothing
    end
    f = if st.in_msrec != 0 && st.msrec_name !== nothing && !st.user_segments
        wfdbx_open_in(w, st.msrec_dir, s, record, st.msrec_name)
    else
        wfdb_open(w, s, record, WFDB_READ)
    end
    st.hdr_dir = (f === nothing || is_std(f)) ? nothing : wfdbx_dirname(wfdb_filename(w))
    f
end

# Read a line of the open header (0 at end of file).
_hgetline(st::SigState, line::Vector{UInt8}) = st.hheader === nothing ? 0 : getline!(st.hheader, line)

function readheader_body(w::Wfdb, record::Vector{UInt8}, line::Vector{UInt8})
    st = w.sig
    # Read the first line and check for a magic string.
    if _hgetline(st, line) == 0
        wfdb_error(w, "init: record %s header is empty\n", record)
        return Int32(-2)
    end
    if length(line) >= 5 && view(line, 1:5) == b"#wfdb"
        major, minor, release = Ref{Int32}(0), Ref{Int32}(0), Ref{Int32}(0)
        n = csscanf(cstr(line[6:end]), "%d.%d.%d", major, minor, release)
        if (n > 0 && major[] > WFDB_MAJOR) ||
           (n > 1 && major[] == WFDB_MAJOR && minor[] > WFDB_MINOR) ||
           (n > 2 && major[] == WFDB_MAJOR && minor[] == WFDB_MINOR && release[] > WFDB_RELEASE)
            wfdb_error(w, "init: reading record %s requires WFDB library version %d.%d.%d or later\n  (the most recent version is always available from http://physionet.org)\n",
                       record, major[], minor[], release[])
            return Int32(-1)
        end
    end

    # Get the first token (the record name) from the first non-empty,
    # non-comment line.
    local t::Strtok
    local p::Vector{UInt8}
    while true
        t = Strtok(copy(line))
        tok = strtok(t, _HSEP)
        if tok !== nothing && tok[1] != UInt8('#')
            p = tok
            break
        end
        if _hgetline(st, line) == 0
            wfdb_error(w, "init: can't find record name in record %s header\n", record)
            return Int32(-2)
        end
    end

    q = findnext(==(UInt8('/')), p, 2)
    if q !== nothing
        if st.in_msrec != 0
            wfdb_error(w, "init: record %s cannot be nested in another multi-segment record\n", record)
            return Int32(-2)
        end
        st.segments = _strtol10(view(p, q+1:length(p))) % Int32
        p = p[1:q-1]
    end

    # For local files, be sure that the name (p) within the header file
    # matches the name (record) provided as an argument to this function.
    # (wfdb-x: not for remote files either, as in C)
    isstd = st.hheader !== nothing && (is_std(st.hheader) || file_type(st.hheader) != WFDB_LOCAL)
    plen = length(p)
    if !isstd && !(length(record) >= plen && view(record, 1:plen) == p)
        # If there is a mismatch, check to see if the record argument
        # includes a directory separator; if so, compare only the final
        # portion of the argument against the name in the header file.
        q2 = length(record) - 1         # (0-based indices)
        s2 = q2
        while s2 > 0
            record[s2+1] in b"/\\:" && break
            s2 -= 1
        end
        if q2 > s2 && p != view(record, s2+2:length(record))
            wfdb_error(w, "init: record name in record %s header is incorrect\n", record)
            return Int32(-2)
        end
    end

    # Identify which type of header file is being read by trying to get
    # another token from the line which contains the record name.
    tok = strtok(t, _HSEP)
    if tok === nothing
        wfdb_error(w, "init: obsolete format in record %s header\n", record)
        return Int32(-2)
    end

    # The second token specifies the number of signals.
    nsig = Int(_strtol10(tok) % UInt32)

    # Determine the frame rate, if present and not set already.
    pf = strtok(t, _HSEP)
    if pf !== nothing
        f = _strtod0(pf)
        if f <= 0.0
            wfdb_error(w, "init: sampling frequency in record %s header is incorrect\n", record)
            return Int32(-2)
        end
        if st.ffreq > 0.0 && f != st.ffreq
            wfdb_error(w, "warning (init):\n")
            wfdb_error(w, " record %s sampling frequency differs", record)
            wfdb_error(w, " from that of previously opened record\n")
        else
            st.ffreq = f
        end
    elseif st.legacy && st.ffreq == 0.0
        st.ffreq = WFDB_DEFFREQ     # wfdb-x: legacy mode (original behavior)
    end
    # wfdb-x: no default sampling frequency (C assumed WFDB_DEFFREQ, 250 Hz):
    # without a frequency field (and none set by setsampfreq), it stays 0.

    # Set the sampling rate to the frame rate for now.
    st.sfreq = st.ffreq

    # Determine the counter frequency and the base counter value.
    st.cfreq = 0.0
    st.bcount = 0.0
    if pf !== nothing
        k = findfirst(==(UInt8('/')), pf)
        if k !== nothing
            qq = view(pf, k+1:length(pf))
            st.cfreq = _strtod0(qq)
            m = findfirst(==(UInt8('(')), qq)
            m === nothing || (st.bcount = _strtod0(view(qq, m+1:length(qq))))
        end
    end
    st.cfreq <= 0.0 && (st.cfreq = st.ffreq)

    # Determine the number of samples per signal, if present and not set
    # already.
    pn = strtok(t, _HSEP)
    if pn !== nothing
        ns = strtoll(pn, 10)[1]
        if ns < 0
            wfdb_error(w, "init: number of samples in record %s header is incorrect\n", record)
            return Int32(-2)
        end
        if st.nsamples == 0
            st.nsamples = ns
        elseif ns > 0 && ns != st.nsamples && st.in_msrec == 0
            wfdb_error(w, "warning (init):\n")
            wfdb_error(w, " record %s duration differs", record)
            wfdb_error(w, " from that of previously opened record\n")
            # nsamples must match the shortest record duration.
            st.nsamples > ns && (st.nsamples = ns)
        end
    else
        ns = Int64(0)
    end

    # Determine the base time and date, if present and not set already.
    pt = strtok(t, b"\n\r")
    if pt !== nothing && st.btime == 0 && setbasetime(w, pt) < 0
        return Int32(-2)    # error message will come from setbasetime
    end

    # Special processing for master header of a multi-segment record.
    if st.segments != 0 && st.in_msrec == 0
        if wfdbx_get_legacy(w) == 0     # wfdb-x: the segments are next to it
            st.msrec_dir = st.hdr_dir === nothing ? nothing : copy(st.hdr_dir)
            st.msrec_name = copy(record)
        end
        st.msbtime = st.btime
        st.msbdate = st.bdate
        st.msnsamples = st.nsamples
        # Read the names and lengths of the segment records.
        st.segarray = Seginfo[]
        st.have_segarray = true
        ns = Int64(0)
        for _ in 1:max(Int(st.segments), 0)
            # Get next segment spec, skip empty lines and comments.
            local name::Vector{UInt8}
            local lenp::Union{Nothing,Vector{UInt8}}
            while true
                if _hgetline(st, line) == 0
                    return segfail(w, cformat("init: unexpected EOF in header file for record %s\n", record))
                end
                tk = Strtok(copy(line))
                tok = strtok(tk, _HSEP)
                if tok !== nothing && tok[1] != UInt8('#')
                    name = tok
                    lenp = strtok(tk, _HSEP)
                    break
                end
            end
            if name[1] == UInt8('+')
                return segfail(w, cformat("init: `%s' is not a valid segment name in record %s\n", name, record))
            end
            if length(name) > WFDB_MAXRNL
                return segfail(w, cformat("init: `%s' is too long for a segment name in record %s\n", name, record))
            end
            nsamp = lenp === nothing ? Int64(-1) : strtoll(lenp, 10)[1]
            if lenp !== nothing && nsamp >= 0
                push!(st.segarray, Seginfo(recname=name, nsamp=nsamp, samp0=ns))
                ns += nsamp
            else
                return segfail(w, cformat("init: length must be specified for segment %s in record %s\n", name, record))
            end
        end
        st.segend = Int32(length(st.segarray) - 1)
        st.segp = 0
        if st.msnsamples == 0
            st.msnsamples = ns
        elseif ns != st.msnsamples
            wfdb_error(w, "warning (init): in record %s, stated record length (%lld)\n", record, st.msnsamples)
            wfdb_error(w, " does not match sum of segment lengths (%lld)\n", ns)
        end
        return Int32(0)
    end

    # Now get information for each signal.
    s = 0
    while s < nsig
        while length(st.hsd) <= s
            push!(st.hsd, HsData())
        end

        # Get the first token (the signal file name) from the next
        # non-empty, non-comment line.
        local tk::Strtok
        local p1::Vector{UInt8}
        while true
            if _hgetline(st, line) == 0
                wfdb_error(w, "init: unexpected EOF in header file for record %s\n", record)
                return Int32(-2)
            end
            tk = Strtok(copy(line))
            tok = strtok(tk, _HSEP)
            if tok !== nothing && tok[1] != UInt8('#')
                p1 = tok
                break
            end
        end

        if s > 0
            hp = st.hsd[s]
            hp_group, hp_fname, hp_fmt, hp_bsize = hp.info.group, hp.info.fname, hp.info.fmt, hp.info.bsize
        else
            hp_group, hp_fname, hp_fmt, hp_bsize = UInt32(0), nothing, Int32(0), Int32(0)
        end
        hs = st.hsd[s+1]
        info = hs.info

        # Determine the signal group number.
        if s == 0 || p1 != _str_or_null(hp_fname)
            info.group = s == 0 ? UInt32(0) : hp_group + UInt32(1)
            info.fname = p1
        else
            info.group = hp_group
            info.fname = hp_fname === nothing ? nothing : copy(hp_fname)
        end

        # Determine the signal format.
        pfm = strtok(tk, _HSEP)
        ok = false
        if pfm !== nothing
            info.fmt = _strtol10(pfm) % Int32
            ok = isfmt(info.fmt)
        end
        if !ok
            wfdb_error(w, "init: illegal format for signal %d, record %s\n", Int32(s), record)
            return Int32(-2)
        end
        info.spf = 1
        hs.skew = 0
        hs.start = 0
        # Parse the optional "xSPF", ":SKEW", and "+START" suffixes. (If the
        # token ends with one of the prefix characters, C reads past its
        # end; the suffix is ignored here.)
        pfv = pfm::Vector{UInt8}
        i = 0       # (0-based index in pfv)
        while true
            i += 1
            _byte0(pfv, i) == 0 && break
            if _byte0(pfv, i) == UInt8('x')
                i += 1
                _byte0(pfv, i) == 0 && break
                info.spf = _strtol10(view(pfv, i+1:length(pfv))) % Int32
                info.spf < 1 && (info.spf = 1)
            end
            if _byte0(pfv, i) == UInt8(':')
                i += 1
                _byte0(pfv, i) == 0 && break
                hs.skew = _strtol10(view(pfv, i+1:length(pfv))) % Int32
                hs.skew < 0 && (hs.skew = 0)
            end
            if _byte0(pfv, i) == UInt8('+')
                i += 1
                _byte0(pfv, i) == 0 && break
                hs.start = _strtol10(view(pfv, i+1:length(pfv)))
                hs.start < 0 && (hs.start = 0)
            end
        end
        info.spf > st.spfmax && (st.spfmax = info.spf)
        # The skew in samples (given in the header) is converted to skew in
        # frames here.
        hs.skew = d2i(hs.skew / info.spf + 0.5)

        # Determine the gain in ADC units per physical unit.
        pg = strtok(tk, _HSEP)
        info.gain = pg === nothing ? 0.0 : _strtod0(pg)

        # Determine the baseline if specified, and the physical units.
        nobaseline = true
        units = nothing
        if pg !== nothing
            k = 1
            while k <= length(pg) && pg[k] != UInt8('(') && pg[k] != UInt8('/')
                k += 1
            end
            if k <= length(pg) && pg[k] == UInt8('(')
                k += 1
                info.baseline = _strtol10(view(pg, k:length(pg))) % Int32
                nobaseline = false
            end
            while k <= length(pg)
                c = pg[k]
                k += 1
                (c == UInt8('/') && k <= length(pg)) && break
            end
            k <= length(pg) && (units = _strn(view(pg, k:length(pg)), WFDB_MAXUSL))
        end
        info.units = units

        # Determine the ADC resolution in bits. wfdb-x: if this number is
        # missing, it is unspecified (0); the C library inferred it from the
        # format or assumed WFDB_DEFRES (12 bits).
        r = strtok(tk, _HSEP)
        info.adcres = r !== nothing ? _strtol10(r) % Int32 :
                      st.legacy ? _legacy_adcres(info.fmt) : Int32(0)

        # Determine the ADC zero (assumed to be zero if missing).
        r = strtok(tk, _HSEP)
        info.adczero = r === nothing ? Int32(0) : _strtol10(r) % Int32

        # Set the baseline to adczero if no baseline field was found.
        nobaseline && (info.baseline = info.adczero)

        # Determine the initial value.
        r = strtok(tk, _HSEP)
        info.initval = r === nothing ? info.adczero : _strtol10(r) % Int32

        # Determine the checksum (assumed to be zero if missing).
        r = strtok(tk, _HSEP)
        if r !== nothing
            info.cksum = _strtol10(r) % Int32
            info.nsamp = ns
        else
            info.cksum = 0
            info.nsamp = 0
        end

        # Determine the block size (assumed to be zero if missing).
        r = strtok(tk, _HSEP)
        info.bsize = r === nothing ? Int32(0) : _strtol10(r) % Int32

        # Check that formats and block sizes match for signals belonging to
        # the same group.
        if s > 0 && info.group == hp_group && (info.fmt != hp_fmt || info.bsize != hp_bsize)
            wfdb_error(w, "init: error in specification of signal %d or %d\n", Int32(s - 1), Int32(s))
            return Int32(-2)
        end

        # Get the signal description.
        d = strtok(tk, b"\n\r")
        info.desc = d !== nothing ? _strn(d, WFDB_MAXDSL) :
                    cformat("record %s, signal %d", record, Int32(s))
        s += 1
    end
    setgvmode(w, st.gvmode)     # Reset sfreq if appropriate.
    Int32(s)
end

function segfail(w::Wfdb, msg::Vector{UInt8})
    wfdb_error_msg(w, msg)
    st = w.sig
    st.segarray = Seginfo[]
    st.have_segarray = false
    st.segments = 0
    Int32(-2)
end

hsdfree(w::Wfdb) = (empty!(w.sig.hsd); nothing)

# ---------------------------------------------------------------------------
# FLAC input and output (glue to flac.jl)

function _flac_pack!(fi::FlacIn, base::Int64)
    fi.base = base
    fi.nfr = (fi.total - base) ÷ fi.spf
    fi.leftover = (fi.total - base) - fi.nfr * fi.spf
    fi.f = 0
    fi.c = 0
    fi.k = 0
    nothing
end

"The MD5 check of a FLAC input when it is closed (`flac_isclose`)."
function flac_isclose(w::Wfdb, ig::IgData)
    fi = ig.flac
    fi === nothing && return nothing
    if fi.md5_check && fi.has_md5 && fi.have_decoded_md5 && !fi.seeked
        if any(!iszero, fi.md5) && fi.md5 != fi.decoded_md5
            wfdb_error(w, "isigclose: warning: incorrect MD5 hash in FLAC input\n")
        end
    end
    nothing
end

function flac_putsamp(og::OgData, v::Int32, fmt::Int32)
    if fmt == 508
        v = Int32(v % Int8)
    elseif fmt == 516
        v = Int32(v % Int16)
    elseif fmt == 524
        v = (v << 8) >> 8
    end
    fo = og.flac
    fo === nothing && return Int32(-1)
    empty!(fo.pending)
    flac_put!(fo.enc, v, fo.pending)
    if !isempty(fo.pending) && og.fp !== nothing
        fwrite(og.fp, fo.pending)
    end
    Int32(0)
end

function flac_osopen(og::OgData)
    fo = og.flac
    fo === nothing && return Int32(0)
    hdr = flac_header!(fo.enc)
    fp = og.fp
    fo.header_pos = fp === nothing ? Int64(0) : ftell(fp)
    fp === nothing || fwrite(fp, hdr)
    Int32(0)
end

function flac_osclose(og::OgData)
    fo = og.flac
    og.flac = nothing
    if fo !== nothing
        empty!(fo.pending)
        flac_finish!(fo.enc, fo.pending)
        fp = og.fp
        if fp !== nothing
            isempty(fo.pending) || fwrite(fp, fo.pending)
            # Rewrite the STREAMINFO block (after "fLaC" and its block header).
            if fseek(fp, fo.header_pos + 8, SEEK_SET) == 0
                fwrite(fp, flac_streaminfo(fo.enc))
                fseek(fp, 0, SEEK_END)
            end
        end
    end
    og.bp = 0
    og.be = 0
    nothing
end

# Decode the FLAC file of input group g (0-based) at its first use.
function flac_decode_group(w::Wfdb, g::Int)
    ig = w.sig.igd[g+1]
    fi = ig.flac
    fi === nothing && return nothing
    fi.decoded = true
    data = ig.fp === nothing ? UInt8[] : read_to_end(ig.fp)
    d = flac_decode(data, fi.nsig, fi.datb)
    status = d.status
    d.error_message === nothing || wfdb_error_msg(w, d.error_message)
    msg = status == FLAC_SYNC ? "getvec: unable to decode FLAC (lost sync)\n" :
          status == FLAC_HEADER ? "getvec: unable to decode FLAC (invalid header)\n" :
          status == FLAC_CRC ? "getvec: unable to decode FLAC (CRC mismatch)\n" :
          status == FLAC_UNPARSEABLE ? "getvec: unable to decode FLAC (unsupported format)\n" :
          status == FLAC_EOF ? "getvec: unable to decode FLAC\n" :
          status == FLAC_META ? "getvec: unexpected FLAC decoding error\n" : nothing
    msg === nothing || wfdb_error_msg(w, msg)
    if status != FLAC_OK
        fi.failed = true
        return nothing
    end
    fi.chans = d.chans
    fi.block_ends = d.block_ends
    fi.total = isempty(fi.chans) ? Int64(0) : Int64(length(fi.chans[1]))
    fi.has_md5 = d.has_md5
    fi.md5 = collect(UInt8, d.md5)
    if fi.md5_check && fi.total != 0
        fi.decoded_md5 = collect(UInt8, flac_samples_md5(fi.chans, d.bps))
        fi.have_decoded_md5 = true
    end
    _flac_pack!(fi, Int64(0))
    nothing
end

function flac_getsamp(w::Wfdb, g::Int)
    ig = w.sig.igd[g+1]
    fi = ig.flac
    if fi === nothing
        ig.stat = -2
        return Int32(0)
    end
    fi.decoded || flac_decode_group(w, g)
    if fi.failed
        ig.stat = -2
        return Int32(0)
    end
    fi.aborted && return Int32(0)  # (the decoder does nothing; ig.stat is negative)
    if fi.f < fi.nfr
        # The frame of the next sample must have been decoded.
        need = fi.base + (fi.f + 1) * fi.spf
        if fi.discarded || need > fi.dec_end
            ig.stat < 0 && return fi.dec_end < fi.total ? _flac_abort(w, g) : Int32(0)
            fi.dec_end = _flac_block_end(fi, need)
        end
        v = fi.chans[fi.c+1][fi.base+fi.f*fi.spf+fi.k+1]
        fi.k += Int32(1)
        if fi.k == fi.spf
            fi.k = 0
            fi.c += 1
            if fi.c == length(fi.chans)
                fi.c = 0
                fi.f += 1
            end
        end
        return v
    end
    fi.discarded && fi.dec_end < fi.total && return _flac_abort(w, g)
    ig.stat < 0 && return Int32(0)
    fi.dec_end = fi.total
    left = fi.leftover
    fi.leftover = 0
    ig.stat = 0
    left != 0 && wfdb_error(w, "getvec: warning: %d samples left over at end of file\n", left % Int32)
    Int32(0)
end

# Decoding a block after a failed seek (ig.stat < 0): iflac_samples() aborts
# the decoder, and flac_getsamp() reports the error.
function _flac_abort(w::Wfdb, g::Int)
    ig = w.sig.igd[g+1]
    ig.flac.aborted = true
    if ig.stat != -2
        wfdb_error(w, "getvec: unexpected FLAC decoding error\n")
        ig.stat = -2
    end
    Int32(0)
end

# Prepare input group g (0-based) for FLAC decoding; its signals are
# hsd[si+1:si+ns].
function flac_isopen(w::Wfdb, g::Int, si::Int, ns::Int)
    if ns > FLAC_MAX_CHANNELS
        wfdb_error(w, "isigopen: cannot store %u signals in a single FLAC file\n", UInt32(ns))
        return Int32(-1)
    end
    hs = w.sig.hsd
    for k in si+2:si+ns
        if hs[k].info.spf != hs[si+1].info.spf
            wfdb_error(w, "isigopen: every signal in a FLAC file must have\n  the same sampling frequency\n")
            return Int32(-1)
        end
    end
    p = cgetenv("WFDB_FLAC_CHECK_MD5")
    ig = w.sig.igd[g+1]
    ig.flac = FlacIn(ns, hs[si+1].info.fmt - FLAC_FMT_BASE, hs[si+1].info.spf,
                     p !== nothing && !isempty(p))
    ig.count = 0
    Int32(0)
end

function flac_isseek(w::Wfdb, g::Int, t::Int64)
    ig = w.sig.igd[g+1]
    fi = ig.flac
    fi === nothing || fi.decoded || flac_decode_group(w, g)
    ig.stat = 1
    ig.count = 0
    if fi === nothing
        ig.stat = -1
        return Int32(-1)
    end
    fi.seeked = true
    if fi.failed
        ig.stat = -1
        return Int32(-1)
    end
    tt = t * fi.spf + ig.start
    if fi.aborted || tt > fi.total || tt < 0
        # (libFLAC refuses to seek once decoding was aborted, or past the end
        # of the stream; the buffered samples are discarded anyway)
        fi.discarded = true
        ig.stat = -1
        return Int32(-1)
    end
    _flac_pack!(fi, tt)
    fi.discarded = false
    # The seek decodes the block that contains sample tt - 1 (sample 0 if tt
    # is 0): libFLAC seeks to it, and the first sample is skipped.
    fi.dec_end = _flac_block_end(fi, max(tt, Int64(1)))
    ig.stat
end

# Prepare output group g (0-based) for FLAC encoding of the signals si.
function flac_osinit(w::Wfdb, g::Int, si::AbstractVector{Siginfo}, ns::Int)
    if ns > FLAC_MAX_CHANNELS
        wfdb_error(w, "osigfopen: cannot store %u signals in a single FLAC file\n", UInt32(ns))
        return Int32(-1)
    end
    for k in 2:ns
        if si[k].spf != si[1].spf
            wfdb_error(w, "osigfopen: every signal in a FLAC file must have\n  the same sampling frequency\n")
            return Int32(-1)
        end
    end
    spf = si[1].spf < 1 ? Int32(1) : si[1].spf
    og = w.sig.ogd[g+1]
    og.flac = FlacOut(FlacEncoder(ns, si[1].fmt - FLAC_FMT_BASE, spf), 0, UInt8[])
    # Make the buffer exactly large enough to hold a single frame (a non-zero
    # bsize also prevents wfdb_osflush from flushing it).
    og.bsize = Int32(ns) * si[1].spf * Int32(4)
    Int32(0)
end

# ---------------------------------------------------------------------------
# Closing signals

function isigclose(w::Wfdb)
    st = w.sig
    if st.have_sbuf && st.in_msrec == 0
        st.sbuf = Int32[]
        st.have_sbuf = false
        st.sample_vflag = 0
    end
    empty!(st.isd)
    st.nisig = 0
    st.framelen = 0

    while !isempty(st.igd)
        ig = pop!(st.igd)
        flac_isclose(w, ig)
        _close!(ig.fp)
        ig.fp = nothing
    end
    st.nigroup = 0

    st.istime = 0
    st.gvc = 1
    st.ispfmax = 1
    _close!(st.hheader)
    st.hheader = nothing
    st.linebuf = UInt8[]
    (st.nosig == 0 && !isempty(st.hsd)) && empty!(st.hsd)
    nothing
end

function osigclose(w::Wfdb)
    st = w.sig
    stat = Int32(0)
    for k in 1:min(st.nogroup, length(st.ogd))
        st.ogd[k].force_flush = 1
    end
    wfdb_osflush(w)

    empty!(st.osd)
    st.nosig = 0

    while !isempty(st.ogd)
        og = pop!(st.ogd)
        maxogroup = Int32(length(st.ogd))
        fp = og.fp
        fp === nothing && continue
        og.flac === nothing || flac_osclose(og)
        # If a block size has been defined, null-pad the buffer.
        if og.bsize != 0
            while og.bp < og.be
                og.buf[og.bp+1] = 0x00
                og.bp += 1
            end
        end
        og.fp = nothing
        # Flush the last block unless it's empty.
        og.bp != 0 && fwrite(fp, view(og.buf, 1:og.bp))
        is_std(fp) && fflush(fp)
        errflag = ferror(fp)
        # Close the file (except stdout, which is closed on exit).
        if !is_std(fp)
            fclose(fp) != 0 && (errflag = true)
        end
        if errflag
            wfdb_error(w, "osigclose: write error in signal group %d\n", maxogroup)
            stat = Int32(-4)
        end
    end
    st.nogroup = 0

    st.ostime = 0
    oh = st.oheader
    if oh !== nothing
        st.oheader = nothing
        errflag = ferror(oh)
        fclose(oh) != 0 && (errflag = true)
        if errflag
            wfdb_error(w, "osigclose: write error in header file\n")
            stat = Int32(-4)
        end
        st.outinfo == OUTINFO_HEADER && (st.outinfo = OUTINFO_NONE)
    end
    (st.nisig == 0 && !isempty(st.hsd)) && hsdfree(w)
    stat
end

# ---------------------------------------------------------------------------
# Input positioning and reading

function seekerr(w::Wfdb, g::Integer)
    wfdb_error(w, "isigsettime: improper seek on signal group %d\n", UInt32(g))
    Int32(-1)
end

function overflow(w::Wfdb, g::Integer)
    wfdb_error(w, "isigsettime: overflow in signal group %d\n", UInt32(g))
    Int32(-1)
end

"""
    isgsetframe(w, g, t) -> Int32

Skip to frame `t` in input signal group `g` (C `isgsetframe`).
"""
function isgsetframe(w::Wfdb, g::Int, t::Int64)
    st = w.sig
    # Do nothing if there is no more than one input signal group and the
    # input pointer is correct already.
    if st.nigroup < 2 && st.istime == t && st.gvc == st.ispfmax && g < length(st.igd) &&
       st.igd[g+1].start == 0
        return Int32(0)
    end

    # Find the first signal that belongs to group g.
    nisig = st.nisig
    s = 0
    while s < nisig && g != st.isd[s+1].info.group
        s += 1
    end
    if s == nisig
        wfdb_error(w, "isgsettime: incorrect signal group number %d\n", Int32(g))
        return Int32(-2)
    end

    # If the current record contains multiple segments, locate the segment
    # containing the desired sample.
    if st.in_msrec != 0
        tseg = st.segp
        t >= st.msnsamples && return seekerr(w, g)
        while tseg > 0 && t < st.segarray[tseg+1].samp0
            tseg -= 1
        end
        while t >= st.segarray[tseg+1].samp0 + st.segarray[tseg+1].nsamp && tseg < st.segend
            tseg += 1
        end
        if st.segp != tseg
            st.segp = tseg
            name = copy(st.segarray[tseg+1].recname)
            if isigopen(w, name, nothing, st.nvsig) <= 0
                wfdb_error(w, "isigsettime: can't open segment %s\n", name)
                return Int32(-1)
            end
            # Following isigopen(), nigroup may have changed: seek on all
            # non-zero groups (regardless of g), but on group 0 only if g is 0.
            h = 1
            while h < st.nigroup
                i = isgsetframe(w, h, t)
                i != 0 && return i
                h += 1
            end
            return g == 0 ? isgsetframe(w, 0, t) : Int32(0)
        end
        t -= st.segarray[st.segp+1].samp0
    end

    ig = st.igd[g+1]
    ig.initial_skip = 0
    # Determine the number of samples per frame for signals in the group.
    n = 0
    nn = UInt32(0)
    while s + n < nisig && st.isd[s+n+1].info.group == g
        nn += st.isd[s+n+1].info.spf % UInt32
        n += 1
    end
    msoff = st.in_msrec != 0 ? st.segarray[st.segp+1].samp0 : Int64(0)
    # Determine the number of bytes per sample interval in the file.
    d = UInt32(1)
    fmt = st.isd[s+1].info.fmt
    if fmt == 0
        if t < st.nsamples
            st.gvc = st.ispfmax
            s == 0 && (st.istime = st.in_msrec != 0 ? t + msoff : t)
            st.isd[s+1].info.nsamp = st.nsamples - t
            ig.stat = 1
            return Int32(0)
        else
            s == 0 && (st.istime = st.in_msrec != 0 ? st.msnsamples : st.nsamples)
            st.isd[s+1].info.nsamp = 0
            return Int32(-1)
        end
    elseif fmt == 508 || fmt == 516 || fmt == 524
        flac_isseek(w, g, t) < 0 && return seekerr(w, g)
        # Reset the getvec sample-within-frame counter.
        st.gvc = st.ispfmax
        # Reset the time (if signal 0 belongs to the group) and disable
        # checksum testing.
        s == 0 && (st.istime = st.in_msrec != 0 ? t + msoff : t)
        for k in 1:n
            st.isd[s+k].info.nsamp = 0
        end
        return Int32(0)
    elseif fmt == 16 || fmt == 61 || fmt == 160
        nn > typemax(UInt32) ÷ 2 && return overflow(w, g)
        b = 2 * nn
    elseif fmt == 212
        nn > typemax(UInt32) ÷ 3 && return overflow(w, g)
        # Reset the input counter.
        ig.count = 0
        # If the desired sample does not lie on a byte boundary, seek to the
        # previous sample and then read ahead.
        if (nn & 1) != 0 && (t & 1) != 0
            st.in_msrec != 0 && (t += msoff)    # absolute time
            i = isgsetframe(w, g, t - 1)
            i != 0 && return i
            for _ in 1:nn
                r212(ig)
            end
            st.istime += 1
            k = 0
            while s + k < nisig && st.isd[s+k+1].info.group == g
                st.isd[s+k+1].info.nsamp = 0
                k += 1
            end
            return Int32(0)
        end
        b = 3 * nn
        d = UInt32(2)
    elseif fmt == 310 || fmt == 311
        nn > typemax(UInt32) ÷ 4 && return overflow(w, g)
        ig.count = 0
        # If the desired sample does not lie on a byte boundary, seek to the
        # closest previous sample that does, then read ahead.
        trem = (t % 3) % Int32
        if (nn % 3) != 0 && trem != 0
            st.in_msrec != 0 && (t += msoff)
            i = isgsetframe(w, g, t - trem)
            i != 0 && return i
            j = nn * (trem % UInt32)
            while j > 0
                fmt == 310 ? r310(ig) : r311(ig)
                j -= UInt32(1)
            end
            st.istime += trem
            k = 0
            while s + k < nisig && st.isd[s+k+1].info.group == g
                st.isd[s+k+1].info.nsamp = 0
                k += 1
            end
            return Int32(0)
        end
        b = 4 * nn
        d = UInt32(3)
    elseif fmt == 24
        nn > typemax(UInt32) ÷ 3 && return overflow(w, g)
        b = 3 * nn
    elseif fmt == 32
        nn > typemax(UInt32) ÷ 4 && return overflow(w, g)
        b = 4 * nn
    else    # 8, 80
        b = nn
    end

    start = ig.start
    if b == 0 || t > typemax(Int64) ÷ Int64(b) || (t * Int64(b)) ÷ Int64(d) > typemax(Int64) - start
        return seekerr(w, g)
    end

    bb = Int64(b)
    dd = Int64(d)
    # Seek to the beginning of the block which contains the desired sample.
    # For normal files, use fseek() to do so.
    if ig.seek != 0
        nb = (t * bb) ÷ dd + ig.start
        i = ig.bsize
        i == 0 && (i = st.ibsize)
        # Seek to a position such that the next block read will contain the
        # desired sample.
        tt = nb ÷ i
        fp = ig.fp
        if fp === nothing || fseek(fp, tt * i, SEEK_SET) != 0
            return seekerr(w, g)
        end
        nb %= i
    else
        # For special files, rewind if necessary and then read ahead.
        # Get the time of the earliest buffered sample ...
        t0 = st.istime - ig.bp ÷ bb
        # ... and that of the earliest unread sample.
        t1 = t0 + ig.be ÷ bb
        if t < t0
            # Either the desired sample has been read and has passed out of
            # the buffer, requiring a rewind ...
            fp = ig.fp
            if fp === nothing || fseek(fp, 0, SEEK_SET) != 0
                return seekerr(w, g)
            end
            nb = (t * bb) ÷ dd + ig.start
        elseif t < t1
            # ... or it is in the buffer already ...
            ig.bp = Int(((t - t0) * bb) ÷ dd)
            return Int32(0)
        else
            # ... or it has not yet been read.
            nb = ((t - t1) * bb) ÷ dd
        end
        n2 = min(max(Int(ig.bsize), 0), length(ig.buf))
        while nb > ig.bsize
            fp = ig.fp
            (fp === nothing || feof(fp)) && break
            nb -= fread!(fp, ig.buf, n2)
        end
    end

    # Reset the block pointer to indicate nothing has been read in the
    # current block.
    ig.bp = ig.be
    ig.stat = 1
    # Read any bytes in the current block that precede the desired sample.
    while nb > 0 && ig.stat > 0
        nb -= 1
        r8(ig)
    end
    ig.stat <= 0 && return Int32(-1)

    # Reset the getvec sample-within-frame counter.
    st.gvc = st.ispfmax

    # Reset the time (if signal 0 belongs to the group) and disable checksum
    # testing (by setting the number of samples remaining to 0).
    s == 0 && (st.istime = st.in_msrec != 0 ? t + st.segarray[st.segp+1].samp0 : t)
    for k in 1:n
        st.isd[s+k].info.nsamp = 0
    end
    Int32(0)
end

"""
    getskewedframe(w, vec, off) -> Int32

Read an input frame, without skew correction, into `vec[off+1:...]`.
"""
function getskewedframe(w::Wfdb, vecstart::Vector{Int32}, off::Int)
    st = w.sig
    stat = Int32(st.nisig)
    stat == 0 && return st.nvsig > 0 ? Int32(-1) : Int32(0)
    nisig = st.nisig
    isd = st.isd
    igd = st.igd
    if st.istime == 0
        for s in 1:nisig
            isd[s].samp = isd[s].info.initval
        end
    end
    g = st.nigroup
    while g > 0
        # Go through groups in reverse order since seeking on group 0 should
        # always be done last.
        g -= 1
        if igd[g+1].initial_skip != 0
            t0 = st.in_msrec != 0 ? st.segarray[st.segp+1].samp0 : Int64(0)
            isgsetframe(w, g, t0)
        end
    end

    # If the vector needs to be rearranged (variable-layout record), then
    # read samples into a temporary buffer.
    need_sigmap = st.need_sigmap != 0
    target = need_sigmap ? st.ovec : vecstart
    toff = need_sigmap ? 0 : off
    pad = (st.gvmode & WFDB_GVPAD) != 0
    switch = false
    vi = toff
    for s in 1:nisig
        is = isd[s]
        info = is.info
        fmt = info.fmt
        group = Int(info.group)
        ig = igd[group+1]
        cksum = info.cksum
        for _ in 1:info.spf
            if fmt == 16
                v = r16(ig)
                inval = INVALID_16
            elseif fmt == 212
                v = r212(ig)
                inval = INVALID_12
            elseif fmt == 0
                # null signal: return sample tagged as invalid
                v = pad ? is.samp : WFDB_INVALID_SAMPLE
                target[vi+1] = v
                info.nsamp == 0 && (ig.stat = -1)
                inval = Int32(0)
            elseif fmt == 61
                v = r61(ig)
                inval = INVALID_16
            elseif fmt == 80
                v = r80(ig)
                inval = INVALID_8
            elseif fmt == 160
                v = r160(ig)
                inval = INVALID_16
            elseif fmt == 310
                v = r310(ig)
                inval = INVALID_10
            elseif fmt == 311
                v = r311(ig)
                inval = INVALID_10
            elseif fmt == 24
                v = r24(ig)
                inval = INVALID_24
            elseif fmt == 32
                v = r32(ig)
                inval = INVALID_32
            elseif fmt == 508
                v = flac_getsamp(w, group)
                inval = INVALID_8
            elseif fmt == 516
                v = flac_getsamp(w, group)
                inval = INVALID_16
            elseif fmt == 524
                v = flac_getsamp(w, group)
                inval = INVALID_24
            else
                # 8-bit first differences
                is.samp += r8(ig)
                v = is.samp
                target[vi+1] = v
                inval = Int32(0)
            end
            if fmt != 0 && fmt != 8 && isfmt(fmt)
                if v == inval
                    target[vi+1] = pad ? is.samp : WFDB_INVALID_SAMPLE
                else
                    is.samp = v
                    target[vi+1] = v
                end
            end
            if ig.stat <= 0
                # End of file -- reset input counter.
                ig.count = 0
                if ig.stat == -2
                    # error in decoding compressed data
                    stat = Int32(-3)
                elseif info.nsamp > 0
                    wfdb_error(w, "getvec: unexpected EOF in signal %d\n", Int32(s - 1))
                    stat = Int32(-3)
                elseif st.in_msrec != 0 && st.have_segarray && st.segp >= 0 && st.segp < st.segend
                    info.cksum = cksum
                    switch = true
                    break
                else
                    stat = Int32(-1)
                end
            end
            cksum -= v
            vi += 1
        end
        switch && break
        info.cksum = cksum
        if info.nsamp >= 0
            info.nsamp -= 1
            if info.nsamp == 0 && (cksum & Int32(0xffff)) != 0 && st.in_msrec == 0 &&
               st.isedf == 0 && fmt != 0
                # wfdb-x: not printed during a high-level read (which warns
                # instead), but recorded for wfdberror
                pr = w.io.error_print
                st.cksum_quiet && (w.io.error_print = false)
                wfdb_error(w, "getvec: checksum error in signal %d\n", Int32(s - 1))
                w.io.error_print = pr
                stat = Int32(-4)
            end
        end
    end
    if switch
        st.segp += Int32(1)
        name = copy(st.segarray[st.segp+1].recname)
        if isigopen(w, name, nothing, st.nvsig) <= 0
            wfdb_error(w, "getvec: error opening segment %s\n", name)
            return Int32(-3)    # avoid looping if segment is bad
        end
        st.istime = st.segarray[st.segp+1].samp0
        return getskewedframe(w, vecstart, off)
    end

    if need_sigmap
        sigmap(w, vecstart, off, st.ovec)
    elseif st.framelen != st.tspf
        for s in max(st.framelen, 0):st.tspf-1
            vecstart[off+s+1] = WFDB_INVALID_SAMPLE
        end
    end
    stat
end

"Create a virtual signal vector from a raw sample vector (C `sigmap`)."
function sigmap(w::Wfdb, vector::Vector{Int32}, off::Int, ivec::Vector{Int32})
    st = w.sig
    for i in 1:max(Int(st.tspf), 0)
        m = st.smi[i]
        x = ivec[m.index+1]
        if x == WFDB_INVALID_SAMPLE
            vector[off+i] = WFDB_INVALID_SAMPLE
        else
            # Scale the input sample and round it to the nearest integer
            # (halfway cases are rounded up; m.offset includes 0.5).
            v = x * m.scale + m.offset
            vector[off+i] = if m.sample_offset != 0
                d2i(v) + m.sample_offset
            elseif v >= 0.0
                v <= WFDB_SAMPLE_MAX ? unsafe_trunc(Int32, v) : WFDB_SAMPLE_MAX
            elseif v >= WFDB_SAMPLE_MIN
                r = unsafe_trunc(Int32, v)
                r > v ? r - Int32(1) : r
            else
                WFDB_SAMPLE_MIN
            end
        end
    end
    nothing
end

"Read a sample from each input signal without resampling (C `rgetvec`)."
function rgetvec(w::Wfdb, vector::Vector{Int32}, off::Int)
    st = w.sig
    st.ispfmax < 2 && return getframe_at(w, vector, off)    # all signals at the same frequency
    tv = st.tvector
    if (st.gvmode & WFDB_HIGHRES) != WFDB_HIGHRES
        # return one sample per frame, decimating by averaging if necessary
        st.rgetvec_stat = getframe_at(w, tv, 0)
        tp = 0
        for s in 1:max(Int(st.nvsig), 0)
            sf = st.vsd[s].info.spf
            vector[off+s] = meansamp(tv, tp, sf)
            tp += sf
        end
    else
        # return ispfmax samples per frame, using zero-order interpolation
        # if necessary
        if st.gvc >= st.ispfmax
            st.rgetvec_stat = getframe_at(w, tv, 0)
            st.gvc = 0
        end
        ispfmax = Int32(st.ispfmax)
        gvc = st.gvc
        tp = 0
        for s in 1:max(Int(st.nvsig), 0)
            v = st.vsd[s]
            sf = v.info.spf
            if gvc == 0
                v.gvindex = 0
                v.gvcount = -ispfmax
            else
                v.gvcount += sf
                if v.gvcount >= 0
                    v.gvindex += Int32(1)
                    v.gvcount -= ispfmax
                end
            end
            vector[off+s] = tv[tp+v.gvindex+1]
            tp += sf
        end
        st.gvc += Int32(1)
    end
    st.rgetvec_stat
end

# ---------------------------------------------------------------------------
# Opening output signals

# wfdb-x: an output signal file is never one of the input files. In normal
# mode, openosig refuses to create (and so to truncate) an output signal file
# that is the same file as a signal file of the open input record: a signal
# file open for input, or a signal file of any segment of the open
# multi-segment record (read from the segment's header; segments are opened
# later, as they are reached). "The same file" is decided by the files, not
# by their names: device and inode numbers (fstat; on Windows, those that
# Julia's stat gives). Decided by Reza Sameni, Oct 2026: e.g., "xform -i vlay
# -o fmt16", fmt16 being a segment of vlay, truncated fmt16.dat while reading
# it, with a platform-dependent result and the input destroyed. Legacy mode:
# no check (the original behavior).

# The identity (device, inode) of the open local file f (not the standard
# input or output, not a URL), or nothing.
function _file_id(f::Union{Nothing,WfdbFile})
    (f === nothing || f.kind != _K_FILE || f.remote || f.fd < 0 || f.closed) && return nothing
    s = try
        stat(Base.RawFD(f.fd))
    catch
        return nothing
    end
    ispath(s) ? (s.device, s.inode) : nothing
end

# The tokens of a header line (separated by spaces, tabs, CR and LF).
_header_tokens(line::Vector{UInt8}) =
    [t for t in Base.split(String(copy(line)), (' ', '\t', '\n', '\r')) if !isempty(t)]

# True if one of the signal files named in the header of segment seg (of the
# open multi-segment record) is the file fid. The header and the signal
# files are located as isigopen locates them in normal mode; one that
# cannot be found (or is at a URL) is not fid. No message.
function _segment_has_file(w::Wfdb, seg::Vector{UInt8}, fid)
    st = w.sig
    (seg == b"~" || !_in_header_dir(seg) || (st.msrec_dir !== nothing && _is_url(st.msrec_dir))) &&
        return false
    hf = st.msrec_name !== nothing ? wfdbx_open_in(w, st.msrec_dir, "hea", seg, st.msrec_name) :
         wfdb_open(w, "hea", seg, WFDB_READ)
    hf === nothing && return false
    d = (file_type(hf) == WFDB_LOCAL && !is_std(hf)) ? wfdbx_dirname(wfdb_filename(w)) : nothing
    found = false
    nsig = -1
    line = UInt8[]
    try
        while !found && nsig != 0
            getline!(hf, line) == 0 && break
            tok = _header_tokens(line)
            (isempty(tok) || startswith(tok[1], '#')) && continue
            if nsig < 0             # the record line
                ('/' in tok[1] || length(tok) < 2) && break
                nsig = strtol(tok[2], 10)[1]
                nsig <= 0 && break
                continue
            end
            nsig -= 1               # a signal line: file name, format, ...
            name = Vector{UInt8}(codeunits(tok[1]))
            (length(tok) < 2 || strtol(tok[2], 10)[1] == 0 || name == b"-" ||
             !_in_header_dir(name) || d === nothing || _is_url(d)) && continue
            sf = wfdbx_open_in(w, d, nothing, name, seg)
            if sf !== nothing
                found = _file_id(sf) == fid
                fclose(sf)
            end
        end
    finally
        fclose(hf)
    end
    found
end

# True if the output signal file fname (as named in an output signal
# specification, created by wfdb_open(fname, nothing, WFDB_WRITE)) exists
# and is one of the signal files of the open input record (see above).
function _is_input_file(w::Wfdb, fname::OptByteStr)
    st = w.sig
    path = wfdbx_output_file(w, fname)
    path === nothing && return false
    s = stat(String(copy(path)))
    ispath(s) || return false       # it does not exist: it is not an input file
    fid = (s.device, s.inode)
    for g in 1:min(st.nigroup, length(st.igd))
        _file_id(st.igd[g].fp) == fid && return true
    end
    if st.in_msrec != 0 && st.have_segarray && !isempty(st.segarray)
        for k in 1:min(Int(st.segend) + 1, length(st.segarray))
            _segment_has_file(w, copy(cstr(st.segarray[k].recname)), fid) && return true
        end
    end
    false
end

function openosig(w::Wfdb, func::String, si_out::Union{Nothing,AbstractVector{Siginfo}},
                  si_in::AbstractVector{Siginfo}, nsig::Int)
    nsig == 0 && return Int32(0)
    st = w.sig
    # Allocate workspace for output signals and signal groups.
    while length(st.osd) < st.nosig + nsig
        push!(st.osd, OsData())
    end
    while length(st.ogd) < st.nogroup + Int(si_in[nsig].group) + 1
        push!(st.ogd, OgData())
    end
    # Initialize local variables.
    st.obsize <= 0 && (st.obsize = WFDB_BUFSIZ)
    # Set the group number adjustment.
    ga = UInt32(st.nogroup)

    # Open the signal files. One signal is handled per iteration.
    s = 0
    while s < nsig
        osi = st.nosig + 1              # (Julia index)
        op = s == 0 ? osi : osi - 1
        info = copy(si_in[s+1])
        info.spf < 1 && (info.spf = 1)
        info.cksum = 0
        info.nsamp = 0
        info.group += ga
        if si_out !== nothing && s < length(si_out)
            si_out[s+1] = copy(info)
        end
        os = st.osd[osi]
        os.info = info
        os.samp = 0

        # Check if this signal is in the same group as the previous one.
        if s == 0 || info.group != st.osd[op].info.group
            gi = Int(info.group)
            while length(st.ogd) < gi + 1
                push!(st.ogd, OgData())
            end
            og = st.ogd[gi+1]
            og.bsize = info.bsize
            if isflacfmt(info.fmt)
                ns = 1
                while s + ns < nsig && si_in[s+ns+1].group == si_in[s+1].group
                    ns += 1
                end
                if flac_osinit(w, gi, view(si_in, s+1:s+ns), ns) < 0
                    osigclose(w)
                    return Int32(-3)
                end
            end
            # This is the first signal in a new group; allocate buffer.
            obuflen = Int(og.bsize != 0 ? og.bsize : st.obsize)
            og.buf = zeros(UInt8, obuflen)
            og.bp = 0
            og.be = obuflen
            if info.fmt == 0
                # If the signal file name was NULL or "~", don't create a
                # signal file.
                if info.fname === nothing || cstr(info.fname) == b"~"
                    og.fp = nothing
                else
                    # Otherwise, assume that the user wants to write a signal
                    # file in the default format (16).
                    info.fmt = 16
                end
            end
            if info.fmt != 0
                # wfdb-x: never an input file (see _is_input_file)
                if wfdbx_get_legacy(w) == 0 && _is_input_file(w, info.fname)
                    wfdb_error(w, "%s: output file %s is also an input file\n", func, info.fname)
                    og.buf = UInt8[]
                    osigclose(w)
                    return Int32(-3)
                end
                # An error in opening an output file is fatal.
                fname = info.fname
                f = wfdb_open(w, fname === nothing ? nothing : cstr(fname), nothing, WFDB_WRITE)
                og.fp = f
                if f === nothing
                    wfdb_error(w, "%s: can't open %s\n", func, fname)
                    og.buf = UInt8[]
                    osigclose(w)
                    return Int32(-3)
                end
            end
            if isflacfmt(info.fmt) && og.flac !== nothing && flac_osopen(og) < 0
                osigclose(w)
                return Int32(-3)
            end
            st.nogroup += 1
        else
            # This signal belongs to the same group as the previous one.
            prev = st.osd[op].info
            if info.fmt != prev.fmt || info.bsize != prev.bsize
                wfdb_error(w, "%s: error in specification of signal %d or %d\n", func,
                           Int32(s - 1), Int32(s))
                return Int32(-2)
            end
        end
        st.nosig += 1
        s += 1
    end
    Int32(s)
end

# ---------------------------------------------------------------------------
# Hooks used by wfdbinit.jl

"""
    wfdb_sampquit([w])

Release the `sample()` buffer (called by `wfdbquit`).
"""
function wfdb_sampquit(w::Wfdb)
    st = w.sig
    if st.have_sbuf
        st.sbuf = Int32[]
        st.have_sbuf = false
        st.sample_vflag = 0
    end
    nothing
end

"""
    wfdb_sigclose([w])

Close all signals and reset the signal state (called by `wfdbquit`).
"""
function wfdb_sigclose(w::Wfdb)
    isigclose(w)
    osigclose(w)
    st = w.sig
    st.btime = 0
    st.bdate = 0
    st.nsamples = 0
    st.msbtime = 0
    st.msbdate = 0
    st.msnsamples = 0
    st.sfreq = 0.0
    st.ifreq = 0.0
    st.ffreq = 0.0
    st.pdays = -1
    st.segments = 0
    st.in_msrec = 0
    st.skewmax = 0
    st.hdr_dir = st.msrec_dir = st.msrec_name = nothing     # wfdb-x
    if st.have_dsbuf
        st.dsbuf = Int32[]
        st.have_dsbuf = false
        st.dsbi = -1
    end
    if st.have_segarray
        st.segarray = Seginfo[]
        st.have_segarray = false
        st.segp = -1
        st.segend = -1
    end
    st.gv0 = Int32[]
    st.gv1 = Int32[]
    st.tvector = Int32[]
    st.uvector = Int32[]
    st.vvector = Int32[]
    st.tuvlen = 0
    sigmap_cleanup(w)
    nothing
end

"""
    wfdb_osflush([w])

Write out buffered output samples (called by `wfdbflush`).
"""
function wfdb_osflush(w::Wfdb)
    st = w.sig
    (isempty(st.osd) || isempty(st.ogd)) && return nothing
    obsize = st.obsize
    for s in 1:min(st.nosig, length(st.osd))
        g = Int(st.osd[s].info.group)
        g >= length(st.ogd) && continue
        fmt = st.osd[s].info.fmt
        og = st.ogd[g+1]
        if og.nrewind == 0
            if og.force_flush == 0 && og.seek == 0
                seekable = og.bsize == 0 && og.fp !== nothing && fseek(og.fp, 0, SEEK_CUR) == 0
                og.seek = seekable ? 1 : -1
            end
            if og.force_flush != 0 || og.seek > 0
                # Either we are closing the file (osigclose() was called), or
                # the file is seekable: write out any partially-completed
                # sets of bit-packed samples.
                if fmt == 212
                    f212(og, obsize)
                elseif fmt == 310
                    f310(og, obsize)
                elseif fmt == 311
                    f311(og, obsize)
                end
            end
        end
    end
    for k in 1:min(st.nogroup, length(st.ogd))
        og = st.ogd[k]
        if og.bsize == 0 && og.bp != 0
            og.fp === nothing || fwrite(og.fp, view(og.buf, 1:og.bp))
            og.bp = 0
        end
        fp = og.fp
        if fp !== nothing
            fflush(fp)
            if og.force_flush == 0 && og.nrewind != 0
                # Rewind the file so that subsequent samples will be written
                # in the right place.
                fseek(fp, -Int64(og.nrewind), SEEK_CUR)
                og.nrewind = 0
            end
        end
    end
    nothing
end

"""
    wfdb_oinfoclose([w]) -> Int32

Close the output info file (called by `wfdbquit`).
"""
function wfdb_oinfoclose(w::Wfdb)
    st = w.sig
    stat = Int32(0)
    if st.outinfo == OUTINFO_FILE
        f = st.outinfo_file
        if f !== nothing
            st.outinfo_file = nothing
            errflag = ferror(f)
            fclose(f) != 0 && (errflag = true)
            if errflag
                wfdb_error(w, "setinfo: write error in info file\n")
                stat = Int32(-2)
            end
        end
    end
    st.outinfo_file = nothing
    st.outinfo = OUTINFO_NONE
    stat
end

# The number of values getvec/getframe may store.
function _vec_need(st::SigState)
    max(Int(st.tspf), Int(st.nvsig), st.nisig, st.framelen, 0)
end

# ---------------------------------------------------------------------------
# WFDB library functions: opening signals

const SiginfoArg = Union{Nothing,AbstractVector{Siginfo}}

"""
    isigopen([w], record, siarray, nsig) -> Int32

C `isigopen`: read the header of `record` and open its first `nsig` input
signals, filling the first elements of `siarray` (a vector of
[`Siginfo`](@ref), or `nothing`) with their descriptions. The signals open
before are closed first, unless the record name begins with `+`.

With `nsig <= 0`, the signals are not opened: up to `-nsig` elements of
`siarray` are filled in from the header, and the number of signals in the
header is returned (so `isigopen(record, nothing, 0)` counts the signals).

Returns the number of signals opened (or available, if `nsig <= 0`), or a
negative value on error: -1 if the header cannot be found or read, -2 if it
is invalid, -3 if a signal file cannot be opened.

# Examples
```julia-repl
julia> n = isigopen("100s", nothing, 0)
2

julia> si = [Siginfo() for _ in 1:n];

julia> isigopen("100s", si, n)
2

julia> String(si[1].desc), si[1].gain
("MLII", 200.0)
```
"""
function isigopen(w::Wfdb, record::OptByteStr, siarray::SiginfoArg, nsig::Integer)
    st = w.sig
    rec_arg = record === nothing ? UInt8[] : copy(cstr(bytes(record)))
    nsig = Int32(nsig)
    first_segment = false

    # Close previously opened input signals unless otherwise requested.
    if !isempty(rec_arg) && rec_arg[1] == UInt8('+')
        rec_arg = rec_arg[2:end]
    else
        isigclose(w)
    end

    # Remove trailing .hea, if any, from record name.
    rec = wfdb_striphea(rec_arg)

    # Save the current record name.
    st.in_msrec == 0 && wfdb_setirec(w, rec)

    # Read the header and determine how many signals are available.
    navail = readheader(w, rec)
    if navail <= 0
        if navail == 0 && st.segments != 0
            # this is a multi-segment record
            st.in_msrec = 1
            first_segment = true
            # Open the first segment to get signal information.
            if st.have_segarray && st.segp >= 0
                navail = readheader(w, st.segarray[st.segp+1].recname)
                if navail >= 0
                    st.msbtime == 0 && (st.msbtime = st.btime)
                    st.msbdate == 0 && (st.msbdate = st.bdate)
                end
            end
            nsig <= 0 && (st.in_msrec = 0)
        end
        if navail == 0 && nsig != 0
            wfdb_error(w, "isigopen: record %s has no signals\n", rec)
        end
        navail <= 0 && return navail
    end

    # If nsig <= 0, isigopen fills in up to (-nsig) members of siarray based
    # on the contents of the header, but no signals are actually opened.
    if nsig <= 0
        nsig = -nsig
        navail < nsig && (nsig = navail)
        if siarray !== nothing
            for s in 1:min(Int(nsig), length(siarray))
                siarray[s] = copy(st.hsd[s].info)
            end
        end
        st.in_msrec = 0     # necessary to avoid errors when reopening
        return navail
    end

    # Determine how many new signals we should attempt to open.
    nsig > navail && (nsig = navail)

    # Allocate input signals and signal group workspace.
    while length(st.isd) < st.nisig + nsig
        push!(st.isd, IsData())
    end
    nn = min(st.nigroup + Int(st.hsd[navail].info.group) + 1, st.nigroup + Int(nsig))
    while length(st.igd) < nn
        push!(st.igd, IgData())
    end
    # Set default buffer size (if not set already by setibsize).
    st.ibsize <= 0 && (st.ibsize = WFDB_BUFSIZ)

    # Open the signal files. One signal group is handled per iteration. In
    # this loop, si counts through the entries that have been read from hsd,
    # and s counts the entries that have been added to isd.
    navail_ = Int(navail)
    nsig_ = Int(nsig)
    g = 0
    si = 0
    s = 0
    while si < navail_ && s < nsig_
        # Find out how many signals are in this group.
        sj = si + 1
        while sj < navail_ && st.hsd[sj+1].info.group == st.hsd[si+1].info.group
            sj += 1
        end

        # Skip this group if there are too few slots in the caller's array.
        if sj - si > nsig_ - s
            si = sj
            continue
        end

        gi = st.nigroup + g
        hs = st.hsd[si+1]
        ig = st.igd[gi+1]
        # Set the buffer size and the seek capability flag.
        if hs.info.bsize < 0
            hs.info.bsize = -hs.info.bsize
            ig.bsize = hs.info.bsize
            ig.seek = 0
        else
            ig.bsize = hs.info.bsize
            ig.bsize == 0 && (ig.bsize = st.ibsize)
            ig.seek = 1
        end
        ig.buf = zeros(UInt8, max(Int(ig.bsize), 0))
        ig.flac = nothing
        ig.data = 0
        ig.datb = 0
        ig.count = 0

        # Check that the signal file is readable.
        fmt = hs.info.fmt
        if fmt == 0
            ig.fp = nothing     # Don't open a file for a null signal.
        else
            fname = hs.info.fname === nothing ? UInt8[] : copy(cstr(hs.info.fname))
            # wfdb-x: in the directory of the header
            ig.fp = wfdbx_get_legacy(w) != 0 ? wfdb_open(w, fname, nothing, WFDB_READ) :
                    wfdbx_open_in(w, st.hdr_dir, nothing, fname, rec)
            # Skip this group if the signal file can't be opened.
            if ig.fp === nothing
                ig.buf = UInt8[]
                si = sj
                continue
            end
        end

        if isflacfmt(fmt) && flac_isopen(w, gi, si, sj - si) < 0
            ig.buf = UInt8[]
            _close!(ig.fp)
            ig.fp = nothing
            ig.flac = nothing
            si = sj
            continue
        end

        # All tests passed -- fill in remaining data for this group.
        ig.bp = max(Int(ig.bsize), 0)
        ig.be = ig.bp
        ig.start = hs.start
        ig.initial_skip = ig.start > 0 ? 1 : 0
        ig.stat = 1
        while si < sj && s < nsig_
            is = st.isd[st.nisig+s+1]
            is.info = copy(st.hsd[si+1].info)
            is.info.group = UInt32(st.nigroup + g)
            is.skew = st.hsd[si+1].skew
            s += 1
            si += 1
        end
        si = sj
        g += 1
    end

    # Produce a warning message if none of the requested signals could be
    # opened.
    if s == 0 && nsig != 0
        wfdb_error(w, "isigopen: none of the signals for record %s is readable\n", rec)
    end

    # Check that the total number of samples per frame is less than or equal
    # to INT_MAX.
    spflimit = INT_MAX - (st.framelen % Int32)
    for k in 1:s
        spflimit -= st.isd[st.nisig+k].info.spf
        if spflimit < 0
            wfdb_error(w, "isigopen: total frame size too large in record %s\n", rec)
            isigclose(w)
            return Int32(-3)
        end
    end

    # Copy the WFDB_Siginfo structures to the caller's array. Use these data
    # to construct the initial sample vector, and to determine the maximum
    # number of samples per signal per frame and the maximum skew.
    for k in 1:s
        is = st.isd[st.nisig+k]
        if siarray !== nothing && k <= length(siarray)
            siarray[k] = copy(is.info)
        end
        is.samp = is.info.initval
        st.ispfmax < is.info.spf && (st.ispfmax = is.info.spf)
        st.skewmax < is.skew && (st.skewmax = is.skew)
    end
    st.nisig += s       # Update the count of open input signals.
    st.nigroup += g     # Update the count of open input groups.

    if sigmap_init(w, first_segment) < 0
        isigclose(w)
        return Int32(-3)
    end
    st.spfmax = st.ispfmax
    setgvmode(w, st.gvmode)     # Reset sfreq if appropriate.
    st.gvc = st.ispfmax         # Initialize getvec's counter.

    # Determine the total number of samples per frame.
    st.framelen = 0
    for k in 1:st.nisig
        st.framelen += st.isd[k].info.spf
    end

    # Allocate workspace for getvec, isgsettime, and tnextvec.
    if st.tspf > st.tuvlen
        n = Int(st.tspf)
        st.tvector = zeros(Int32, n)
        st.uvector = zeros(Int32, n)
        st.vvector = zeros(Int32, n)
        st.tuvlen = st.tspf
    end

    # If deskewing is required, allocate the deskewing buffer (unless this
    # is a multi-segment record and dsbuf has been allocated already).
    if st.skewmax != 0 && (st.in_msrec == 0 || !st.have_dsbuf)
        if st.tspf > INT_MAX ÷ (st.skewmax + 1)
            wfdb_error(w, "isigopen: maximum skew too large in record %s\n", rec)
            isigclose(w)
            return Int32(-3)
        end
        st.dsbi = -1    # mark buffer contents as invalid
        st.dsblen = Int(st.tspf) * (st.skewmax + 1)
        st.dsbuf = zeros(Int32, st.dsblen)
        st.have_dsbuf = true
    end
    Int32(s)
end

"""
    osigopen([w], record, siarray, nsig) -> Int32

C `osigopen`: open output signals as described by the header of `record`
(filling `siarray`, a vector of [`Siginfo`](@ref) or `nothing`). Returns
the number of signals opened, or a negative error code.
"""
function osigopen(w::Wfdb, record::OptByteStr, siarray::SiginfoArg, nsig::Integer)
    rec_arg = record === nothing ? UInt8[] : copy(cstr(bytes(record)))
    nsig = Int(nsig % UInt32)
    # Close previously opened output signals unless otherwise requested.
    if !isempty(rec_arg) && rec_arg[1] == UInt8('+')
        rec_arg = rec_arg[2:end]
    else
        osigclose(w)
    end

    # Remove trailing .hea, if any, from record name.
    rec = wfdb_striphea(rec_arg)

    n = readheader(w, rec)
    n < 0 && return n
    if n < nsig
        wfdb_error(w, "osigopen: record %s has fewer signals than needed\n", rec)
        return Int32(-3)
    end
    hsi = Siginfo[copy(w.sig.hsd[k].info) for k in 1:nsig]
    out = (siarray === nothing || isempty(siarray)) ? nothing : siarray
    openosig(w, "osigopen", out, hsi, nsig)
end

"""
    osigfopen([w], siarray, nsig) -> Int32

C `osigfopen`: create and open the output signals described by the first
`nsig` elements of `siarray` (`fname`, `fmt`, `gain`, ... of each). The
signal files are created in the current directory (or in the directory
given in `fname`); output signals open before are closed first. Write the
samples with [`putvec`](@ref) and the header with [`newheader`](@ref).

Returns the number of signals opened, or a negative value on error.
"""
function osigfopen(w::Wfdb, siarray::SiginfoArg, nsig::Integer)
    st = w.sig
    # Close any open output signals.
    stat = osigclose(w)

    # Do nothing further if there are no signals to open.
    (siarray === nothing || isempty(siarray) || nsig == 0) && return stat
    nsig = min(Int(nsig % UInt32), length(siarray))

    st.obsize <= 0 && (st.obsize = WFDB_BUFSIZ)

    # Prescan siarray to check the signal specifications and to determine
    # the number of signal groups.
    for s in 1:nsig
        si = siarray[s]
        f1 = _ostr(si.fname)
        if length(f1) + length(_ostr(si.desc)) > OSIG_NAME_DESC_MAX || si.bsize < 0 || !isfmt(si.fmt)
            wfdb_error(w, "osigfopen: error in specification of signal %d\n", Int32(s - 1))
            return Int32(-2)
        end
        f0 = s > 1 ? _ostr(siarray[s-1].fname) : UInt8[]
        ok = (s == 1 && si.group == 0) ||
             (s > 1 && si.group == siarray[s-1].group && f1 == f0) ||
             (s > 1 && si.group == siarray[s-1].group + UInt32(1) && f1 != f0)
        if !ok
            wfdb_error(w, "osigfopen: incorrect file name or group for signal %d\n", Int32(s - 1))
            return Int32(-2)
        end
    end
    openosig(w, "osigfopen", nothing, siarray, nsig)
end

"""
    findsig([w], p) -> Int32

C `findsig`: the number of the input signal named (or numbered) `p`, or -1.
"""
function findsig(w::Wfdb, p::ByteStr)
    st = w.sig
    p = cstr(bytes(p))
    if all(c_isdigit, p)
        # all digits, probably a signal number
        s = _strtol10(p) % Int32
        ((s % UInt32) < st.nisig || s < st.nvsig) && return s
    end
    # Otherwise, p is either an integer too large to be a signal number or
    # a string containing a non-digit character. Assume it's a signal name.
    if st.need_sigmap != 0
        for s in 1:max(Int(st.nvsig), 0)
            d = st.vsd[s].info.desc
            (d !== nothing && cstr(d) == p) && return Int32(s - 1)
        end
    else
        for s in 1:st.nisig
            d = st.isd[s].info.desc
            (d !== nothing && cstr(d) == p) && return Int32(s - 1)
        end
    end
    Int32(-1)
end

"""
    getspf([w]) -> Int32

C `getspf`: the number of samples per frame returned by `getvec` for each
signal (1 unless in `WFDB_HIGHRES` mode).
"""
function getspf(w::Wfdb)
    st = w.sig
    st.sfreq != st.ffreq ? d2i(st.sfreq / st.ffreq + 0.5) : Int32(1)
end

"""
    setgvmode([w], mode)

C `setgvmode`: set the getvec mode (`WFDB_LOWRES` or `WFDB_HIGHRES`,
optionally with `WFDB_GVPAD`); a negative mode selects the default (from
`WFDBGVMODE`).
"""
function setgvmode(w::Wfdb, mode::Integer)
    mode = mode % Int32
    if mode < 0
        # (re)set to default mode
        p = cgetenv("WFDBGVMODE")
        mode = p === nothing ? DEFWFDBGVMODE : _strtol10(p) % Int32
    end
    st = w.sig
    st.gvmode = mode & (WFDB_HIGHRES | WFDB_GVPAD)
    if (mode & WFDB_HIGHRES) == WFDB_HIGHRES
        st.spfmax == 0 && (st.spfmax = 1)
        st.sfreq = st.ffreq * st.spfmax
    else
        st.sfreq = st.ffreq
    end
    nothing
end

"    getgvmode([w]) -> Int32

C `getgvmode`: the getvec mode (see [`setgvmode`](@ref))."
getgvmode(w::Wfdb) = w.sig.gvmode

"""
    setifreq([w], f) -> Int32

C `setifreq`: make `getvec` return the input signals resampled (by linear
interpolation) at `f` Hz. As in C, this also sets the time resolution of
output annotation files to `f` (see [`setafreq`](@ref)). Returns 0, or -1
if `f` is not positive or no record is open.
"""
function setifreq(w::Wfdb, f::Real)
    st = w.sig
    f = Float64(f)
    g = st.sfreq
    if g <= 0.0
        st.ifreq = 0.0
        if st.nisig > 0 && !st.legacy   # wfdb-x: the frequency is not specified
            wfdb_error(w, "setifreq: sampling frequency is not specified\n")
        else
            wfdb_error(w, "setifreq: no open input record\n")
        end
        return Int32(-1)
    end
    if f > 0.0
        n = max(Int(st.nvsig), st.nisig, Int(st.tspf), 1)
        length(st.gv0) < n && resize!(st.gv0, n)
        length(st.gv1) < n && resize!(st.gv1, n)
        st.ifreq = f
        setafreq(w, f)
        # Euclid's algorithm for the GCD of sfreq and ifreq (in multiples of
        # 0.005 Hz, the maximum tolerable error in the resampling frequency).
        while true
            error = f - g
            (error > 0.005 || error < -0.005) || break
            if f > g
                f -= g
            else
                g -= f
            end
        end
        # f is now the GCD of sfreq and ifreq. Each raw sampling interval is
        # divided into mticks subintervals.
        st.mticks = d2l(st.sfreq / f + 0.5)
        # Each resampled interval is divided into nticks subintervals.
        st.nticks = d2l(st.ifreq / f + 0.5)
        # Raw and resampled intervals begin simultaneously once every mnticks
        # subintervals (an epoch).
        st.mnticks = st.mticks * st.nticks
        # gvtime is the number of subintervals from the beginning of the
        # current epoch to the next sample to be returned by getvec().
        st.gvtime = 0
        _reload_gv!(w)
        return Int32(0)
    end
    st.ifreq = 0.0
    wfdb_error(w, "setifreq: improper frequency %g (must be > 0)\n", f)
    Int32(-1)
end

# rgvstat = rgetvec(gv0); rgvstat = rgetvec(gv1); rgvtime = nticks;
function _reload_gv!(w::Wfdb)
    st = w.sig
    st.rgvstat = rgetvec(w, st.gv0, 0)
    st.rgvstat = rgetvec(w, st.gv1, 0)
    st.rgvtime = st.nticks
    nothing
end

"""
    getifreq([w]) -> Float64

C `getifreq`: the sampling frequency of the samples returned by `getvec`.
"""
getifreq(w::Wfdb) = w.sig.ifreq > 0.0 ? w.sig.ifreq : w.sig.sfreq

# ---------------------------------------------------------------------------
# Reading and writing samples

# Call f(w, v, pos), which may store up to _vec_need values from v[pos+1],
# through a temporary vector if v is too short (copying what fits).
@inline function _call_at(f::F, w::Wfdb, v::Vector{Int32}, pos::Int) where {F}
    need = _vec_need(w.sig)
    pos + need <= length(v) && return f(w, v, pos)
    tmp = zeros(Int32, need)
    r = f(w, tmp, 0)
    copyto!(v, pos + 1, tmp, 1, clamp(length(v) - pos, 0, need))
    r
end
_with_room(f::F, w::Wfdb, v::Vector{Int32}) where {F} = _call_at(f, w, v, 0)

"""
    getvec([w], vector::Vector{Int32}) -> Int32

C `getvec`: read the next sample of each open input signal into
`vector[1:nsig]` (if `vector` is shorter, only the values that fit are
stored). In `WFDB_HIGHRES`
mode, oversampled signals give one sample per call and the others are
repeated; in `WFDB_LOWRES` mode (the default), each call reads a frame and
oversampled signals are averaged (see [`setgvmode`](@ref)). Invalid
samples are `WFDB_INVALID_SAMPLE`.

Returns the number of input signals, 0 or -1 at the end of the record, or
-3 (unexpected end of file or decoding error) or -4 (checksum error).
"""
getvec(w::Wfdb, vector::Vector{Int32}) = _with_room(getvec_at, w, vector)

"`getvec` storing the samples into `vector[off+1:...]` (long enough)."
function getvec_at(w::Wfdb, vector::Vector{Int32}, off::Int)
    st = w.sig
    # no resampling necessary
    (st.ifreq == 0.0 || st.ifreq == st.sfreq) && return rgetvec(w, vector, off)
    # Resample the input.
    if st.rgvtime > st.mnticks
        st.rgvtime -= st.mnticks
        st.gvtime -= st.mnticks
    end
    nsig = max(Int(st.nvsig), st.nisig, 0)
    while st.gvtime > st.rgvtime
        copyto!(st.gv0, 1, st.gv1, 1, nsig)
        st.rgvstat = rgetvec(w, st.gv1, 0)
        st.rgvtime += st.nticks
    end
    frac = st.gvtime % st.nticks
    for i in 1:nsig
        a, b = st.gv0[i], st.gv1[i]
        vector[off+i] = (a + frac * Int64(b - a) ÷ st.nticks) % Int32
        st.gv0[i] = b
    end
    st.gvtime += st.mticks
    st.rgvstat
end

"""
    getframe([w], vector::Vector{Int32}) -> Int32

C `getframe`: read the next frame (all samples of every signal, `spf`
samples of an oversampled signal).
"""
getframe(w::Wfdb, vector::Vector{Int32}) = _with_room(getframe_at, w, vector)

"`getframe` storing the samples into `vector[off+1:...]` (long enough)."
function getframe_at(w::Wfdb, vector::Vector{Int32}, off::Int)
    st = w.sig
    stat = Int32(-1)
    if st.have_dsbuf
        # signals must be deskewed
        ds = st.dsbuf
        tspf = st.tspf
        dsblen = Int32(st.dsblen)
        # First, obtain the samples needed.
        if st.dsbi < 0
            # dsbuf contents are invalid -- refill dsbuf
            i = Int32(0)
            st.dsbi = 0
            while i < dsblen
                stat = getskewedframe(w, ds, Int(i))
                stat < 0 && break
                i += tspf
                st.dsbi = i
            end
            st.dsbi = 0
        else
            # replace oldest frame in dsbuf only
            stat = getskewedframe(w, ds, Int(st.dsbi))
            st.dsbi += tspf
            st.dsbi >= dsblen && (st.dsbi = 0)
        end

        # Assemble the deskewed frame from the data in dsbuf.
        j = 0
        for s in 1:max(Int(st.nvsig), 0)
            i = Int32(j) + st.dsbi + st.vsd[s].skew * tspf
            i >= dsblen && (i %= dsblen)
            for _ in 1:st.vsd[s].info.spf
                vector[off+j+1] = ds[i+1]
                j += 1
                i += Int32(1)
            end
        end
    else
        # no deskewing necessary
        stat = getskewedframe(w, vector, off)
    end
    st.istime += 1
    stat
end

"""
    getvecs([w], out::Vector{Int32}, n) -> Int64

Read up to `n` sample vectors (as `n` calls of `getvec`) into `out`, which
receives `n` times the number of values `getvec` stores (one per signal).
Returns the number of vectors read (`>= 0`), or the negative status of
`getvec` if the first call failed. (An addition to the C library, with a
fast path for the common case.)
"""
getvecs(w::Wfdb, out::Vector{Int32}, n::Integer) = getvecs_status(w, out, n)[1]

# ---------------------------------------------------------------------------
# Bulk frame reading (wfdb-x; a port of the Python implementation's
# _bulk_frames)
#
# _bulk_frames! decodes up to n complete frames at once, straight from the
# input buffers, with one loop per signal (no per-sample dispatch on the
# format). It is exactly equivalent to n consecutive calls of
# getskewedframe in the situations where it is used, and it declines
# (returning fewer frames, possibly none) whenever a frame would require
# special handling: data not in the input buffer (it never reads the file:
# the next frame then goes through getskewedframe, which refills the buffer
# as usual), end of file, a frame at which a checksum is verified, a segment
# boundary, deskewing, resampling, a FLAC or null signal, or a partially
# consumed bit-packed group. The samples, statuses, checksums, sample
# counts, istime and the buffer state are therefore identical.

# (private switch, for the tests: false forces the per-frame path)
const _BULK_ENABLED = Ref(true)

# Bytes and samples per packed unit of the formats read in bulk.
@inline _bulk_unit(fmt::Int32) =
    (fmt == 8 || fmt == 80) ? (1, 1) :
    (fmt == 16 || fmt == 61 || fmt == 160) ? (2, 1) :
    fmt == 24 ? (3, 1) : fmt == 32 ? (4, 1) : fmt == 212 ? (3, 2) :
    (fmt == 310 || fmt == 311) ? (4, 3) : (0, 0)

# The conditions for bulk reading that do not change while frames are read.
function _bulk_static_ok(st::SigState)
    _BULK_ENABLED[] || return false
    nisig = st.nisig
    (nisig == 0 || st.need_sigmap != 0 || st.have_dsbuf || st.nvsig != nisig ||
     st.ispfmax != 1 || st.tspf != nisig || st.framelen != nisig ||
     !(st.ifreq == 0.0 || st.ifreq == st.sfreq)) && return false
    gfmt = fill(Int32(-1), st.nigroup)
    for s in 1:nisig
        info = st.isd[s].info
        (_bulk_unit(info.fmt)[1] == 0 || info.spf != 1) && return false
        # (one format per group)
        g = Int(info.group) + 1
        1 <= g <= st.nigroup || return false
        gfmt[g] == -1 && (gfmt[g] = info.fmt)
        gfmt[g] == info.fmt || return false
    end
    for g in 1:st.nigroup
        ig = st.igd[g]
        (gfmt[g] == -1 || ig.seek != 1 || ig.fp === nothing || ig.flac !== nothing) &&
            return false
    end
    true
end

# Decode the sample at index j (0-based) of a group's stream of format fmt
# starting at buf[b+1] (a whole number of packed units).
@inline function _bulk_sample(fmt::Int32, buf::Vector{UInt8}, b::Int, j::Int)
    @inbounds if fmt == 16
        o = b + 2j
        return Int32(reinterpret(Int16, UInt16(buf[o+1]) | UInt16(buf[o+2]) << 8))
    elseif fmt == 212
        o = b + 3 * (j >> 1)
        v = iseven(j) ? Int32(buf[o+1]) | (Int32(buf[o+2]) & Int32(0x0f)) << 8 :
                        Int32(buf[o+3]) | (Int32(buf[o+2]) & Int32(0xf0)) << 4
        return (v & Int32(0x800)) != 0 ? v | ~Int32(0xfff) : v
    elseif fmt == 8
        return Int32(reinterpret(Int8, buf[b+j+1]))
    elseif fmt == 80
        return Int32(buf[b+j+1]) - Int32(1 << 7)
    elseif fmt == 61
        o = b + 2j
        return Int32(reinterpret(Int16, UInt16(buf[o+1]) << 8 | UInt16(buf[o+2])))
    elseif fmt == 160
        o = b + 2j
        return Int32(UInt16(buf[o+1]) | UInt16(buf[o+2]) << 8) - Int32(1 << 15)
    elseif fmt == 24
        o = b + 3j
        v = UInt32(buf[o+1]) | UInt32(buf[o+2]) << 8 | UInt32(buf[o+3]) << 16
        return reinterpret(Int32, v << 8) >> 8
    elseif fmt == 32
        o = b + 4j
        return reinterpret(Int32, UInt32(buf[o+1]) | UInt32(buf[o+2]) << 8 |
                                  UInt32(buf[o+3]) << 16 | UInt32(buf[o+4]) << 24)
    else    # 310, 311
        t, r = divrem(j, 3)
        o = b + 4t
        w0 = Int32(buf[o+1]) | Int32(buf[o+2]) << 8
        if fmt == 310
            w1 = Int32(buf[o+3]) | Int32(buf[o+4]) << 8
            v = r == 0 ? (w0 >> 1) & Int32(0x3ff) :
                r == 1 ? (w1 >> 1) & Int32(0x3ff) :
                ((w0 & Int32(0xf800)) >> 11) | ((w1 & Int32(0xf800)) >> 6)
        else
            v = r == 0 ? w0 & Int32(0x3ff) :
                r == 1 ? ((w0 & Int32(0xfc00)) >> 10) | ((Int32(buf[o+3]) & Int32(0xf)) << 6) :
                ((Int32(buf[o+3]) | Int32(buf[o+4]) << 8) >> 4) & Int32(0x3ff)
        end
        return (v & Int32(0x200)) != 0 ? v | ~Int32(0x3ff) : v
    end
end

# Decode the samples of signal s (k-th of the nn signals of its group,
# 0-based) of m frames from buf[b+1:...] into out (frame i at
# out[pos+(i-1)*stride+s]), as getskewedframe does (invalid samples, GVPAD,
# format 8 differences, the checksum). A function barrier: fmt is
# dispatched once per signal.
function _bulk_signal!(out::Vector{Int32}, pos::Int, stride::Int, s::Int, is::IsData,
                       buf::Vector{UInt8}, b::Int, k::Int, nn::Int, m::Int, pad::Bool)
    info = is.info
    fmt = info.fmt
    cksum = info.cksum
    samp = is.samp
    o = pos + s
    if fmt == 8
        for i in 0:m-1
            samp += _bulk_sample(fmt, buf, b, i * nn + k)
            @inbounds out[o] = samp
            cksum -= samp
            o += stride
        end
    else
        inval = _invalid_out(fmt)
        for i in 0:m-1
            v = _bulk_sample(fmt, buf, b, i * nn + k)
            if v == inval
                @inbounds out[o] = pad ? samp : WFDB_INVALID_SAMPLE
            else
                samp = v
                @inbounds out[o] = v
            end
            cksum -= v
            o += stride
        end
    end
    is.samp = samp
    info.cksum = cksum
    if info.nsamp > 0
        info.nsamp -= m
    elseif info.nsamp == 0
        info.nsamp = -1
    end
    nothing
end

# Read up to n frames into out (frame i at out[pos+(i-1)*nisig+1:...]); the
# number of frames read (0 if the next frame must go through
# getskewedframe). Requires _bulk_static_ok.
function _bulk_frames!(w::Wfdb, out::Vector{Int32}, pos::Int, n::Int64)
    st = w.sig
    nisig = st.nisig
    isd = st.isd
    igd = st.igd
    # The alignment period (in frames) of the bit-packed groups, and the
    # dynamic conditions.
    period = 1
    for g in 1:st.nigroup
        ig = igd[g]
        (ig.initial_skip != 0 || ig.count != 0 || ig.stat <= 0) && return Int64(0)
    end
    nn = zeros(Int, st.nigroup)
    for s in 1:nisig
        nn[Int(isd[s].info.group)+1] += 1
    end
    for s in 1:nisig
        info = isd[s].info
        g = Int(info.group) + 1
        ns = _bulk_unit(info.fmt)[2]
        if ns > 1 && nn[g] % ns != 0
            period = lcm(period, ns)
        end
        # Do not include a frame at which a checksum would be verified.
        ns_ = info.nsamp
        ns_ > 0 && n >= ns_ && (n = ns_ - 1)
    end
    # Only the data in the input buffers (whole periods).
    for s in 1:nisig
        info = isd[s].info
        g = Int(info.group) + 1
        nb, ns = _bulk_unit(info.fmt)
        ig = igd[g]
        unit = period * nn[g] * nb ÷ ns
        avail = ((ig.be - ig.bp) ÷ unit) * period
        avail < n && (n = avail)
    end
    n -= n % period
    n <= 0 && return Int64(0)
    m = Int(n)
    if st.istime == 0
        for s in 1:nisig
            isd[s].samp = isd[s].info.initval
        end
    end
    pad = (st.gvmode & WFDB_GVPAD) != 0
    kk = zeros(Int, st.nigroup)
    for s in 1:nisig
        info = isd[s].info
        g = Int(info.group) + 1
        ig = igd[g]
        _bulk_signal!(out, pos, nisig, s, isd[s], ig.buf, ig.bp, kk[g], nn[g], m, pad)
        kk[g] += 1
    end
    # Consume the bytes, leaving the group state as the per-sample readers
    # would (data, datb: the last packed unit).
    done = falses(st.nigroup)
    for s in 1:nisig
        fmt = isd[s].info.fmt
        g = Int(isd[s].info.group) + 1
        done[g] && continue
        done[g] = true
        ig = igd[g]
        nb, ns = _bulk_unit(fmt)
        used = m * nn[g] * nb ÷ ns
        ig.bp += used
        buf = ig.buf
        o = ig.bp - nb      # the last unit
        @inbounds if fmt == 212
            ig.data = Int32(reinterpret(Int16, UInt16(buf[o+1]) | UInt16(buf[o+2]) << 8))
        elseif fmt == 310
            ig.data = Int32(reinterpret(Int16, UInt16(buf[o+1]) | UInt16(buf[o+2]) << 8))
            ig.datb = Int32(reinterpret(Int16, UInt16(buf[o+3]) | UInt16(buf[o+4]) << 8))
        elseif fmt == 311
            ig.data = Int32(reinterpret(Int16, UInt16(buf[o+1]) | UInt16(buf[o+2]) << 8))
            ig.datb = (Int32(buf[o+3]) & Int32(0xff)) | Int32(reinterpret(Int8, buf[o+4])) << 8
        end
    end
    st.istime += m
    Int64(m)
end

"""
    getvecs_status([w], out::Vector{Int32}, n) -> (Int64, Int32)

As [`getvecs`](@ref), also returning the value returned by the last
`getvec` call: the negative status of the first vector that could not be
read (-1 at the end of the data, `< -1` on an error, e.g. -3 for an
unexpected end of file), or the number of values per vector if all `n` were
read (0 if `n <= 0`). (An addition to the C library.) With
`keep_checksum_frame=true` (wfdb-x, for the high-level reader), the vector
for which `getvec` returns -4 (a checksum error: it was read completely, it
is the last one of the record) is included in the count and in `out`.
"""
function getvecs_status(w::Wfdb, out::Vector{Int32}, n::Integer; keep_checksum_frame::Bool=false)
    _getvecs_into(w, out, 0, Int64(n), keep_checksum_frame)
end

# getvecs_status storing the vectors from out[off+1] (wfdb-x: the
# high-level reader reads into its output buffer directly).
function _getvecs_into(w::Wfdb, out::Vector{Int32}, off::Int, n::Int64, keep_checksum_frame::Bool)
    n <= 0 && return (Int64(0), Int32(0))
    st = w.sig
    stat = Int32(0)
    k = Int64(0)
    if !st.have_dsbuf && st.ispfmax < 2 && (st.ifreq == 0.0 || st.ifreq == st.sfreq)
        # Fast path: getvec is getframe, which is getskewedframe.
        stride = max(Int(st.tspf), 0)
        need = _vec_need(st)
        pos = off
        bulk = _bulk_static_ok(st)
        seg = st.segp
        while k < n
            if st.segp != seg       # (another segment: other signals)
                seg = st.segp
                bulk = _bulk_static_ok(st)
            end
            if bulk
                # wfdb-x: as many frames as possible in bulk (identical
                # results), the others one by one
                room = Int64((length(out) - pos) ÷ max(stride, 1))
                m = _bulk_frames!(w, out, pos, min(n - k, room))
                if m > 0
                    k += m
                    pos += Int(m) * stride
                    stat = Int32(st.nisig)     # (as getskewedframe returns)
                    continue
                end
            end
            if pos + need > length(out)
                # (the caller's array is too short for another vector)
                tmp = zeros(Int32, need)
                stat = getskewedframe(w, tmp, 0)
                st.istime += 1
                keep = stat == -4 && keep_checksum_frame
                stat < 0 && !keep && break
                m = min(max(length(out) - pos, 0), stride)
                copyto!(out, pos + 1, tmp, 1, m)
                k += 1
                (keep || m < stride) && break
                pos += stride
                continue
            end
            stat = getskewedframe(w, out, pos)
            st.istime += 1
            if stat < 0
                # wfdb-x: the frame of a checksum error is complete
                (stat == -4 && keep_checksum_frame) && (k += 1)
                break
            end
            pos += stride
            k += 1
        end
    else
        # getvec returns one sample per signal
        stride = max(Int(st.nvsig), 0)
        if st.ifreq != 0.0 && st.ifreq != st.sfreq && st.nisig > st.nvsig
            stride = st.nisig
        end
        pos = off
        while k < n
            pos + stride > length(out) && break
            stat = _call_at(getvec_at, w, out, pos)
            if stat < 0
                (stat == -4 && keep_checksum_frame) && (k += 1)
                break
            end
            pos += stride
            k += 1
        end
    end
    ((k == 0 && stat < 0) ? Int64(stat) : k, Int32(stat))
end

# The value written for an invalid sample (the lowest of the format).
function _invalid_out(fmt::Int32)
    (fmt == 80 || fmt == 508) ? INVALID_8 :
    fmt == 212 ? INVALID_12 :
    (fmt == 310 || fmt == 311) ? INVALID_10 :
    (fmt == 24 || fmt == 524) ? INVALID_24 :
    fmt == 32 ? INVALID_32 : INVALID_16
end

"""
    putvec([w], vector) -> Int32

C `putvec`: write a sample to each open output signal, taking `spf`
consecutive values of `vector` for an oversampled signal (one frame in all).

Returns the number of output signals, 0 if a sample difference had to be
clipped (format 8), or -1 on a write error.
"""
function putvec(w::Wfdb, vector::AbstractVector{Int32})
    st = w.sig
    stat = Int32(st.nosig)
    obsize = st.obsize
    vi = 0
    errs = nothing
    for s in 1:st.nosig
        os = st.osd[s]
        info = os.info
        og = st.ogd[Int(info.group)+1]
        if info.nsamp == 0
            info.initval = vector[vi+1]
            os.samp = vector[vi+1]
        end
        info.nsamp += 1
        fmt = info.fmt
        for _ in 1:info.spf
            # Replace invalid samples with lowest possible value for format.
            samp = vector[vi+1]
            samp == WFDB_INVALID_SAMPLE && (samp = _invalid_out(fmt))
            if fmt == 16
                w16(og, samp, obsize)
                os.samp = samp
            elseif fmt == 212
                w212(og, samp, obsize)
                os.samp = samp
            elseif fmt == 0
                os.samp = samp      # null signal (do not write)
            elseif fmt == 61
                w61(og, samp, obsize)
                os.samp = samp
            elseif fmt == 80
                w80(og, samp, obsize)
                os.samp = samp
            elseif fmt == 160
                w160(og, samp, obsize)
                os.samp = samp
            elseif fmt == 310
                w310(og, samp, obsize)
                os.samp = samp
            elseif fmt == 311
                w311(og, samp, obsize)
                os.samp = samp
            elseif fmt == 24
                w24(og, samp, obsize)
                os.samp = samp
            elseif fmt == 32
                w32(og, samp, obsize)
                os.samp = samp
            elseif fmt == 508 || fmt == 516 || fmt == 524
                flac_putsamp(og, samp, fmt) < 0 && (stat = Int32(-1))
                os.samp = samp
            else
                # 8-bit first differences; handle large slew rates sensibly.
                dif = samp - os.samp
                if dif < -128
                    dif = Int32(-128)
                    stat = Int32(0)
                elseif dif > 127
                    dif = Int32(127)
                    stat = Int32(0)
                end
                os.samp += dif
                w8(og, dif, obsize)
            end
            if og.fp !== nothing && ferror(og.fp)
                errs === nothing && (errs = Int32[])
                push!(errs, Int32(s - 1))
                stat = Int32(-1)
            else
                info.cksum += os.samp
            end
            vi += 1
        end
    end
    st.ostime += 1
    if errs !== nothing
        for s in errs
            wfdb_error(w, "putvec: write error in signal %d\n", s)
        end
    end
    stat
end

"""
    isigsettime([w], t) -> Int32

C `isigsettime`: make sample `t` (a sample number of the open record) the
next one read by `getvec` from every input signal. Returns 0, or a negative
value if the position cannot be reached (e.g. it is beyond the end of the
record).
"""
function isigsettime(w::Wfdb, t::Integer)
    st = w.sig
    t = Int64(t)
    # Return immediately if no seek is needed.
    st.nisig == 0 && return Int32(0)
    if st.ifreq <= 0.0
        curtime = ((st.gvmode & WFDB_HIGHRES) == 0 || st.ispfmax < 2) ? st.istime :
                  (st.istime - 1) * st.ispfmax + st.gvc
        t == curtime && return Int32(0)
    end
    stat = Int32(0)
    g = 1
    while g < st.nigroup
        stat = isgsettime(w, g, t)
        stat < 0 && break
        g += 1
    end
    # Seek on signal group 0 last (since doing so updates istime and would
    # confuse isgsettime if done first).
    stat == 0 && (stat = isgsettime(w, 0, t))
    stat
end

"""
    isgsettime([w], g, t) -> Int32

C `isgsettime`: skip to sample `t` in signal group `g`.
"""
function isgsettime(w::Wfdb, g::Integer, t::Integer)
    st = w.sig
    g = Int(g % UInt32)
    t = Int64(t)
    trem = Int32(0)
    # Handle negative arguments as equivalent positive arguments.
    if t < 0
        t < -WFDB_TIME_MAX && return seekerr(w, g)
        t = -t
    end

    # Convert t to raw sample intervals if we are resampling.
    if st.ifreq > 0.0
        tt = t * st.sfreq / st.ifreq
        tt > Float64(WFDB_TIME_MAX) && return seekerr(w, g)
        t = d2l(tt)
    end

    # If we're in WFDB_HIGHRES mode, convert t from samples to frames, and
    # save the remainder (if any) in trem.
    if st.gvmode & WFDB_HIGHRES != 0
        m = max(Int64(st.ispfmax), 1)
        trem = (t % m) % Int32
        t ÷= m
    end

    # Mark the contents of the deskewing buffer (if any) as invalid.
    st.dsbi = -1

    stat = isgsetframe(w, g, t)
    if stat == 0 && g == 0
        while trem > 0
            trem -= Int32(1)
            need = _vec_need(st)
            length(st.uvector) < need && resize!(st.uvector, need)
            rgetvec(w, st.uvector, 0) < 0 && return seekerr(w, g)
        end
        if st.ifreq > 0.0 && st.ifreq != st.sfreq
            st.gvtime = 0
            _reload_gv!(w)
        end
    end
    stat
end

"""
    tnextvec([w], s, t) -> Int64

C `tnextvec`: the time of the next valid sample of signal `s` at or after
`t` (or a negative value).
"""
function tnextvec(w::Wfdb, s::Integer, t::Integer)
    st = w.sig
    s = s % UInt32
    t = Int64(t)
    stat = Int32(0)
    vv = zeros(Int32, max(_vec_need(st), 1))

    if st.in_msrec != 0 && st.need_sigmap != 0
        # variable-layout multi-segment record
        if s >= max(st.nvsig, 0) % UInt32
            wfdb_error(w, "nextvect: illegal signal number %d\n", s)
            return Int64(-1)
        end
        # Go to the start (t) if not already there.
        (t != st.istime && isigsettime(w, t) < 0) && return Int64(-1)
        while stat >= 0
            p = _ostr(st.vsd[s+1].info.desc)
            seg = st.segarray[st.segp+1]
            tf = seg.samp0 + seg.nsamp
            # Check if signal s is available in the current segment.
            found = false
            for k in 1:st.nisig
                d = st.isd[k].info.desc
                if d !== nothing && cstr(d) == p
                    found = true
                    break
                end
            end
            if found
                # The current segment contains the desired signal. Read
                # samples until we find a valid one or reach the end of the
                # segment.
                while t <= tf
                    need = _vec_need(st)
                    length(vv) < need && resize!(vv, need)
                    stat = getvec(w, vv)
                    stat <= 0 && break
                    if vv[s+1] != WFDB_INVALID_SAMPLE
                        isigsettime(w, t)
                        return t
                    end
                    t += 1
                end
                stat < 0 && return Int64(-1)
            end
            # Go on to the next segment.
            if t != tf
                t = tf
                stat = isigsettime(w, t)
            end
        end
    else
        # single-segment or fixed-layout multi-segment record
        # Go to the start (t) if not already there.
        (t != st.istime && isigsettime(w, t) < 0) && return Int64(-1)
        if s >= st.nisig
            wfdb_error(w, "nextvect: illegal signal number %d\n", s)
            return Int64(-1)
        end
        while true
            need = _vec_need(st)
            length(vv) < need && resize!(vv, need)
            stat = getvec(w, vv)
            stat <= 0 && break
            # Read samples until we find a valid one or reach the end of the
            # record.
            if vv[s+1] != WFDB_INVALID_SAMPLE
                isigsettime(w, t)
                return t
            end
            t += 1
        end
    end
    # Error or end of record without finding another sample of signal s.
    Int64(stat)
end

"""
    setibsize([w], n) -> Int32

C `setibsize`: set the default input buffer size.
"""
function setibsize(w::Wfdb, n::Integer)
    n = n % Int32
    if w.sig.nisig != 0
        wfdb_error(w, "setibsize: can't change buffer size after isigopen\n")
        return Int32(-1)
    end
    if n < 0
        wfdb_error(w, "setibsize: illegal buffer size %d\n", n)
        return Int32(-2)
    end
    n == 0 && (n = WFDB_BUFSIZ)
    w.sig.ibsize = n
    n
end

"""
    setobsize([w], n) -> Int32

C `setobsize`: set the default output buffer size.
"""
function setobsize(w::Wfdb, n::Integer)
    n = n % Int32
    if w.sig.nosig != 0
        wfdb_error(w, "setobsize: can't change buffer size after osig[f]open\n")
        return Int32(-1)
    end
    if n < 0
        wfdb_error(w, "setobsize: illegal buffer size %d\n", n)
        return Int32(-2)
    end
    n == 0 && (n = WFDB_BUFSIZ)
    w.sig.obsize = n
    n
end

# ---------------------------------------------------------------------------
# Writing headers

"""
    newheader([w], record) -> Int32

C `newheader`: write the header file `RECORD.hea` (in the current
directory) for the open output signals, with the sampling frequency, base
time and the number of samples written so far. Returns 0, or a negative
value on error.
"""
function newheader(w::Wfdb, record::ByteStr)
    rec = wfdb_striphea(record)
    st = w.sig
    osi = Siginfo[copy(st.osd[k].info) for k in 1:st.nosig]
    setheader(w, rec, osi, st.nosig)
end

"""
    setheader([w], record, siarray, nsig) -> Int32

C `setheader`: write a header file. As in C, the `units` and `desc`
strings of `siarray` are truncated at their first space or line ending (C
applies `strtok` to them).
"""
function setheader(w::Wfdb, record::ByteStr, siarray::AbstractVector{Siginfo}, nsig::Integer)
    st = w.sig
    # If another output header file was opened, close it.
    if st.oheader !== nothing
        fclose(st.oheader)
        st.oheader = nothing
        st.outinfo == OUTINFO_HEADER && (st.outinfo = OUTINFO_NONE)
    end

    # Remove trailing .hea, if any, from record name.
    rec = wfdb_striphea(record)

    # Quit (with message from wfdb_checkname) if name is illegal.
    wfdb_checkname(w, rec, "record") != 0 && return Int32(-1)

    # Try to create the header file.
    f = wfdb_open(w, "hea", rec, WFDB_WRITE)
    if f === nothing
        wfdb_error(w, "newheader: can't create header for record %s\n", rec)
        return Int32(-1)
    end
    st.oheader = f
    nsig = min(Int(nsig % UInt32), length(siarray))

    # Write the general information line.
    out = cformat("%s %d %.12g", rec, Int32(nsig), st.ffreq)
    if (st.cfreq > 0.0 && st.cfreq != st.ffreq) || st.bcount != 0.0
        sprintf!(out, "/%.12g", st.cfreq)
        st.bcount != 0.0 && sprintf!(out, "(%.12g)", st.bcount)
    end
    sprintf!(out, " %ld", nsig > 0 ? siarray[1].nsamp : Int64(0))
    if st.btime != 0 || st.bdate != 0
        if st.btime == 0
            append!(out, b" 0:00")
        elseif st.btime % 1000 == 0
            push!(out, UInt8(' '))
            append!(out, _ftimstr(w, st.btime, 1000.0))
        else
            push!(out, UInt8(' '))
            append!(out, _fmstimstr(w, st.btime, 1000.0))
        end
    end
    st.bdate != 0 && append!(out, _datstr!(w, st.bdate))
    append!(out, b"\r\n")

    # Write a signal specification line for each signal.
    for s in 1:nsig
        si = siarray[s]
        sprintf!(out, "%s %d", si.fname, si.fmt)
        si.spf > 1 && sprintf!(out, "x%d", si.spf)
        if s <= length(st.osd) && st.osd[s].skew != 0
            sprintf!(out, ":%d", st.osd[s].skew * si.spf)
        end
        gstart = (s <= length(st.osd) && st.osd[s].info.group < length(st.ogd)) ?
                 st.ogd[Int(st.osd[s].info.group)+1].start : Int64(0)
        if gstart != 0
            sprintf!(out, "+%ld", gstart)
        elseif st.prolog_bytes != 0
            sprintf!(out, "+%ld", st.prolog_bytes)
        end
        sprintf!(out, " %.12g", si.gain)
        si.baseline != si.adczero && sprintf!(out, "(%d)", si.baseline)
        if si.units !== nothing
            p = _strtok_inplace!(si.units, _HSEP)
            if p !== nothing
                push!(out, UInt8('/'))
                append!(out, p)
            end
        end
        sprintf!(out, " %d %d %d %d %d", si.adcres, si.adczero, si.initval,
                 Int32(si.cksum % Int16), si.bsize)
        if si.desc !== nothing
            p = _strtok_inplace!(si.desc, b"\n\r")
            if p !== nothing
                push!(out, UInt8(' '))
                append!(out, p)
            end
        end
        append!(out, b"\r\n")
    end
    fwrite(f, out)
    fflush(f)
    st.prolog_bytes = 0
    Int32(0)
end

"""
    getseginfo([w], sarray::Ref) -> Int32

C `getseginfo`: the number of segments of the open multi-segment record (0
if it is not one); `sarray[]` receives a copy of the segment table
(`nothing` if there is none).
"""
function getseginfo(w::Wfdb, sarray::Ref)
    st = w.sig
    sarray[] = st.have_segarray ? Seginfo[copy(x) for x in st.segarray] : nothing
    st.segments
end

"""
    setmsheader([w], record, segment_names, nsegments) -> Int32

C `setmsheader`: write the header of a multi-segment record.
"""
function setmsheader(w::Wfdb, record::ByteStr, segment_name::AbstractVector, nsegments::Integer)
    st = w.sig
    old_in_msrec = st.in_msrec
    msfreq, mscfreq, msbcount = 0.0, 0.0, 0.0
    nsig = Int32(0)

    isigclose(w)    # close any open input signals

    # If another output header file was opened, close it.
    if st.oheader !== nothing
        fclose(st.oheader)
        st.oheader = nothing
        st.outinfo == OUTINFO_HEADER && (st.outinfo = OUTINFO_NONE)
    end

    # Remove trailing .hea, if any, from record name.
    rec = wfdb_striphea(record)

    # Quit (with message from wfdb_checkname) if name is illegal.
    wfdb_checkname(w, rec, "record") != 0 && return Int32(-1)

    if nsegments < 1
        wfdb_error(w, "setmsheader: record must contain at least one segment\n")
        return Int32(-1)
    end
    nseg = min(Int(nsegments % UInt32), length(segment_name))

    ns = zeros(Int64, nseg)
    for i in 1:nseg
        name = copy(cstr(bytes(segment_name[i])))
        if length(name) > WFDB_MAXRNL
            wfdb_error(w, "setmsheader: `%s' is too long for a segment name in record %s\n", name, rec)
            return Int32(-2)
        end
        st.in_msrec = 1
        st.nsamples = 0
        st.user_segments = true     # wfdb-x: names given by the caller
        n = readheader(w, name)
        st.user_segments = false
        st.in_msrec = old_in_msrec
        if n < 0
            wfdb_error(w, "setmsheader: can't read segment %s header\n", name)
            return Int32(-3)
        end
        ns[i] = st.nsamples
        if ns[i] <= 0
            wfdb_error(w, "setmsheader: length of segment %s must be specified\n", name)
            return Int32(-4)
        end
        if i == 1
            nsig = n
            msfreq = st.ffreq
            mscfreq = st.cfreq
            msbcount = st.bcount
            st.msbtime = st.btime
            st.msbdate = st.bdate
            st.msnsamples = ns[i]
        else
            if nsig != n
                wfdb_error(w, "setmsheader: incorrect number of signals in segment %s\n", name)
                return Int32(-4)
            end
            if msfreq != st.ffreq
                wfdb_error(w, "setmsheader: incorrect sampling frequency in segment %s\n", name)
                return Int32(-4)
            end
            st.msnsamples += ns[i]
        end
    end

    # Try to create the header file.
    f = wfdb_open(w, "hea", rec, WFDB_WRITE)
    if f === nothing
        wfdb_error(w, "setmsheader: can't create header file for record %s\n", rec)
        return Int32(-1)
    end
    st.oheader = f

    # Write the first line of the master header.
    out = cformat("%s/%u %d %.12g", rec, UInt32(nseg), nsig, msfreq)
    if (mscfreq > 0.0 && mscfreq != msfreq) || msbcount != 0.0
        sprintf!(out, "/%.12g", mscfreq)
        msbcount != 0.0 && sprintf!(out, "(%.12g)", msbcount)
    end
    sprintf!(out, " %lld", st.msnsamples)
    if st.msbtime != 0 || st.msbdate != 0
        push!(out, UInt8(' '))
        append!(out, st.msbtime % 1000 == 0 ? _ftimstr(w, st.msbtime, 1000.0) :
                     _fmstimstr(w, st.msbtime, 1000.0))
    end
    st.msbdate != 0 && append!(out, _datstr!(w, st.msbdate))
    append!(out, b"\r\n")

    # Write a line for each segment.
    for i in 1:nseg
        sprintf!(out, "%s %lld\r\n", cstr(bytes(segment_name[i])), ns[i])
    end
    fwrite(f, out)
    Int32(0)
end

# ---------------------------------------------------------------------------
# Skew, start and prolog

"""
    wfdbgetskew([w], s) -> Int32

C `wfdbgetskew`: the skew (in frames) of input signal `s`.
"""
function wfdbgetskew(w::Wfdb, s::Integer)
    st = w.sig
    s = s % UInt32
    s < max(st.nvsig, 0) % UInt32 ? st.vsd[s+1].skew : Int32(0)
end

"""
    wfdbsetiskew([w], s, skew)

C `wfdbsetiskew`: set the skew of input signal `s` (use with care: only to
restore skews reset as a side effect of, e.g., `sampfreq`).
"""
function wfdbsetiskew(w::Wfdb, s::Integer, skew::Integer)
    st = w.sig
    s = s % UInt32
    skew = skew % Int32
    if s < max(st.nvsig, 0) % UInt32 && skew >= 0 && st.tspf != 0 && skew < st.dsblen ÷ st.tspf
        st.vsd[s+1].skew = skew
    end
    nothing
end

"""
    wfdbsetskew([w], s, skew)

C `wfdbsetskew`: set the skew to be written by `setheader` for output
signal `s`.
"""
function wfdbsetskew(w::Wfdb, s::Integer, skew::Integer)
    st = w.sig
    s = s % UInt32
    s < st.nosig && (st.osd[s+1].skew = skew % Int32)
    nothing
end

"""
    wfdbgetstart([w], s) -> Int64

C `wfdbgetstart`: the byte offset of sample 0 in the signal file of input
signal `s`.
"""
function wfdbgetstart(w::Wfdb, s::Integer)
    st = w.sig
    s = s % UInt32
    if s < st.nisig && s < length(st.vsd) && st.vsd[s+1].info.group < length(st.igd)
        st.igd[Int(st.vsd[s+1].info.group)+1].start
    elseif s == 0 && !isempty(st.hsd)
        st.hsd[1].start
    else
        Int64(0)
    end
end

"""
    wfdbsetstart([w], s, bytes)

C `wfdbsetstart`: set the byte offset to be written by `setheader` for
output signal `s`.
"""
function wfdbsetstart(w::Wfdb, s::Integer, nbytes::Integer)
    st = w.sig
    s = s % UInt32
    if s < st.nosig
        g = Int(st.osd[s+1].info.group)
        g < length(st.ogd) && (st.ogd[g+1].start = nbytes)
    end
    st.prolog_bytes = nbytes
    nothing
end

"""
    wfdbputprolog([w], buf, size, s) -> Int32

C `wfdbputprolog`: write `size` bytes of `buf` (a prolog) to the signal
file of output signal `s`.
"""
function wfdbputprolog(w::Wfdb, buf::ByteStr, size::Integer, s::Integer)
    st = w.sig
    b = bytes(buf)
    size = Int64(size)
    s = s % UInt32
    n = Int64(0)
    if s < st.nosig
        g = Int(st.osd[s+1].info.group)
        if g < length(st.ogd) && st.ogd[g+1].fp !== nothing
            k = min(max(size, 0), length(b))
            n = fwrite(st.ogd[g+1].fp, view(b, 1:k))
        end
    end
    wfdbsetstart(w, s, n)
    n != size && wfdb_error(w, "wfdbputprolog: only %ld of %ld bytes written\n", n, size)
    n == size ? Int32(0) : Int32(-1)
end

# ---------------------------------------------------------------------------
# Info strings

"""
    setinfo([w], record) -> Int32

C `setinfo`: create a `.info` file for `record` (or open it for
appending), to which `putinfo` writes; `nothing` closes it.
"""
function setinfo(w::Wfdb, record::OptByteStr)
    # Close any previously opened output info file.
    stat = wfdb_oinfoclose(w)

    # Quit unless a record name has been specified.
    record === nothing && return stat

    # Remove trailing .hea, if any, from record name.
    rec = wfdb_striphea(record)

    # Quit (with message from wfdb_checkname) if name is illegal.
    wfdb_checkname(w, rec, "record") != 0 && return Int32(-1)

    # Try to create the .info file.
    f = wfdb_open(w, "info", rec, WFDB_APPEND)
    if f === nothing
        wfdb_error(w, "setinfo: can't create info file for record %s\n", rec)
        return Int32(-1)
    end
    w.sig.outinfo_file = f
    w.sig.outinfo = OUTINFO_FILE
    Int32(0)
end

"""
    putinfo([w], s) -> Int32

C `putinfo`: write an info string to the open output `.hea` or `.info`
file.
"""
function putinfo(w::Wfdb, s::ByteStr)
    st = w.sig
    if st.outinfo == OUTINFO_NONE
        if st.oheader !== nothing
            st.outinfo = OUTINFO_HEADER
        else
            wfdb_error(w, "putinfo: caller has not specified a record name\n")
            return Int32(-1)
        end
    end
    f = st.outinfo == OUTINFO_HEADER ? st.oheader : st.outinfo_file
    if f !== nothing
        line = UInt8[UInt8('#')]
        append!(line, cstr(bytes(s)))
        append!(line, b"\r\n")
        fwrite(f, line)
        fflush(f)
    end
    Int32(0)
end

# Save an info string: the line after its initial '#', without its line
# ending, up to its first null character.
function _save_info!(st::SigState, b::Vector{UInt8})
    l = cstr(b)
    n = length(l)
    (n > 0 && l[n] == UInt8('\n')) && (n -= 1)
    (n > 0 && l[n] == UInt8('\r')) && (n -= 1)
    push!(st.pinfo, n >= 2 ? l[2:n] : UInt8[])
    st.ninfo += Int32(1)
    nothing
end

"""
    getinfo([w], record) -> Union{Vector{UInt8},Nothing}

C `getinfo`: on the first call (or with a record name), read the info
strings of the record (from its header and `.info` file) and return the
first; with `nothing`, return the next one. `nothing` when there are no
more.
"""
function getinfo(w::Wfdb, record::OptByteStr)
    st = w.sig
    rec = record === nothing ? nothing : copy(cstr(bytes(record)))
    rec === nothing || wfdb_freeinfo(w)

    if !st.have_pinfo
        # info for record has not yet been read
        if rec === nothing
            rec = wfdb_getirec(w)
            if rec === nothing
                wfdb_error(w, "getinfo: caller did not specify record name\n")
                return nothing
            end
        end
        recbuf = rec::Vector{UInt8}

        if st.ninfo != 0
            wfdb_freeinfo(w)
            st.ninfo = 0
        end
        st.info_i = 0
        st.have_pinfo = true
        st.pinfo = Vector{UInt8}[]

        # Read info from the .hea file, if available (skip for EDF files).
        if st.isedf == 0
            recbuf = wfdb_striphea(recbuf)
            ifile = wfdb_open(w, "hea", recbuf, WFDB_READ)
            if ifile !== nothing
                # As with wfdb_getline(), the buffer keeps its previous
                # contents when the end of the file is reached.
                buf = UInt8[]
                line = UInt8[]
                while getline!(ifile, line) > 0
                    buf = copy(line)
                    buf[1] != UInt8('#') && break     # skip initial comments
                end
                while getline!(ifile, line) > 0
                    buf = copy(line)
                    buf[1] == UInt8('#') && break     # skip header content
                end
                while !isempty(buf) && buf[1] != 0x00
                    # read and save info
                    buf[1] == UInt8('#') && _save_info!(st, buf)
                    getline!(ifile, line) == 0 && break
                    buf = copy(line)
                end
                fclose(ifile)
            end
        end
        # Read more info from the .info file, if available.
        ifile = wfdb_open(w, "info", recbuf, WFDB_READ)
        if ifile !== nothing
            buf = UInt8[]
            while getline!(ifile, buf) > 0
                buf[1] == UInt8('#') && _save_info!(st, buf)
            end
            fclose(ifile)
        end
    end
    if st.info_i < st.ninfo
        st.info_i += Int32(1)
        return copy(st.pinfo[st.info_i])
    end
    nothing
end

"""
    wfdb_freeinfo([w])

C `wfdb_freeinfo`: release the info strings.
"""
function wfdb_freeinfo(w::Wfdb)
    st = w.sig
    st.pinfo = Vector{UInt8}[]
    st.have_pinfo = false
    st.ninfo = 0
    nothing
end

# ---------------------------------------------------------------------------
# Frequencies, times and dates

"""
    sampfreq([w], record) -> Float64

C `sampfreq`: the sampling frequency of `record` (reading its header), or
of the open record if `record` is `nothing`; a negative value if the
header cannot be read.
"""
function sampfreq(w::Wfdb, record::OptByteStr)
    if record !== nothing
        # Remove trailing .hea, if any, from record name.
        rec = wfdb_striphea(record)
        # Save the current record name.
        wfdb_setirec(w, rec)
        # Don't require the sampling frequency of this record to match that
        # of the previously opened record, if any.
        setsampfreq(w, 0.0)
        # readheader sets sfreq if successful.
        n = readheader(w, rec)
        n < 0 && return Float64(n)  # error message will come from readheader
    end
    w.sig.sfreq
end

"""
    setsampfreq([w], freq) -> Int32

C `setsampfreq`: set the sampling frequency.
"""
function setsampfreq(w::Wfdb, freq::Real)
    freq = Float64(freq)
    if freq >= 0.0
        st = w.sig
        st.sfreq = freq
        st.ffreq = freq
        st.spfmax == 0 && (st.spfmax = 1)
        (st.gvmode & WFDB_HIGHRES) == WFDB_HIGHRES && (st.sfreq *= st.spfmax)
        return Int32(0)
    end
    wfdb_error(w, "setsampfreq: sampling frequency must not be negative\n")
    Int32(-1)
end

"""
    setbasetime([w], string) -> Int32

C `setbasetime`: set the base time and date of the record (`nothing` or
empty: the current local time).
"""
function setbasetime(w::Wfdb, string::OptByteStr)
    st = w.sig
    st.pdays = -1
    s = string === nothing ? UInt8[] : cstr(bytes(string))
    if isempty(s)
        tm = Libc.TmStruct(time())     # C localtime(time(NULL))
        ds = cformat("%02d/%02d/%d", tm.mday, tm.month + 1, tm.year + 1900)
        st.bdate = strdat(w, ds)
        st.date_string = ds
        st.btime = fstrtim(w, cformat("%d:%d:%d", tm.hour, tm.min, tm.sec), 1000.0)
        return Int32(0)
    end
    k = 1
    while k <= length(s) && s[k] == UInt8(' ')
        k += 1
    end
    str = s[k:end]
    p = findfirst(==(UInt8(' ')), str)
    tpart = p === nothing ? str : str[1:p-1]
    st.btime = fstrtim(w, tpart, 1000.0)
    st.bdate = p === nothing ? Int64(0) : strdat(w, view(str, p+1:length(str)))
    if st.btime == 0 && st.bdate == 0 && !(!isempty(str) && str[1] == UInt8('['))
        wfdb_error(w, "setbasetime: incorrect time format, '%s'\n", str)
        return Int32(-1)
    end
    Int32(0)
end

# Convert a sample number to a string, using the given sampling frequency
# (C ftimstr).
function _ftimstr(w::Wfdb, t::Int64, f::Float64)
    ts = _fmstimstr(w, t, f)
    p = strtok(Strtok(ts), ".")
    p === nothing && return UInt8[]
    st = w.sig
    if t <= 0 && (st.btime != 0 || st.bdate != 0)     # time of day
        append!(p, st.date_string)
        push!(p, UInt8(']'))
    end
    p
end

# Convert a sample number to a string with milliseconds, using the given
# sampling frequency (C fmstimstr).
function _fmstimstr(w::Wfdb, t::Int64, f::Float64)
    st = w.sig
    btime, bdate = st.btime, st.bdate
    if t > 0 || (btime == 0 && bdate == 0)
        # time interval
        t < 0 && (t = -t)
        # Convert from sample intervals to seconds.
        s = d2l(t / f)
        msec = d2i((t - s * f) * 1000.0 / f + 0.5)
        if msec == 1000
            msec = Int32(0)
            s += 1
        end
        t = s
        seconds = (t % 60) % Int32
        t ÷= 60
        minutes = (t % 60) % Int32
        hours = (t ÷ 60) % Int32
        return hours > 0 ? cformat("%2d:%02d:%02d.%03d", hours, minutes, seconds, msec) :
                           cformat("   %2d:%02d.%03d", minutes, seconds, msec)
    end
    # time of day
    # Convert to milliseconds since midnight.
    tms = btime - (t * 1000.0 / f)
    # Convert to seconds.
    s = d2l(tms / 1000.0)
    msec = d2i((tms - s * 1000.0) + 0.5)
    if msec == 1000
        msec = Int32(0)
        s += 1
    end
    t = s
    seconds = (t % 60) % Int32
    t ÷= 60
    minutes = (t % 60) % Int32
    t ÷= 60
    hours = (t % 24) % Int32
    days = t ÷ 24
    if days != st.pdays
        if bdate > 0
            _datstr!(w, days + bdate)
        elseif days == 0
            st.date_string = UInt8[]
        else
            st.date_string = cformat(" %ld", days)
        end
        st.pdays = days
    end
    r = cformat("[%02d:%02d:%02d.%03d%s]", hours, minutes, seconds, msec, st.date_string)
    length(r) > TIME_STRING_MAX && resize!(r, TIME_STRING_MAX)
    r
end

# Convert a string to a sample number, using the given sampling frequency
# (C fstrtim).
function fstrtim(w::Wfdb, string0::AbstractVector{UInt8}, f::Float64)
    st = w.sig
    string = cstr(Vector{UInt8}(string0))
    k = 1
    while k <= length(string) && string[k] in b" \t\n\r"
        k += 1
    end
    str = view(string, k:length(string))
    c = isempty(str) ? 0x00 : str[1]
    rest = view(str, 2:length(str))
    if c == UInt8('c')
        return st.cfreq > 0.0 ? d2l((_strtod0(rest) - st.bcount) * f / st.cfreq) :
                                strtoll(rest, 10)[1]
    elseif c == UInt8('e')
        n = st.in_msrec != 0 ? st.msnsamples : st.nsamples
        return n * ((st.gvmode & WFDB_HIGHRES) == WFDB_HIGHRES ? Int64(st.spfmax) : Int64(1))
    elseif c == UInt8('f')
        return d2l(strtoll(rest, 10)[1] * f / st.ffreq)
    elseif c == UInt8('i')
        return d2l(st.istime * (st.ifreq > 0.0 ? st.ifreq / st.sfreq : 1.0) *
                   ((st.gvmode & WFDB_HIGHRES) == WFDB_HIGHRES ? Float64(st.ispfmax) : 1.0))
    elseif c == UInt8('o')
        return st.ostime
    elseif c == UInt8('s')
        return strtoll(rest, 10)[1]
    elseif c == UInt8('[')
        # time of day, possibly with date or days since start
        q = findfirst(==(UInt8(']')), rest)
        q === nothing && return Int64(0)    # '[...': malformed time string
        p = findfirst(==(UInt8(' ')), rest)
        days = Int64(0)     # '[hh:mm:ss.sss]': time since midnight only
        if p !== nothing && p <= q
            r = findnext(==(UInt8('/')), rest, p + 1)
            if r !== nothing && r <= q
                # '[hh:mm:ss.sss dd/mm/yyyy]'
                days = strdat(w, view(rest, p+1:length(rest))) - st.bdate
            else
                # '[hh:mm:ss.sss d]'
                days = _strtol10(view(rest, p+1:length(rest)))
            end
        end
        x = Float64(fstrtim(w, rest, 1000.0) - st.btime)
        days > 0 && (x += days * MS_PER_DAY)
        return -d2l(x * f / 1000.0 + 0.5)
    end
    x = _strtod0(str)
    p = findfirst(==(UInt8(':')), str)
    p === nothing && return d2l(x * f + 0.5)
    rest2 = view(str, p+1:length(str))
    y = _strtod0(rest2)
    p2 = findfirst(==(UInt8(':')), rest2)
    p2 === nothing && return d2l((60.0 * x + y) * f + 0.5)
    z = _strtod0(view(rest2, p2+1:length(rest2)))
    d2l((3600.0 * x + 60.0 * y + z) * f + 0.5)
end

# The frequency used by timstr, mstimstr and strtim (0: not specified).
function _tfreq(st::SigState)
    st.ifreq > 0.0 ? st.ifreq : st.sfreq > 0.0 ? st.sfreq : st.legacy ? 1.0 : 0.0
end

# wfdb-x: no default sampling frequency (C assumed 1 sample per second in
# the time conversions). Without one, timstr and mstimstr report an error
# and return the time as a sample number ("s" followed by |t|, a valid
# strtim argument).
function _nofreq_timstr(w::Wfdb, fn::String, t::Int64)
    wfdb_error(w, "%s: sampling frequency is not specified\n", fn)
    String(cformat("s%ld", t < 0 ? -t : t))
end

"""
    wfdbx_time_needs_freq([w], string) -> Int32

wfdb-x addition (not in the C library): 1 if [`strtim`](@ref) needs a
sampling frequency to convert `string`, 0 otherwise (sample numbers `s...`,
`e`, `i`, `o`, and counter values `c...` when no counter frequency is set).
Leading spaces, tabs, newlines and carriage returns are skipped. See
`docs/DIVERGENCES.md`.
"""
function wfdbx_time_needs_freq(w::Wfdb, string::ByteStr)
    s = _bv(string)
    i = 1
    while i <= length(s) && (s[i] == UInt8(' ') || s[i] == UInt8('\t') ||
                             s[i] == UInt8('\n') || s[i] == UInt8('\r'))
        i += 1
    end
    c = i <= length(s) ? s[i] : 0x00
    if c == UInt8('e') || c == UInt8('i') || c == UInt8('o') || c == UInt8('s')
        Int32(0)
    elseif c == UInt8('c')
        Int32(w.sig.cfreq > 0.0)
    else
        Int32(1)
    end
end

"""
    timstr([w], t) -> String

C `timstr`: a time string (`hh:mm:ss`, or `[hh:mm:ss dd/mm/yyyy]` for a
time of day: `t <= 0` when the base time is defined). wfdb-x: if the
sampling frequency is not specified, reports an error and returns `"s"`
followed by `|t|` (C assumed 1 sample per second; see `docs/DIVERGENCES.md`).
"""
function timstr(w::Wfdb, t::Integer)
    f = _tfreq(w.sig)
    f > 0.0 || return _nofreq_timstr(w, "timstr", Int64(t))
    String(_ftimstr(w, Int64(t), f))
end

"""
    mstimstr([w], t) -> String

C `mstimstr`: as `timstr`, with milliseconds (wfdb-x: the same error as
`timstr` if the sampling frequency is not specified).
"""
function mstimstr(w::Wfdb, t::Integer)
    f = _tfreq(w.sig)
    f > 0.0 || return _nofreq_timstr(w, "mstimstr", Int64(t))
    String(_fmstimstr(w, Int64(t), f))
end

"    getcfreq([w]) -> Float64

C `getcfreq`: the counter frequency (the frame frequency if none is set)."
getcfreq(w::Wfdb) = w.sig.cfreq > 0.0 ? w.sig.cfreq : w.sig.ffreq
"    setcfreq([w], freq)

C `setcfreq`: set the counter frequency (0: none)."
setcfreq(w::Wfdb, freq::Real) = (w.sig.cfreq = Float64(freq); nothing)
"    getbasecount([w]) -> Float64

C `getbasecount`: the base counter value."
getbasecount(w::Wfdb) = w.sig.bcount
"    setbasecount([w], counter)

C `setbasecount`: set the base counter value."
setbasecount(w::Wfdb, counter::Real) = (w.sig.bcount = Float64(counter); nothing)

"""
    strtim([w], string) -> Int64

C `strtim`: convert a time string to a sample number (negative for a time
of day). wfdb-x: if the sampling frequency is not specified and the
string needs one ([`wfdbx_time_needs_freq`](@ref)), reports an error and
returns 0 (C assumed 1 sample per second; see `docs/DIVERGENCES.md`).
"""
function strtim(w::Wfdb, string::ByteStr)
    f = _tfreq(w.sig)
    if f <= 0.0
        if wfdbx_time_needs_freq(w, string) != 0
            wfdb_error(w, "strtim: sampling frequency is not specified\n")
            return Int64(0)
        end
        f = 1.0     # not used
    end
    fstrtim(w, _bv(string), f)
end

# C datstr: the date string (also kept as the current date string). The
# numeric constants are those of the Julian date algorithm of the C library
# (`caldat` of *Numerical Recipes in C*, Press et al.).
function _datstr!(w::Wfdb, date::Int64)
    y, m, d = _julian_ymd(date)
    ds = cformat(" %02d/%02d/%d", d, m, y)
    length(ds) > DATE_STRING_MAX && resize!(ds, DATE_STRING_MAX)
    w.sig.date_string = copy(ds)
    w.sig.pdays = -1
    ds
end

# The calendar date (year, month, day; Int32) of a Julian date, as datstr
# gives it (also used for the base_date of the high-level API).
function _julian_ymd(date::Int64)
    if date >= JD_GREGORIAN
        # Gregorian calendar correction
        gcorr = d2i(((date - 1867216) - 0.25) / 36524.25)
        date += 1 + gcorr - d2l(0.25 * gcorr)
    end
    date += 1524
    jy = d2i(6680.0 + ((date - 2439870) - 122.1) / 365.25)
    jd = d2l(365 * Int64(jy) + 0.25 * jy)
    jm = d2i((date - jd) / 30.6001)
    d = (date - jd - d2i(30.6001 * jm)) % Int32
    m = jm - Int32(1)
    m > 12 && (m -= Int32(12))
    y = jy - Int32(4715)
    m > 2 && (y -= Int32(1))
    y <= 0 && (y -= Int32(1))
    (y, m, d)
end

"""
    datstr([w], date) -> String

C `datstr`: a Julian date as ` dd/mm/yyyy` (with a leading space).
"""
datstr(w::Wfdb, date::Integer) = String(_datstr!(w, Int64(date)))

"""
    strdat([w], string) -> Int64

C `strdat`: the Julian date of a `dd/mm/yyyy` date (0 if it is invalid).
(The numeric constants are those of `julday` of *Numerical Recipes in C*,
as in the C library.)
"""
function strdat(w::Wfdb, string::ByteStr)
    s = cstr(Vector{UInt8}(_bv(string)))
    mp = findfirst(==(UInt8('/')), s)
    mp === nothing && return Int64(0)
    yp = findnext(==(UInt8('/')), s, mp + 1)
    yp === nothing && return Int64(0)
    d = _strtol10(s) % Int32
    1 <= d <= 31 || return Int64(0)
    m = _strtol10(view(s, mp+1:length(s))) % Int32
    1 <= m <= 12 || return Int64(0)
    y = _strtol10(view(s, yp+1:length(s))) % Int32
    y == 0 && return Int64(0)
    jy, jm = m > 2 ? (y, m + Int32(1)) : (y - Int32(1), m + Int32(13))
    date = jy > 0 ? d2l(365.25 * jy) : -d2l(-365.25 * (jy + 0.25))
    date += Int64(d2i(30.6001 * jm) + d) + 1720995
    if d + 31 * (Int64(m) + 12 * Int64(y)) >= IGREG
        # Gregorian calendar correction
        gcorr = d2i(0.01 * jy)
        date += 2 - gcorr + d2i(0.25 * gcorr)
    end
    date
end

# ---------------------------------------------------------------------------
# Amplitude conversions

# wfdb-x: no default gain (C assumed WFDB_DEFGAIN, 200 adu per physical
# unit, for uncalibrated signals and invalid signal numbers). Returns the
# gain of signal s, or 0 after reporting an error (C conversion_gain).
function _conversion_gain(w::Wfdb, fn::String, s::UInt32)
    st = w.sig
    if st.legacy        # wfdb-x: legacy mode (original behavior)
        g = s < max(st.nvsig, 0) % UInt32 ? st.vsd[s+1].info.gain : WFDB_DEFGAIN
        return g == 0.0 ? WFDB_DEFGAIN : g
    end
    if s >= max(st.nvsig, 0) % UInt32
        wfdb_error(w, "%s: invalid signal number %u\n", fn, s)
        return 0.0
    end
    g = st.vsd[s+1].info.gain
    g == 0.0 && wfdb_error(w, "%s: signal %u is uncalibrated\n", fn, s)
    g
end

# The baseline of signal s (0 for an invalid signal number: legacy mode only).
_conversion_baseline(st::SigState, s::UInt32) =
    s < max(st.nvsig, 0) % UInt32 ? st.vsd[s+1].info.baseline : Int32(0)

"""
    adumuv([w], s, a) -> Int32

C `adumuv`: convert ADC units of signal `s` to microvolts. wfdb-x: for an
uncalibrated signal or an invalid signal number, reports an error and
returns `WFDB_INVALID_SAMPLE`.
"""
function adumuv(w::Wfdb, s::Integer, a::Integer)
    g = _conversion_gain(w, "adumuv", s % UInt32)
    g == 0.0 && return WFDB_INVALID_SAMPLE
    x = (a % Int32) * 1000.0 / g
    x >= 0.0 ? d2i(x + 0.5) : d2i(x - 0.5)
end

"""
    muvadu([w], s, v) -> Int32

C `muvadu`: convert microvolts to ADC units of signal `s`. wfdb-x: for an
uncalibrated signal or an invalid signal number, reports an error and
returns `WFDB_INVALID_SAMPLE`.
"""
function muvadu(w::Wfdb, s::Integer, v::Integer)
    g = _conversion_gain(w, "muvadu", s % UInt32)
    g == 0.0 && return WFDB_INVALID_SAMPLE
    x = g * (v % Int32) * 0.001
    x >= 0.0 ? d2i(x + 0.5) : d2i(x - 0.5)
end

"""
    aduphys([w], s, a) -> Float64

C `aduphys`: convert ADC units of signal `s` to physical units. wfdb-x: for
an uncalibrated signal or an invalid signal number, reports an error and
returns `NaN`.
"""
function aduphys(w::Wfdb, s::Integer, a::Integer)
    s = s % UInt32
    g = _conversion_gain(w, "aduphys", s)
    g == 0.0 && return NaN
    b = Float64(_conversion_baseline(w.sig, s))
    ((a % Int32) - b) / g
end

"""
    physadu([w], s, v) -> Int32

C `physadu`: convert physical units to ADC units of signal `s`. wfdb-x: for
an uncalibrated signal or an invalid signal number, reports an error and
returns `WFDB_INVALID_SAMPLE`.
"""
function physadu(w::Wfdb, s::Integer, v::Real)
    s = s % UInt32
    g = _conversion_gain(w, "physadu", s)
    g == 0.0 && return WFDB_INVALID_SAMPLE
    b = _conversion_baseline(w.sig, s)
    x = Float64(v) * g
    x >= 0.0 ? d2i(x + 0.5) + b : d2i(x - 0.5) + b
end

# ---------------------------------------------------------------------------
# Random access

"""
    sample([w], s, t) -> Int32

C `sample`: sample number `t` of input signal `s` (buffered random access);
see [`sample_valid`](@ref).
"""
function sample(w::Wfdb, s::Integer, t::Integer)
    st = w.sig
    s = s % UInt32
    t = Int64(t)
    nsig = max(Int(st.nvsig), st.nisig, 0)
    stride = Int64(nsig)    # (getvec may store tspf samples per call)

    # Allocate the sample buffer on the first call.
    if !st.have_sbuf
        width = max(nsig, Int(st.tspf), 0)
        st.sbuf = zeros(Int32, max(width, 1) * Int(BUFLN) + max(width, _vec_need(st)))
        st.have_sbuf = true
        st.sample_tt = -1
    end

    # If the caller requested a sample from an unavailable signal, return an
    # invalid value. Note that sample_vflag is not cleared in this case.
    if s >= nsig
        st.sample_vflag = -1
        return WFDB_INVALID_SAMPLE
    end

    # If the caller specified a negative sample number, prepare to return
    # sample 0.
    t < 0 && (t = 0)

    # If the caller has requested a sample that is no longer in the buffer,
    # or that is further ahead than the length of the buffer, reset the
    # signal file pointer(s).
    if t <= st.sample_tt - BUFLN || t > st.sample_tt + BUFLN
        tt = t - BUFLN
        tt < 0 && (tt = -1)
        st.sample_tt = tt
        if isigsettime(w, tt + 1) < 0
            st.sample_vflag = 0
            return WFDB_INVALID_SAMPLE
        end
    end
    # If the requested sample is not yet in the buffer, read and buffer more
    # samples. If we reach the end of the record, clear sample_vflag and
    # return the last valid value.
    while t > st.sample_tt
        st.sample_tt += 1
        pos = Int(stride * (st.sample_tt & (BUFLN - 1)))
        if _call_at(getvec_at, w, st.sbuf, pos) < 0
            st.sample_tt -= 1
            st.sample_vflag = 0
            return st.sbuf[Int(stride * (st.sample_tt & (BUFLN - 1)))+s+1]
        end
    end

    # The requested sample is in the buffer. Set sample_vflag and return the
    # requested sample.
    v = st.sbuf[Int(stride * (t & (BUFLN - 1)))+s+1]
    st.sample_vflag = v == WFDB_INVALID_SAMPLE ? Int32(-1) : Int32(1)
    v
end

"""
    sample_valid([w]) -> Int32

C `sample_valid`: 1 if the value returned by the last `sample()` call was
valid, -1 if it was invalid, 0 at the end of the record.
"""
sample_valid(w::Wfdb) = w.sig.sample_vflag

# ---------------------------------------------------------------------------
# The same functions on the default instance.

isigopen(record::OptByteStr, siarray::SiginfoArg, nsig::Integer) = isigopen(lib(), record, siarray, nsig)
osigopen(record::OptByteStr, siarray::SiginfoArg, nsig::Integer) = osigopen(lib(), record, siarray, nsig)
osigfopen(siarray::SiginfoArg, nsig::Integer) = osigfopen(lib(), siarray, nsig)
findsig(p::ByteStr) = findsig(lib(), p)
getspf() = getspf(lib())
setgvmode(mode::Integer) = setgvmode(lib(), mode)
getgvmode() = getgvmode(lib())
setifreq(f::Real) = setifreq(lib(), f)
getifreq() = getifreq(lib())
getvec(vector::Vector{Int32}) = getvec(lib(), vector)
getframe(vector::Vector{Int32}) = getframe(lib(), vector)
getvecs(out::Vector{Int32}, n::Integer) = getvecs(lib(), out, n)
getvecs_status(out::Vector{Int32}, n::Integer) = getvecs_status(lib(), out, n)
putvec(vector::AbstractVector{Int32}) = putvec(lib(), vector)
isigsettime(t::Integer) = isigsettime(lib(), t)
isgsettime(g::Integer, t::Integer) = isgsettime(lib(), g, t)
tnextvec(s::Integer, t::Integer) = tnextvec(lib(), s, t)
setibsize(n::Integer) = setibsize(lib(), n)
setobsize(n::Integer) = setobsize(lib(), n)
newheader(record::ByteStr) = newheader(lib(), record)
setheader(record::ByteStr, siarray::AbstractVector{Siginfo}, nsig::Integer) =
    setheader(lib(), record, siarray, nsig)
getseginfo(sarray::Ref) = getseginfo(lib(), sarray)
setmsheader(record::ByteStr, segment_name::AbstractVector, nsegments::Integer) =
    setmsheader(lib(), record, segment_name, nsegments)
wfdbgetskew(s::Integer) = wfdbgetskew(lib(), s)
wfdbsetiskew(s::Integer, skew::Integer) = wfdbsetiskew(lib(), s, skew)
wfdbsetskew(s::Integer, skew::Integer) = wfdbsetskew(lib(), s, skew)
wfdbgetstart(s::Integer) = wfdbgetstart(lib(), s)
wfdbsetstart(s::Integer, nbytes::Integer) = wfdbsetstart(lib(), s, nbytes)
wfdbputprolog(buf::ByteStr, size::Integer, s::Integer) = wfdbputprolog(lib(), buf, size, s)
setinfo(record::OptByteStr) = setinfo(lib(), record)
putinfo(s::ByteStr) = putinfo(lib(), s)
getinfo(record::OptByteStr) = getinfo(lib(), record)
wfdb_freeinfo() = wfdb_freeinfo(lib())
sampfreq(record::OptByteStr) = sampfreq(lib(), record)
setsampfreq(freq::Real) = setsampfreq(lib(), freq)
setbasetime(string::OptByteStr) = setbasetime(lib(), string)
timstr(t::Integer) = timstr(lib(), t)
mstimstr(t::Integer) = mstimstr(lib(), t)
getcfreq() = getcfreq(lib())
setcfreq(freq::Real) = setcfreq(lib(), freq)
getbasecount() = getbasecount(lib())
setbasecount(counter::Real) = setbasecount(lib(), counter)
strtim(string::ByteStr) = strtim(lib(), string)
wfdbx_time_needs_freq(string::ByteStr) = wfdbx_time_needs_freq(lib(), string)
wfdbx_set_legacy(on::Union{Bool,Integer}) = wfdbx_set_legacy(lib(), on)
wfdbx_get_legacy() = wfdbx_get_legacy(lib())
wfdbx_legacy_args(args::Vector{String}) = wfdbx_legacy_args(lib(), args)
datstr(date::Integer) = datstr(lib(), date)
strdat(string::ByteStr) = strdat(lib(), string)
adumuv(s::Integer, a::Integer) = adumuv(lib(), s, a)
muvadu(s::Integer, v::Integer) = muvadu(lib(), s, v)
aduphys(s::Integer, a::Integer) = aduphys(lib(), s, a)
physadu(s::Integer, v::Real) = physadu(lib(), s, v)
sample(s::Integer, t::Integer) = sample(lib(), s, t)
sample_valid() = sample_valid(lib())
wfdb_sampquit() = wfdb_sampquit(lib())
wfdb_sigclose() = wfdb_sigclose(lib())
wfdb_osflush() = wfdb_osflush(lib())
wfdb_oinfoclose() = wfdb_oinfoclose(lib())

export isigopen, osigopen, osigfopen, findsig, getspf, setgvmode, getgvmode, setifreq,
       getifreq, getvec, getframe, getvecs, getvecs_status, putvec, isigsettime, isgsettime, tnextvec,
       setibsize, setobsize, newheader, setheader, getseginfo, setmsheader, wfdbgetskew,
       wfdbsetiskew, wfdbsetskew, wfdbgetstart, wfdbsetstart, wfdbputprolog, setinfo,
       putinfo, getinfo, wfdb_freeinfo, sampfreq, setsampfreq, setbasetime, timstr,
       mstimstr, getcfreq, setcfreq, getbasecount, setbasecount, strtim, datstr, strdat,
       wfdbx_time_needs_freq, wfdbx_set_legacy, wfdbx_get_legacy, wfdbx_legacy_args,
       adumuv, muvadu, aduphys, physadu, sample, sample_valid

# ---------------------------------------------------------------------------
# Precompilation workload: the library functions not exercised by the tools.

register_workload("signal") do
    with_workload_data(files=NODEFAULTS_FILES) do dir
        w = Wfdb()
        wfdbquiet(w)
        setwfdb(w, ".")
        for rec in ("100s", "fmt212", "fmt310", "fmt311", "fmt16", "fmt24", "fmt160")
            n = isigopen(w, rec, nothing, 0)
            n > 0 || continue
            si = [Siginfo() for _ in 1:n]
            isigopen(w, rec, si, n)
            v = zeros(Int32, n)
            getvec(w, v); getframe(w, v); isigsettime(w, 5); isgsettime(w, 0, 3)
            tnextvec(w, 0, 2); sample(w, 0, 10); sample_valid(w)
            buf = zeros(Int32, 16 * n)
            getvecs(w, buf, 16)
            setifreq(w, 100.0); getvec(w, v); setifreq(w, sampfreq(w, nothing))
            findsig(w, "0"); getspf(w); getgvmode(w); getifreq(w)
            adumuv(w, 0, 100); muvadu(w, 0, 100); aduphys(w, 0, 100); physadu(w, 0, 1.0)
            wfdbgetskew(w, 0); wfdbgetstart(w, 0); wfdbsetiskew(w, 0, 0)
            sarray = Ref{Union{Nothing,Vector{Seginfo}}}(nothing)
            getseginfo(w, sarray)
            getinfo(w, rec); getinfo(w, nothing)
            wfdbquit(w)
        end
        timstr(w, 360); mstimstr(w, -360); strtim(w, "1:00"); strtim(w, "[12:00:00 01/01/2000]")
        strtim(w, "s100"); strtim(w, "e"); strtim(w, "c10"); strtim(w, "f10"); strtim(w, "i")
        wfdbx_time_needs_freq(w, " s10"); wfdbx_time_needs_freq(w, "c1")
        w0 = Wfdb()         # no sampling frequency, no signals
        wfdbquiet(w0)
        timstr(w0, -5); mstimstr(w0, 5); strtim(w0, "1:00"); strtim(w0, "s5")
        adumuv(w0, 0, 1); muvadu(w0, 0, 1); aduphys(w0, 0, 1); physadu(w0, 0, 1.0)
        setifreq(w0, 100.0)
        wfdbx_legacy_args(w0, ["--legacy", "x"]); wfdbx_get_legacy(w0)   # legacy mode
        timstr(w0, -5); mstimstr(w0, 5); strtim(w0, "1:00"); setifreq(w0, 100.0)
        adumuv(w0, 0, 1); muvadu(w0, 0, 1); aduphys(w0, 0, 1); physadu(w0, 0, 1.0)
        isigopen(w0, "nf", nothing, 0); wfdbquit(w0); wfdbx_set_legacy(w0, false)
        datstr(w, 2451545); strdat(w, "01/01/2000"); setbasetime(w, "12:00:00 01/02/2003")
        setbasetime(w, ""); getcfreq(w); setcfreq(w, 0.0); getbasecount(w); setbasecount(w, 0.0)
        setibsize(w, 0); setobsize(w, 0)
        for fmt in (8, 16, 61, 80, 160, 212, 310, 311, 24, 32)
            si = [Siginfo(fname=Vector{UInt8}(b"wl.dat"), desc=Vector{UInt8}(b"x"), fmt=fmt,
                          spf=1, gain=200.0, adcres=12, group=0) for _ in 1:2]
            osigfopen(w, si, 2) == 2 || continue
            setsampfreq(w, 250.0)
            v = Int32[0, 0]
            for k in 1:10
                v[1] = k; v[2] = -k
                putvec(w, v)
            end
            wfdbsetskew(w, 0, 0); wfdbsetstart(w, 0, 0)
            newheader(w, "wl"); putinfo(w, "info")
            wfdbquit(w)
            n = isigopen(w, "wl", nothing, 2)
            v2 = zeros(Int32, 2)
            while getvec(w, v2) > 0
            end
            wfdbquit(w)
        end
        setinfo(w, "wl"); putinfo(w, "x"); setinfo(w, nothing)
        setmsheader(w, "wlm", ["wl", "wl"], 2)
        wfdbquit(w)
    end
end
