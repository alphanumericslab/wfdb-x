# parsescp: parse an SCP-ECG file read from the standard input (port of
# convert/parsescp.c, by way of the Rust and C++ ports of wfdb-x).
#
# parsescp converts SCP-ECG files produced by SpaceLabs/Burdick ECG carts
# into more easily usable formats:
#
#  RECORD.des (text): description (age, sex, recording bandwidth,
#                     measurements, diagnoses)
#  RECORD.ecg (binary): reconstructed ECGs
#  RECORD.key (text): patient's name and ID (medical record number)
#  RECORD.txt (text): reconstructed ECGs (with -v)
#  RECORD.dat, RECORD.hea: WFDB-format record (with -w)
#
# With -a, an anonymized copy of the input is written to the standard output
# instead.
#
# The input is held in one byte buffer, and the C program's pointers into it
# are represented by 0-based offsets (_scp_b(s, off) is the byte at `off`).
# Integer arithmetic uses the C types (wrapping), and floating-point
# expressions are evaluated in the order of the C expressions, so that the
# output is identical to C's. Behaviors of the C program that are undefined
# (on defective inputs) are resolved as in the other wfdb-x implementations
# (see docs/KNOWN_C_BEHAVIORS.md): bytes beyond the end of the input are
# read as 0; signal arrays have at least 5000 samples and samples beyond the
# end of a lead are 0; leads whose indices are outside the signal array read
# as zeros; missing subtraction zones are ignored and samples outside the
# arrays are skipped; strings copied into fixed-size buffers are truncated;
# a missing date or time of acquisition is left empty, and an invalid month
# is printed as `???`. Samples are written in little-endian byte order, as
# the C program does on x86.
#
# Copyright (C) 2000-2014 George B. Moody and Edna S. Moody (original C
# program, convert/parsescp.c; revised 2016-2020 by Benjamin Moody).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
# 12 bits and millivolts), because a silently assumed value corrupts every
# result derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).

const _SCP_VERSION_STRING = b"#ECG/1.0"
const _SCP_INVALID_SAMPLE = Int16(-32768)   # WFDB_INVALID_SAMPLE
# The C program allocates every array with malloc/calloc; requests larger
# than this many elements are treated as allocation failures.
const _SCP_MAXALLOC = UInt64(1) << 28
# Signal arrays have at least this many elements (the .ecg file always
# contains 5000 samples of lead II); samples beyond a lead's length are 0.
const _SCP_MINSIGLEN = UInt64(5000)
const _SCP_ECG_SEGLEN = 1250        # samples per lead in each .ecg segment
const _SCP_PROLOG_SIZE = 512        # size of the .ecg file prolog
const _SCP_HEADER_SIZE = 6          # record header: CRC (2 bytes), length (4)
const _SCP_SECHDR_SIZE = 16         # section header (ID, length, versions, reserved)
const _SCP_MIN_SECLEN = 8           # shortest valid section
const _SCP_NSECTIONS = 12           # standard sections 0-11
const _SCP_MAXRECNAME = 11          # longest record name accepted by -o
const _SCP_NAMEBUF = 100            # size of the patient name buffer
const _SCP_IDBUF = 30               # size of the patient ID buffer
const _SCP_DRBUF = 100              # size of the referring physician buffer
const _SCP_COMMENTBUF = 200         # size of the comments buffer
const _SCP_MAXREPORT = 1200         # size of the report statement array
const _SCP_MAXAGE = 90              # ages above this are censored
const _SCP_CENSORED_DATE = UInt32(257)  # censored month and day (257 => 1 Jan)
const _SCP_UNDEF_AXIS = Int16(999)  # axis value meaning "undefined"
const _SCP_NOTCOMPUTED = Int16(29999)   # measurement never computed by the analyzer
const _SCP_REJECTED = Int16(29998)  # lead rejected, measurement not computed
const _SCP_ABSENT = Int16(19999)    # corresponding wave not present
const _SCP_STD_HUFFMAN = UInt32(19999)  # "standard Huffman table only"
const _SCP_HUFF_ERROR = UInt64(1000000) # bits "read" after a Huffman decoding error
const _SCP_HUFF_MAXBITS = 63        # longest code searched for
const _SCP_ZWINDOW = 5000           # samples used for the median (-z)
const _SCP_ZLIMIT = 2000            # larger zero-mean samples are invalid (-z)
# The gain of the WFDB record (adu/mV) is exact, not assumed: the samples
# are rescaled to units of 5000 nV (_SCP_NV_PER_UNIT), i.e., 200 adu/mV.
const _SCP_WFDB_GAIN = 200.0
const _SCP_WFDB_FMT = Int32(16)     # signal format of the WFDB record
const _SCP_WFDB_ADCRES = Int32(16)  # ADC resolution of the WFDB record
# wfdb-x: legacy mode (original behavior): the sampling frequency that the C
# program always wrote, and assumed when no sample interval was given
const _SCP_LEGACY_FREQ = 500.0
const _SCP_US_PER_S = 1.0e6         # microseconds per second
const _SCP_NV_PER_UNIT = 5000.0     # amplitude multiplier divisor (5 uV per adu)
const _SCP_BL_UNITS = 0.0001        # units of the baseline filter field (Hz)

const _SCP_MONTH = (b"January", b"February", b"March", b"April", b"May", b"June", b"July",
                    b"August", b"September", b"October", b"November", b"December")

# Standard lead names (index: lead ID).
const _SCP_LEADNAME = (
    b"<Unspecified lead>", b"I", b"II", b"V1", b"V2",                       #  0 -  4
    b"V3", b"V4", b"V5", b"V6", b"V7",                                      #  5 -  9
    b"V2R", b"V3R", b"V4R", b"V5R", b"V6R",                                 # 10 - 14
    b"V7R", b"X", b"Y", b"Z", b"CC5",                                       # 15 - 19
    b"CM5", b"Left Arm", b"Right Arm", b"Left Leg", b"I (Frank)",           # 20 - 24
    b"E", b"C", b"A", b"M", b"F",                                           # 25 - 29
    b"H", b"I-cal", b"II-cal", b"V1-cal", b"V2-cal",                        # 30 - 34
    b"V3-cal", b"V4-cal", b"V5-cal", b"V6-cal", b"V7-cal",                  # 35 - 39
    b"V2R-cal", b"V3R-cal", b"V4R-cal", b"V5R-cal", b"V6R-cal",             # 40 - 44
    b"V7R-cal", b"X-cal", b"Y-cal", b"Z-cal", b"CC5-cal",                   # 45 - 49
    b"CM5-cal", b"Left Arm-cal", b"Right Arm-cal", b"Left Leg-cal", b"I-cal (Frank)", # 50 - 54
    b"E-cal", b"C-cal", b"A-cal", b"M-cal", b"F-cal",                       # 55 - 59
    b"H-cal", b"III", b"aVR", b"aVL", b"aVF",                               # 60 - 64
    b"-aVR", b"V8", b"V9", b"V8R", b"V9R",                                  # 65 - 69
    b"D (Nehb - Dorsal)", b"A (Nehb - Anterior)", b"J (Nehb - Inferior",
    b"Defibrillator lead: anterior-lateral",
    b"External pacing lead: anterior-posterior",                            # 70 - 74
    b"A1 (Auxiliary unipolar lead 1)", b"A2 (Auxiliary unipolar lead 2)",
    b"A3 (Auxiliary unipolar lead 3)", b"A4 (Auxiliary unipolar lead 4)",
    b"V8-cal",                                                              # 75 - 79
    b"V9-cal", b"V8R-cal", b"V9R-cal", b"D-cal (Nehb - Dorsal)",
    b"A-cal (Nehb - Anterior)",                                             # 80 - 84
    b"J-cal (Nehb - Inferior)")                                             # 85
const _SCP_NLEADNAMES = length(_SCP_LEADNAME)
const _SCP_RESERVED_LEADS = 100     # lead IDs below this (and not named) are reserved

# Lead IDs of the leads written to the output files.
const _SCP_ID_I = 1
const _SCP_ID_II = 2
const _SCP_ID_V1 = 3                # (V1-V6: 3-8)
const _SCP_ID_V6 = 8
const _SCP_ID_III = 61
const _SCP_ID_AVR = 62
const _SCP_ID_AVL = 63
const _SCP_ID_AVF = 64

# Fields of the sets of measurements in section 10 (struct ECGmeas in C;
# each is a short): 0-based indices.
const _SCP_M_VLEN = 1
const _SCP_NMEAS = 33

# The rows of the table of measurements: label, 0-based field index.
const _SCP_MEASROWS = (
    (b"\nP duration    ms", 2), (b"\nPR interval   ms", 3), (b"\nQRS duration  ms", 4),
    (b"\nQT interval   ms", 5), (b"\nQ duration    ms", 6), (b"\nR duration    ms", 7),
    (b"\nS duration    ms", 8), (b"\nR' duration   ms", 9), (b"\nS' duration   ms", 10),
    (b"\nQ amplitude   uV", 11), (b"\nR amplitude   uV", 12), (b"\nS amplitude   uV", 13),
    (b"\nJ amplitude   uV", 16), (b"\nP+ amplitude  uV", 17), (b"\nP- amplitude  uV", 18),
    (b"\nT+ amplitude  uV", 19), (b"\nT- amplitude  uV", 20), (b"\nST slope    uV/s", 21),
    (b"\nP morphology  --", 22), (b"\nT morphology  --", 23), (b"\nIsoelec (I)   ms", 24),
    (b"\nIsoelec (K)   ms", 25), (b"\nIntrins defl  ms", 26), (b"\nQuality       --", 27),
    # FIXME: SCP spec doesn't specify units of st20, 60, 80, rr16, rr8 --
    # assume they are microvolts
    (b"\nST (J+20ms)   uV", 28), (b"\nST (J+60ms)   uV", 29), (b"\nST (J+80ms)   uV", 30),
    (b"\nST (J+RRm/16) uV", 31), (b"\nST (J+RRm/8)  uV", 32))

# The default (SCP standard) Huffman table: pattern, suffix bits, base value.
const _SCP_HTDEFAULT = (
    (0x0000, 0x0000, Int16(0)), (0x0004, 0x0000, Int16(1)), (0x0005, 0x0000, Int16(-1)),
    (0x000c, 0x0000, Int16(2)), (0x000d, 0x0000, Int16(-2)), (0x001c, 0x0000, Int16(3)),
    (0x001d, 0x0000, Int16(-3)), (0x003c, 0x0000, Int16(4)), (0x003d, 0x0000, Int16(-4)),
    (0x007c, 0x0000, Int16(5)), (0x007d, 0x0000, Int16(-5)), (0x00fc, 0x0000, Int16(6)),
    (0x00fd, 0x0000, Int16(-6)), (0x01fc, 0x0000, Int16(7)), (0x01fd, 0x0000, Int16(-7)),
    (0x03fc, 0x0000, Int16(8)), (0x03fd, 0x0000, Int16(-8)), (0x03fe, 0x0008, Int16(0)),
    (0x03ff, 0x0010, Int16(0)))
const _SCP_HUFF_WORDBITS = 16       # bits in a decoded value

# Description of each standard section (-v).
const _SCP_CONTENTS = (
    b" Pointers to data areas in the record\n",
    b" Header information - Patient data/ECG acquisition data\n",
    b" Huffman tables used in encoding of ECG data\n",
    b" ECG lead definition\n",
    b" QRS locations\n",
    b" Encoded reference beat data\n",
    b" Residual signal after reference beat subtraction (if reference beats\n  are stored);  otherwise, encoded rhythm data\n",
    b" Global measurements\n",
    b" Textual diagnosis from the interpretive device\n",
    b" Manufacturer specific diagnostic and overreading data\n",
    b" Lead measurement results\n",
    b" Universal statement codes resulting from the interpretation\n")

# Types of the values of section 1 tagged fields.
const _SCP_VT_TEXT = 0
const _SCP_VT_DATE = 1
const _SCP_VT_TIME = 2
const _SCP_VT_B1 = 3
const _SCP_VT_B2 = 4
const _SCP_VT_B2B1 = 5
const _SCP_VT_BN = 6
const _SCP_VT_MIXED = 7

const _ScpSig = Vector{Int16}
const _ScpSigs = Vector{Union{Nothing,_ScpSig}}

# Reference beat subtraction zone.
struct _ScpSubzone
    ztype::Int16    # beat type (0: dominant)
    t0::Int64       # first sample in zone
    t1::Int64       # fiducial
    t2::Int64       # last sample in zone
end

# The state of the program (the global and static variables of C). Lead
# indices (lead_i, ...) are 0-based, as in C (-1: absent).
mutable struct _Scp
    bflag::Int32            # 0: normal operation, 1: show baselines only
    fflag::Int32            # 0: quit on CRC error, 1: continue if possible
    tflag::Int32            # 0: normal operation, 1: show templates only
    vflag::Int32            # 0: run quietly, 1: print (lots of) messages
    xflag::Int32            # 0: run quietly, 1: print hexdump
    shift::Int32            # shift templates by this many samples
    lflag::Int32
    wflag::Int32
    zflag::Int32
    aflag::Int32
    skip::Vector{Int32}     # skip[id+1]: skip section id
    data::Vector{UInt8}     # the input
    pname::String
    nleads::Int32           # number of ECG leads
    nqrs::Int32             # number of beats detected
    nsamp::Vector{UInt64}   # nsamp[i+1]: number of samples in lead i
    rblen::Int64            # number of samples in refbeat (template)
    rblenms::Int64          # length of refbeat in milliseconds
    fc_m::Int32             # index of fiducial within refbeat
    gref::Float64           # gain for refbeat
    gres::Float64           # gain for residuals
    sfreq::Float64          # sampling frequency (samples/second/lead)
    recdate::Vector{UInt8}  # date of recording
    rectime::Vector{UInt8}  # time of recording
    recname::Vector{UInt8}  # record name
    patient_name::Vector{UInt8}
    referring_dr::Vector{UInt8}
    comments::Vector{UInt8}
    patient_id::Vector{UInt8}
    age::Int32
    sex::Int32              # 1: male, 2: female, 0: unknown, 9: unspecified
    rrint::Int32
    pon::Int32
    pend::Int32
    qrson::Int32
    qrsend::Int32
    tend::Int32
    paxis::Int16
    qrsaxis::Int16
    taxis::Int16
    blfilt::Int32           # baseline filter -3 dB point
    lpfilt::Int32           # low-pass filter -3 dB point
    filter_bit::Int32       # see SCP spec
    tdevid::Int32           # ID number of acquiring device
    tinst::Int32            # institution number
    tdept::Int32            # department number
    dept::Int64             # offset of location description (-1: none)
    inst::Int64             # offset of institution description
    stmnts::Int32           # number of statements in report
    report::Vector{Int64}   # offsets of the report statements (-1: none)
    nout::UInt64            # number of samples written per signal
    subz::Vector{Union{Nothing,_ScpSubzone}}
    ecg::_ScpSigs           # ecg[i+1]: reconstructed ECG for lead i
    have_ecg::Bool
    refbeat::_ScpSigs       # reference beats (templates)
    lead_i::Int16
    lead_ii::Int16
    lead_iii::Int16
    avr::Int16
    avf::Int16
    avl::Int16
    v1::Int16
    v2::Int16
    v3::Int16
    v4::Int16
    v5::Int16
    v6::Int16
    ecgmeas::Matrix{Int16}  # ecgmeas[field+1, k]: measurements of the kth lead
    nsecleads::Int32
    # static variables of getbits(), huffdecode() and write_output()
    w::UInt8
    hdx::Int16
    hx::Int16
    hxx::Int16
    hxxx::Int16
    hxout::Int16
    zbuf::Vector{Int16}
end

_Scp(pname::String) = _Scp(
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, zeros(Int32, _SCP_NSECTIONS), UInt8[], pname,
    -1, -1, UInt64[], 0, 0, 0, 0.0, 0.0, -1.0,
    UInt8[], UInt8[], UInt8[], UInt8[], UInt8[], UInt8[], UInt8[],
    -1, -1, -1, -1, -1, -1, -1, -1, _SCP_UNDEF_AXIS, _SCP_UNDEF_AXIS, _SCP_UNDEF_AXIS,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, fill(Int64(-1), _SCP_MAXREPORT), 0,
    Union{Nothing,_ScpSubzone}[], _ScpSigs(), false, _ScpSigs(),
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    zeros(Int16, _SCP_NMEAS, 0), 0,
    0, 0, 0, 0, 0, 0, zeros(Int16, _SCP_ZWINDOW))

# C conversion of double to short (via a 32-bit int, as gcc does).
@inline _scp_d2s(x::Float64) = d2i(x) % Int16

# calloc(n, sizeof(short)) for a signal; nothing if allocation fails.
_scp_newsig(n::UInt64) = n > _SCP_MAXALLOC ? nothing : zeros(Int16, max(n, _SCP_MINSIGLEN))

# Weighted sums of the low-pass filter, evaluated in the order of the C
# expressions (left to right, no fused multiply-add).
@inline function _scp_wsum3(a::Float64, wa::Float64, b::Float64, wb::Float64,
                            c::Float64, wc::Float64)
    x = a * wa
    y = b * wb
    z = c * wc
    (x + y) + z
end
@inline function _scp_wsum4(a::Float64, wa::Float64, b::Float64, wb::Float64,
                            c::Float64, wc::Float64, d::Float64, wd::Float64)
    r = _scp_wsum3(a, wa, b, wb, c, wc)
    r + d * wd
end

# ---- access to the input buffer (0-based offsets; 0 beyond the data) ----

@inline _scp_inrange(s::_Scp, off::Int64) = 0 <= off < length(s.data)
@inline _scp_b(s::_Scp, off::Int64) = _scp_inrange(s, off) ? UInt32(@inbounds s.data[off+1]) : UInt32(0)
@inline _scp_get16(s::_Scp, off::Int64) = _scp_b(s, off) | (_scp_b(s, off + 1) << 8)

function _scp_put16!(s::_Scp, val::UInt32, off::Int64)
    _scp_inrange(s, off) && (s.data[off+1] = val % UInt8)
    _scp_inrange(s, off + 1) && (s.data[off+2] = (val >> 8) % UInt8)
    nothing
end

function _scp_get32(s::_Scp, off::Int64)
    r = UInt64(_scp_b(s, off)) | (UInt64(_scp_b(s, off + 1)) << 8) |
        (UInt64(_scp_b(s, off + 2)) << 16) | (UInt64(_scp_b(s, off + 3)) << 24)
    # (*p << 24 is a sign-extended int in C)
    (r & 0x80000000) != 0 ? r | 0xffffffff00000000 : r
end

# The NUL-terminated string at `off` (ends at the end of the data).
function _scp_cstr(s::_Scp, off::Int64)
    _scp_inrange(s, off) || return UInt8[]
    k = findnext(iszero, s.data, off + 1)
    s.data[off+1:(k === nothing ? length(s.data) : k - 1)]
end

function _scp_getcrc(s::_Scp, off::Int64, length::Int64)
    crchigh = crclow = 0xff
    while length > 0
        length -= 1
        a = (_scp_b(s, off) % UInt8) ⊻ crchigh
        off += 1
        crchigh = a
        a >>= 4                 # top 4 bits of a are now zero
        a ⊻= crchigh
        crchigh, crclow = crclow, a     # swap crchigh, crclow
        # rotate a left by four bits (swap nibbles)
        b = (a & 0x0f) << 4
        a >>= 4
        a |= b
        b = a
        a = bitrotate(a, 1)     # rotate a left by one more bit
        a &= 0x1f
        crchigh ⊻= a
        a = b & 0xf0
        crchigh ⊻= a            # crchigh complete
        b = bitrotate(b, 1)     # rotate b left by one bit
        b &= 0xe0
        crclow ⊻= b             # crclow complete
    end
    (UInt16(crchigh) << 8) | UInt16(crclow)
end

function _scp_crcok(s::_Scp, off::Int64, length::Int64, crcref::UInt16, description)
    crc = _scp_getcrc(s, off, length)
    if crc == crcref
        s.vflag != 0 && cprintf("%s: correct (%d)\n", description, crc)
        return 1
    end
    s.vflag != 0 && cprintf("%s: error (calculated: %d, expected: %d)\n", description, crc, crcref)
    s.fflag != 0 || cexit(1)    # quit on CRC error unless in -f (force) mode
    0
end

# ---- signals (0-based lead indices) ----

# Signal k, if it exists.
@inline _scp_sigp(s::_Scp, k::Integer) = 0 <= k < length(s.ecg) ? s.ecg[k+1] : nothing

# A copy of signal k, or (if it does not exist) an array of zero samples.
function _scp_srcsig(s::_Scp, k::Integer)
    sig = _scp_sigp(s, k)
    sig === nothing ? zeros(Int16, max(s.nout, _SCP_MINSIGLEN)) : copy(sig)
end

@inline _scp_nsampk(s::_Scp, k::Integer) = 0 <= k < length(s.nsamp) ? s.nsamp[k+1] : UInt64(0)

# Signal k, or (if it does not exist) 5000 zero samples.
function _scp_sigr(s::_Scp, k::Integer)
    sig = _scp_sigp(s, k)
    sig === nothing ? zeros(Int16, _SCP_MINSIGLEN) : sig
end

function _scp_sample_at(s::_Scp, k::Integer, i::UInt64)
    sig = _scp_sigp(s, k)
    (sig === nothing || i >= length(sig)) ? Int16(0) : sig[i+1]
end

_scp_order(s::_Scp) = (s.lead_i, s.lead_ii, s.lead_iii, s.avr, s.avf, s.avl,
                       s.v1, s.v2, s.v3, s.v4, s.v5, s.v6)

# ---- output ----

function _scp_prval(out::Vector{UInt8}, val::Int16)
    if val == _SCP_NOTCOMPUTED
        append!(out, b"  n/comp")
    elseif val == _SCP_REJECTED
        append!(out, b"     rej")
    elseif val == _SCP_ABSENT
        append!(out, b"  absent")
    else
        sprintf!(out, "%8d", val)
    end
end

# Write n samples of signal `sig`, beginning at (0-based) sample i0, as
# little-endian 16-bit integers.
function _scp_write_samples(f::WfdbFile, sig::_ScpSig, i0::Int, n::Int)
    last = min(i0 + n, length(sig))
    i0 >= last && return
    buf = Vector{UInt8}(undef, 2 * (last - i0))
    k = 1
    for j in i0+1:last
        v = sig[j]
        buf[k] = v % UInt8
        buf[k+1] = (v >> 8) % UInt8
        k += 2
    end
    fwrite(f, buf)
    nothing
end

# This low-pass filter is implemented as a 5-tap weighted moving average FIR
# filter. The -3 dB point is at roughly 1/10 the sampling frequency. It is
# applied only to the .ecg file, not to the text-format samples.
function _scp_lowpass(s::_Scp)
    for i in 0:max(s.nleads, 0)-1
        inp = _scp_sigp(s, i)
        inp === nothing && continue
        n = _scp_nsampk(s, i)
        out = _scp_newsig(n)
        if out === nothing
            ceprintf("Insufficient memory for filtering\n")
            break
        end
        _scp_lowpass!(out, inp, n)
        s.ecg[i+1] = out
    end
end

# Filter the n samples of `inp` into `out`. Samples beyond the end of the
# input array read as 0, and writes beyond the end of the output array are
# skipped.
function _scp_lowpass!(out::_ScpSig, inp::_ScpSig, n::UInt64)
    nin = UInt64(length(inp))
    nout = UInt64(length(out))
    xs(k::UInt64) = k < nin ? Int32(inp[k+1]) : Int32(0)
    x(k::UInt64) = Float64(xs(k))
    put(k::UInt64, v::Int16) = (k < nout && (out[k+1] = v); nothing)
    z = UInt64(0)
    put(z, _scp_d2s(_scp_wsum3(x(z), 0.67, x(z + 1), 0.22, x(z + 2), 0.11)))
    put(z + 1, _scp_d2s(_scp_wsum4(x(z), 0.33, x(z + 1), 0.34, x(z + 2), 0.22, x(z + 3), 0.11)))
    # C: for (j = 2; j < nsamp[i] - 2; j++), with an unsigned (wrapping)
    # bound; iterations past the end of the output array would only make
    # skipped writes, so the loop stops there (the final writes below are
    # then skipped too).
    jend = min(n - UInt64(2), nout)
    j = UInt64(2)
    while j < jend
        put(j, _scp_d2s(_scp_wsum3(x(j), 0.34, Float64(xs(j - 1) + xs(j + 1)), 0.22,
                                   Float64(xs(j - 2) + xs(j + 2)), 0.11)))
        j += 1
    end
    put(j, _scp_d2s(_scp_wsum4(x(j - 2), 0.11, x(j - 1), 0.22, x(j), 0.34, x(j + 1), 0.33)))
    j += 1
    put(j, _scp_d2s(_scp_wsum3(x(j - 2), 0.11, x(j - 1), 0.22, x(j), 0.67)))
    nothing
end

function _scp_precgmeas(s::_Scp)
    out = Vector{UInt8}(b"Parameter  Units")
    nl = size(s.ecgmeas, 2)
    for k in 1:nl
        id = s.ecgmeas[1, k]    # lead ID
        if 0 < id < _SCP_NLEADNAMES
            sprintf!(out, "%8s", _SCP_LEADNAME[id+1])
        else
            sprintf!(out, "  <%4d>", id)
        end
    end
    for (label, field) in _SCP_MEASROWS
        append!(out, label)
        for k in 1:nl
            _scp_prval(out, s.ecgmeas[field+1, k])
        end
    end
    push!(out, UInt8('\n'))
    out
end

const _SCP_WLEADNAME = (b"I", b"II", b"III", b"aVR", b"aVF", b"aVL",
                        b"V1", b"V2", b"V3", b"V4", b"V5", b"V6")

function _scp_write_wfdb_record(s::_Scp)
    filename = append!(copy(s.recname), b".dat")
    nsig = length(_SCP_WLEADNAME)
    v = zeros(Int32, nsig)
    order = _scp_order(s)

    # wfdb-x: the sampling frequency is the one given in the SCP file (the C
    # program always wrote 500 Hz, as legacy mode does); without one, no
    # record is written.
    legacy = wfdbx_get_legacy() != 0
    if !legacy
        if s.sfreq <= 0.0
            ceprintf("%s: sampling frequency not specified; record %s not written\n", s.pname,
                     s.recname)
            return 0
        end
        setsampfreq(s.sfreq)
    end
    newheader(s.recname) < 0 && return 0
    legacy && setsampfreq(_SCP_LEGACY_FREQ)     # FIXME: we should calculate this!
    si = [Siginfo(fname=copy(filename), desc=Vector{UInt8}(name), units=Vector{UInt8}(b"mV"),
                  fmt=_SCP_WFDB_FMT,
                  gain=_SCP_WFDB_GAIN,          # wfdb-x: exact (see _SCP_WFDB_GAIN)
                  adcres=_SCP_WFDB_ADCRES)      # FIXME: we should calculate this!
          for name in _SCP_WLEADNAME]
    osigfopen(si, nsig) < nsig && return 0
    basetime = push!(copy(s.recdate), UInt8(' '))
    append!(basetime, s.rectime)
    setbasetime(push!(basetime, UInt8('\n')))

    # write the ECG samples
    i = UInt64(0)
    while i < s.nout
        for k in 1:nsig
            v[k] = _scp_sample_at(s, order[k], i)
        end
        putvec(v) < 0 && break
        i += 1
    end
    newheader(s.recname)
    sexc = s.sex == 1 ? UInt8('M') : s.sex == 2 ? UInt8('F') : UInt8('?')
    putinfo(cformat("<age>: %d <sex>: %c", min(s.age, Int32(_SCP_MAXAGE)), sexc))
    wfdbquit()
    1
end

function _scp_write_output(s::_Scp)
    isempty(s.recname) && (s.recname = Vector{UInt8}(b"ecg"))  # default record name
    recname = s.recname
    dname = append!(copy(recname), b".des")
    ename = append!(copy(recname), b".ecg")
    kname = append!(copy(recname), b".key")
    tname = append!(copy(recname), b".txt")
    dfile = cfopen(dname, "wb")
    if dfile === nothing
        ceprintf("%s: can't create '%s'\n", s.pname, dname)
        return 0
    end
    efile = cfopen(ename, "wb")
    if efile === nothing
        fclose(dfile)
        ceprintf("%s: can't create '%s'\n", s.pname, ename)
        return 0
    end
    kfile = cfopen(kname, "wb")
    if kfile === nothing
        fclose(dfile)
        fclose(efile)
        ceprintf("%s: can't create '%s'\n", s.pname, kname)
        return 0
    end
    tfile = nothing
    if s.vflag != 0
        tfile = cfopen(tname, "wb")
        if tfile === nothing
            fclose(dfile)
            fclose(efile)
            fclose(kfile)
            ceprintf("%s: can't create '%s'\n", s.pname, tname)
            return 0
        end
    end

    # Write the description file first.
    cfprintf(dfile, "%s description\n", _SCP_VERSION_STRING)
    cfprintf(dfile, "Record: %s (%s %s)\n", recname, s.recdate, s.rectime)
    cfprintf(dfile, "Age: %d\n", s.age)
    cfprintf(dfile, "Sex: ")
    cfprintf(dfile, s.sex == 1 ? "M\n" : s.sex == 2 ? "F\n" : s.sex == 0 ? "not known\n" :
                    s.sex == 9 ? "unspecified\n" : "<error>\n")     # (shouldn't happen)
    cfprintf(dfile, "Referring Dr: %s\n", s.referring_dr)
    cfprintf(dfile, "Comments: %s\n", s.comments)
    if s.tdevid == 0
        cfprintf(dfile, "Cart ID: <missing>\n")
    else
        cfprintf(dfile, "Cart ID: %d\n", s.tdevid)
    end
    sdept = s.dept < 0 ? Vector{UInt8}(b"<missing>") : _scp_cstr(s, s.dept)
    cfprintf(dfile, "Department: %s\n", sdept)
    if s.tdept == 0
        cfprintf(dfile, "Department #: <missing>\n")
    else
        cfprintf(dfile, "Department #: %s\n", sdept)
    end
    sinst = s.inst < 0 ? Vector{UInt8}(b"<missing>") : _scp_cstr(s, s.inst)
    cfprintf(dfile, "Institution: %s\n", sinst)
    if s.tinst == 0
        cfprintf(dfile, "Institution #: <missing>\n")
    else
        cfprintf(dfile, "Institution #: %d\n", s.tinst)
    end
    for i in 1:max(s.stmnts, 0)
        r = s.report[i]
        cfprintf(dfile, "Report %d: %s\n", Int32(i - 1), r < 0 ? nothing : _scp_cstr(s, r))
    end

    # FIXME -- according to the SCP spec, units for blfilt should be .01 Hz,
    # not .0001 Hz;  but files from Spacelabs carts have blfilt equal to 500
    # and clearly are diagnostic (0.05-100 Hz) bandwidth.
    cfprintf(dfile, "Bandwidth: %g-%d Hz\n", Float64(s.blfilt) * _SCP_BL_UNITS, s.lpfilt)
    cfprintf(dfile, "Filtering:")
    (s.filter_bit & 1) != 0 && cfprintf(dfile, " 60 Hz notch")
    (s.filter_bit & 2) != 0 && cfprintf(dfile, " 50 Hz notch")
    (s.filter_bit & 4) != 0 && cfprintf(dfile, " Artifact filter")
    (s.filter_bit & 8) != 0 && cfprintf(dfile, " Baseline filter")
    (s.filter_bit & 0xf0) != 0 && cfprintf(dfile, " <undefined>")
    s.filter_bit == 0 && cfprintf(dfile, " <not specified>")
    cfprintf(dfile, "\n\n")

    cfprintf(dfile, "RR interval: %d\n", s.rrint)
    cfprintf(dfile, "P onset: %d\n", s.pon)
    cfprintf(dfile, "P end: %d\n", s.pend)
    cfprintf(dfile, "QRS onset: %d\n", s.qrson)
    cfprintf(dfile, "QRS end: %d\n", s.qrsend)
    cfprintf(dfile, "T end: %d\n", s.tend)
    cfprintf(dfile, "P axis: %d\n", s.paxis)
    cfprintf(dfile, "QRS axis: %d\n", s.qrsaxis)
    cfprintf(dfile, "T axis: %d\n", s.taxis)
    fwrite(dfile, _scp_precgmeas(s))
    fclose(dfile)

    # Generate the key file. The patient's name and ID number should appear
    # only in this file (and in the debugging output, if enabled using -v).
    cfprintf(kfile, "%s key\n", _SCP_VERSION_STRING)
    cfprintf(kfile, "Record: %s (%s %s)\n", recname, s.recdate, s.rectime)
    cfprintf(kfile, "Name: %s\n", s.patient_name)
    cfprintf(kfile, "MRN: %s\n", s.patient_id)
    fclose(kfile)

    # If the -z option was selected, then for each signal:
    #  1. Calculate the median amplitude of the first 5000 samples in the
    #     signal
    #  2. If its final sample is zero, replace that sample with the previous
    #     one. This step eliminates transients that occur occasionally.
    #  3. Subtract the calculated median amplitude from all of the samples.
    # If the result after subtracting the median falls outside of the +/- 10
    # millivolt range (+/- 2000 A/D units), it is assumed to be invalid, and
    # the sample is stored with the value WFDB_INVALID_SAMPLE (-32768).
    if s.zflag != 0
        buf = s.zbuf                # (static in C: keeps earlier contents)
        for k in 0:max(s.nleads, 0)-1
            ns = _scp_nsampk(s, k)
            sig = _scp_sigp(s, k)
            sig === nothing && continue
            imax = Int(min(ns, UInt64(_SCP_ZWINDOW)))
            for i in 1:imax
                buf[i] = i <= length(sig) ? sig[i] : Int16(0)
            end
            sort!(view(buf, 1:imax))
            m = buf[imax÷2+1]
            last = ns - UInt64(1)   # (0-based; wraps if ns is 0)
            if 1 <= last < length(sig) && sig[last+1] == 0
                sig[last+1] = sig[last]
            end
            nz = min(s.nout, UInt64(length(sig)))
            for ii in 1:Int(nz)
                v = (Int32(sig[ii]) - Int32(m)) % Int16
                sig[ii] = -_SCP_ZLIMIT <= v <= _SCP_ZLIMIT ? v : _SCP_INVALID_SAMPLE
            end
        end
    end

    # Write the WFDB-format record if requested (-w option).
    s.wflag != 0 && _scp_write_wfdb_record(s)

    order = _scp_order(s)

    # Write the ECG in text form if requested (-v option).
    if tfile !== nothing
        if s.vflag > 1
            cfprintf(tfile, "samp#      I     II    III    aVR    aVF    aVL     V1     V2     V3     V4     V5     V6")
        end
        line = UInt8[]
        i = UInt64(0)
        while i < s.nout
            empty!(line)
            sprintf!(line, "%5d", i % Int32)
            for o in order
                sprintf!(line, "%7d", _scp_sample_at(s, o, i))
            end
            push!(line, UInt8('\n'))
            fwrite(tfile, line)
            i += 1
        end
        fclose(tfile)
    end

    # Finally, output the ECG in vector (binary) form.
    # ** FIXME ** This assumes that the sampling frequency is 500 Hz, that
    # nsamp[leadII] >= 5000, and that nsamp[all other leads] >= 1250.
    prolog = Vector{UInt8}(_SCP_VERSION_STRING)
    append!(prolog, b" signals\nRecord: ")
    append!(prolog, recname)
    append!(prolog, b" (")
    append!(prolog, s.recdate)
    push!(prolog, UInt8(' '))
    append!(prolog, s.rectime)
    append!(prolog, b")\n")
    if s.lflag != 0
        append!(prolog, b"Low-pass filtered\n")
        _scp_lowpass(s)
    end
    # (the rest of C's static buffer is zero)
    n = length(prolog)
    resize!(prolog, _SCP_PROLOG_SIZE)
    n < _SCP_PROLOG_SIZE && fill!(view(prolog, n+1:_SCP_PROLOG_SIZE), 0x00)
    fwrite(efile, prolog)
    # Three rows of four 1250-sample segments, then 5000 samples of lead II.
    for row in ((s.lead_i, s.avr, s.v1, s.v4), (s.lead_ii, s.avl, s.v2, s.v5),
                (s.lead_iii, s.avf, s.v3, s.v6))
        for (k, l) in enumerate(row)
            _scp_write_samples(efile, _scp_sigr(s, l), _SCP_ECG_SEGLEN * (k - 1), _SCP_ECG_SEGLEN)
        end
    end
    _scp_write_samples(efile, _scp_sigr(s, s.lead_ii), 0, Int(_SCP_MINSIGLEN))
    fclose(efile)
    1
end

# ---- sections (p: offset of the section header, len: section length) ----

function _scp_hexdump(s::_Scp, p::Int64, len::Int64)
    cprintf("Hex dump of data area:\n\n")
    for i in 0:len-1
        i % 16 == 0 && cprintf("\n%4d:  ", i % Int32)
        cprintf(" %2x", _scp_b(s, p + i))
    end
    cprintf("\n\n")
end

# True if the bytes at `off` are `id`.
function _scp_bytes_eq(s::_Scp, off::Int64, id::AbstractVector{UInt8})
    for k in eachindex(id)
        _scp_b(s, off + (k - 1)) == id[k] || return false
    end
    true
end

function _scp_section0(s::_Scp, p::Int64, len::Int64)
    if !_scp_bytes_eq(s, p + 10, b"SCPECG") && s.vflag != 0
        cprintf(" Warning: SCPECG identifier is missing in header\n")
    end
    p += _SCP_SECHDR_SIZE
    len -= _SCP_SECHDR_SIZE         # move to data area
    if len < 10
        s.vflag != 0 && cprintf(" Error: section 0 contains no data\n")
        return 0
    end
    while len > 0
        sec_id = _scp_get16(s, p)
        sec_len = _scp_get32(s, p + 2)
        sec_index = _scp_get32(s, p + 6)
        s.vflag != 0 && cprintf("  Section %2d:%6lld bytes beginning at byte %6lld\n",
                                sec_id % Int32, sec_len % Int64, sec_index % Int64)
        len -= 10
        p += 10
    end
    if len < 0
        s.vflag != 0 && cprintf(" Error: section 0 overlaps the next section\n")
        return 0
    end
    1
end

# Overwrite the len-1 bytes at p with c, and the next byte with NUL (len is
# a C unsigned short: 0 wraps around).
function _scp_censor!(s::_Scp, p::Int64, len::UInt16, c::UInt8)
    while true
        len -= 0x0001
        len == 0 && break
        _scp_inrange(s, p) && (s.data[p+1] = c)
        p += 1
    end
    _scp_inrange(s, p) && (s.data[p+1] = 0x00)
    nothing
end

# Append a byte as text (printable characters) or as an octal escape.
function _scp_putbyte!(o::Vector{UInt8}, c::UInt32)
    if 32 <= c < 127
        push!(o, c % UInt8)
    else
        sprintf!(o, "\\%03o", c)
    end
end

# Section 1 tags: name and value type (index: tag).
const _SCP_TAGNAMES = (
    "Last name", "First name", "Patient ID number", "Second last name", "Age",
    "Date of birth", "Height", "Weight", "Sex", "Race", "Drug",
    "Systolic blood pressure", "Diastolic blood pressure",
    "Diagnosis or referral indication", "ID of the acquiring device",
    "ID of the analyzing device", "Acquiring institution", "Analyzing institution",
    "Acquiring department", "Analyzing department", "Referring physician",
    "Latest confirming physician", "Technician", "Room", "Stat code (urgency)",
    "Date of acquisition", "Time of acquisition", "Baseline filter", "Low-pass filter",
    "Filter bit map", "Free text field (comments)", "Sequence number",
    "Medical history codes", "Electrode configuration code", "Time zone",
    "Free text medical history")
const _SCP_TAGTYPES = (
    _SCP_VT_TEXT, _SCP_VT_TEXT, _SCP_VT_TEXT, _SCP_VT_TEXT, _SCP_VT_B2B1,       #  0 -  4
    _SCP_VT_DATE, _SCP_VT_B2B1, _SCP_VT_B2B1, _SCP_VT_B1, _SCP_VT_B1,           #  5 -  9
    _SCP_VT_MIXED, _SCP_VT_B2, _SCP_VT_B2, _SCP_VT_TEXT, _SCP_VT_MIXED,         # 10 - 14
    _SCP_VT_MIXED, _SCP_VT_TEXT, _SCP_VT_TEXT, _SCP_VT_TEXT, _SCP_VT_TEXT,      # 15 - 19
    _SCP_VT_TEXT, _SCP_VT_TEXT, _SCP_VT_TEXT, _SCP_VT_TEXT, _SCP_VT_B1,         # 20 - 24
    _SCP_VT_DATE, _SCP_VT_TIME, _SCP_VT_B2, _SCP_VT_B2, _SCP_VT_B1,             # 25 - 29
    _SCP_VT_TEXT, _SCP_VT_TEXT, _SCP_VT_BN, _SCP_VT_B2, _SCP_VT_MIXED,          # 30 - 34
    _SCP_VT_TEXT)                                                               # 35
# Text fields censored by -a (the patient ID with `0', the others with `x').
const _SCP_CENSORED_TAGS = (0, 1, 2, 3, 16, 17, 18, 19, 20, 21, 22, 23)
const _SCP_TAG_PATIENT_ID = 2
const _SCP_TAG_END = 255            # tag 255 is the terminator

const _SCP_DEVICE_LABELS = (
    "Analyzing program revision number",
    "Serial number of acquisition device",
    "Acquisition device system software ID",
    "Acquisition device SCP implementation ID",
    "Manufacturer of acquisition device")

# Print the description of the acquiring device (tag 14, -v).
function _scp_print_device(s::_Scp, p::Int64)
    cprintf("   Institution number: %d\n", _scp_get16(s, p + 3) % Int32)
    cprintf("   Department number: %d\n", _scp_get16(s, p + 5) % Int32)
    cprintf("   Device ID: %d\n", _scp_get16(s, p + 7) % Int32)
    c = _scp_b(s, p + 9)
    cprintf("   Device type: %d (%s)\n", c % Int32,
            c == 0 ? "cart" : c == 1 ? "system or host" : "<error>")
    cprintf("   Manufacturer code: %d\n", _scp_b(s, p + 10) % Int32)
    cprintf("   Text model description: [%d]", _scp_b(s, p + 11) % Int32)
    cprintf("   SCP-ECG protocol revision number: %g\n", Float64(_scp_b(s, p + 17)) / 10.0)
    cprintf("   SCP-ECG protocol compatibility level: %d\n", _scp_b(s, p + 18) % Int32)
    cprintf("   Language support code: %d\n", _scp_b(s, p + 19) % Int32)
    cprintf("   Device capabilities: %d\n", _scp_b(s, p + 20) % Int32)
    c = _scp_b(s, p + 21)
    cprintf("   AC mains frequency environment: %d ", c % Int32)
    cprintf(c == 0 ? "(unspecified)\n" : c == 1 ? "(50 Hz)\n" : c == 2 ? "(60 Hz)\n" : "<error>")
    q = p + 39
    for label in _SCP_DEVICE_LABELS
        str = _scp_cstr(s, q)
        cprintf("   %s: [%s]\n", label, str)
        q += length(str) + 1
    end
end

# A string truncated to fit a C buffer of n characters.
_scp_trunc(x::Vector{UInt8}, n::Int) = length(x) > n ? x[1:n] : x

# The byte at `off` as a C signed char.
_scp_sb(s::_Scp, off::Int64) = (_scp_b(s, off) % UInt8) % Int8

function _scp_section1(s::_Scp, p::Int64, len::Int64)
    tpatid = trefdr = tcomments = tdate = ttime = Int64(-1)
    pyob = firstname = lastname = Int64(-1)
    p_save = p
    len_save = len
    v = s.vflag != 0
    a = s.aflag != 0

    p += _SCP_SECHDR_SIZE
    len -= _SCP_SECHDR_SIZE         # move to data area
    if len < 3
        v && cprintf(" Error: section 1 contains no data\n")
        return 0
    end

    while len > 2
        tag = _scp_b(s, p)
        tag == _SCP_TAG_END && break
        vlen = _scp_get16(s, p + 1)
        if vlen > len
            v && cprintf(" Error: tagged field overlaps next section\n")
            return 0
        end
        if tag < length(_SCP_TAGNAMES)
            v && cprintf("\n  %s\n", _SCP_TAGNAMES[tag+1])
            vtype = _SCP_TAGTYPES[tag+1]
        else
            v && cprintf("\n  <Undefined tag>\n")
            vtype = _SCP_VT_MIXED
        end
        if a && tag in _SCP_CENSORED_TAGS
            _scp_censor!(s, p + 3, vlen % UInt16,
                         tag == _SCP_TAG_PATIENT_ID ? UInt8('0') : UInt8('x'))
        end
        if tag == 0
            lastname = p + 3
        elseif tag == 1
            firstname = p + 3
        elseif tag == _SCP_TAG_PATIENT_ID
            tpatid = p + 3
        elseif tag == 4
            s.age = _scp_get16(s, p + 3) % Int32    # FIXME
            # censor age if over 90
            a && s.age > _SCP_MAXAGE && _scp_put16!(s, UInt32(_SCP_MAXAGE), p + 3)
        elseif tag == 5
            if a
                pyob = p + 3            # save pointer to year of birth
                _scp_put16!(s, _SCP_CENSORED_DATE, p + 5)   # censor month and day
            end
        elseif tag == 8
            s.sex = _scp_b(s, p + 3) % Int32
        elseif tag == 14
            s.tdevid = _scp_get16(s, p + 7) % Int32
            s.tinst = _scp_get16(s, p + 3) % Int32  # institution #
            s.tdept = _scp_get16(s, p + 5) % Int32  # department #
            v && _scp_print_device(s, p)
        elseif tag == 16
            s.inst = p + 3
        elseif tag == 18
            s.dept = p + 3
        elseif tag == 20
            trefdr = p + 3
        elseif tag == 25
            tdate = p + 3
            # (the pointer to the year of acquisition is saved, but never used)
            a && _scp_put16!(s, _SCP_CENSORED_DATE, p + 5)  # censor month and day
        elseif tag == 26
            ttime = p + 3
        elseif tag == 27
            s.blfilt = _scp_get16(s, p + 3) % Int32
        elseif tag == 28
            s.lpfilt = _scp_get16(s, p + 3) % Int32
        elseif tag == 29
            s.filter_bit = _scp_b(s, p + 3) % Int32
        elseif tag == 30
            tcomments = p + 3
        end
        v && cprintf("   Tag%3d (%2d bytes): ", tag % Int32, vlen % Int32)
        p += 3
        len -= Int64(vlen) + 3
        if vlen == 0
            v && cprintf("<not defined>\n")
            continue
        end
        if vtype == _SCP_VT_TEXT
            v && cprintf("[%*s]", (vlen % Int32) - Int32(1), _scp_cstr(s, p))
            p += vlen
        elseif vtype == _SCP_VT_DATE
            if vlen != 4
                v && cprintf("  Error: incorrect date format (%d bytes)\n", vlen % Int32)
            elseif v
                cprintf("%4d/%02d/%02d", _scp_get16(s, p) % Int32, _scp_b(s, p + 2) % Int32,
                        _scp_b(s, p + 3) % Int32)
            end
            p += vlen
        elseif vtype == _SCP_VT_TIME
            if vlen != 3
                v && cprintf("  Error: incorrect time format (%d bytes)\n", vlen % Int32)
            elseif v
                cprintf("%02d:%02d:%02d", _scp_b(s, p) % Int32, _scp_b(s, p + 1) % Int32,
                        _scp_b(s, p + 2) % Int32)
            end
            p += vlen
        elseif vtype == _SCP_VT_B1
            if vlen != 1
                v && cprintf("  Error: incorrect format (%d bytes instead of 1)\n", vlen % Int32)
            elseif v
                cprintf("%d", _scp_b(s, p) % Int32)
            end
            p += vlen
        elseif vtype == _SCP_VT_B2
            if vlen != 2
                v && cprintf("  Error: incorrect format (%d bytes instead of 2)\n", vlen % Int32)
            elseif v
                cprintf("%d", _scp_get16(s, p) % Int32)
            end
            p += vlen
        elseif vtype == _SCP_VT_B2B1
            if vlen != 3
                v && cprintf("  Error: incorrect format (%d bytes instead of 3)\n", vlen % Int32)
            elseif v
                cprintf("%d (code %d)", _scp_get16(s, p) % Int32, _scp_b(s, p + 2) % Int32)
            end
            p += vlen
        elseif vtype == _SCP_VT_BN
            while vlen > 0
                vlen -= 1
                v && cprintf("%d, ", _scp_b(s, p) % Int32)
                p += 1
            end
        else                            # _SCP_VT_MIXED
            if v
                o = UInt8[]
                while vlen > 0
                    vlen -= 1
                    _scp_putbyte!(o, _scp_b(s, p))
                    p += 1
                end
                push!(o, UInt8('\n'))
                cout_write(o)
            else
                p += vlen
            end
        end
    end

    # (tdate and ttime are pointers to signed char)
    if tdate >= 0
        mon = Int32(_scp_sb(s, tdate + 2)) - Int32(1)
        s.recdate = cformat("%d %s %d", _scp_sb(s, tdate + 3),
                            0 <= mon < length(_SCP_MONTH) ? _SCP_MONTH[mon+1] : b"???",
                            _scp_get16(s, tdate) % Int32)
    end
    if ttime >= 0
        s.rectime = cformat("%02d:%02d:%02d", _scp_sb(s, ttime), _scp_sb(s, ttime + 1),
                            _scp_sb(s, ttime + 2))
    end
    slast = lastname < 0 ? Vector{UInt8}(b"<last name missing>") : _scp_cstr(s, lastname)
    sfirst = firstname < 0 ? Vector{UInt8}(b"<first name missing>") : _scp_cstr(s, firstname)
    if length(slast) + length(sfirst) < _SCP_NAMEBUF - 3
        s.patient_name = append!(append!(copy(slast), b", "), sfirst)
    else
        ceprintf("Patient name (%s, %s) is too long\n", slast, sfirst)
        s.patient_name = Vector{UInt8}(b"Name not available -- too long")
    end
    s.patient_id = _scp_trunc(tpatid < 0 ? Vector{UInt8}(b"<patient ID missing>") :
                              _scp_cstr(s, tpatid), _SCP_IDBUF)
    s.referring_dr = _scp_trunc(trefdr < 0 ? Vector{UInt8}(b"<referring physician missing>") :
                                _scp_cstr(s, trefdr), _SCP_DRBUF)
    s.comments = _scp_trunc(tcomments < 0 ? Vector{UInt8}(b"<comments missing>") :
                            _scp_cstr(s, tcomments), _SCP_COMMENTBUF)

    _scp_b(s, p) != _SCP_TAG_END && v && cprintf(" Error: header terminator (tag 255) is missing\n")
    # (tpatid cannot be NULL here, so that error is never reported)
    if (s.tdevid == -1 || s.tinst == -1 || s.tdept == -1) && v
        cprintf(" Error: device ID number (tag 14) is missing\n")
    end
    tdate < 0 && v && cprintf(" Error: date of acquisition (tag 25) is missing\n")
    ttime < 0 && v && cprintf(" Error: time of acquisition (tag 26) is missing\n")

    if a && pyob >= 0
        # (the censored year of birth is computed but never stored)
        # Recalculate the CRC for this section.
        crc = _scp_getcrc(s, p_save + 2, len_save - 2)
        _scp_put16!(s, UInt32(crc), p_save)
    end

    (_scp_b(s, p) != _SCP_TAG_END || s.tdevid == -1 || tdate < 0 || ttime < 0) && return 0
    1
end

function _scp_section2(s::_Scp, p::Int64, len::Int64)
    p += _SCP_SECHDR_SIZE
    len -= _SCP_SECHDR_SIZE         # move to data area
    if len < 2
        s.vflag != 0 && cprintf("  Error: section 2 contains no data\n")
        return 0
    end
    if _scp_get16(s, p) == _SCP_STD_HUFFMAN
        s.vflag != 0 && cprintf("  Using standard Huffman table only\n")
    elseif s.vflag != 0
        cprintf("  Number of Huffman tables defined: %d\n", _scp_get16(s, p) % Int32)
        cprintf("  Number of code structures in table 1: %d\n", _scp_get16(s, p + 2) % Int32)
        # ** more to do here **
    end
    1
end

# Record the (0-based) index of the lead with the given lead ID.
function _scp_set_lead!(s::_Scp, id::Int32, idx::Int16)
    if id == _SCP_ID_I
        s.lead_i = idx
    elseif id == _SCP_ID_II
        s.lead_ii = idx
    elseif id == _SCP_ID_III
        s.lead_iii = idx
    elseif id == _SCP_ID_AVR
        s.avr = idx
    elseif id == _SCP_ID_AVF
        s.avf = idx
    elseif id == _SCP_ID_AVL
        s.avl = idx
    elseif id == _SCP_ID_V1
        s.v1 = idx
    elseif id == _SCP_ID_V1 + 1
        s.v2 = idx
    elseif id == _SCP_ID_V1 + 2
        s.v3 = idx
    elseif id == _SCP_ID_V1 + 3
        s.v4 = idx
    elseif id == _SCP_ID_V1 + 4
        s.v5 = idx
    elseif id == _SCP_ID_V6
        s.v6 = idx
    end
    nothing
end

const _SCP_LEADDEF_SIZE = 9         # bytes per lead in section 3
const _SCP_NEXTRA = 4               # extra signals calculated later (III, aVR, aVL, aVF)

function _scp_section3(s::_Scp, p::Int64, len::Int64)
    i = Int32(0)
    nsmax = Int32(0)
    v = s.vflag != 0

    p += _SCP_SECHDR_SIZE
    len -= _SCP_SECHDR_SIZE         # move to data area
    if len < 2
        v && cprintf("  Error: section3 contains no data\n")
        return 0
    end

    s.nleads = _scp_b(s, p) % Int32
    p += 1
    v && cprintf("  Number of leads: %d\n", s.nleads)
    len -= 1

    s.nsamp = zeros(UInt64, s.nleads + _SCP_NEXTRA)

    v && cprintf("  Flag byte: %xH\n", _scp_b(s, p))
    len -= 1
    if (_scp_b(s, p) & 1) != 0
        v && cprintf("   Reference beat subtraction used for compression\n")
    else
        v && cprintf("   Reference beat subtraction not used for compression\n")
    end
    if (_scp_b(s, p) & 4) != 0
        v && cprintf("   All leads recorded simultaneously\n")
    else
        v && cprintf("   %d leads recorded simultaneously\n", ((_scp_b(s, p) >> 3) & 0xf) % Int32)
    end
    p += 1

    while len >= _SCP_LEADDEF_SIZE
        j = _scp_b(s, p + 8) % Int32
        if j < _SCP_NLEADNAMES
            v && cprintf("  %s", _SCP_LEADNAME[j+1])
            _scp_set_lead!(s, j, i % Int16)
        elseif j < _SCP_RESERVED_LEADS
            v && cprintf("  <Reserved lead>")
        else
            v && cprintf("  <Manufacturer-defined lead>")
        end
        v && cprintf(": ID %d, samples %llu to %llu\n", j, _scp_get32(s, p), _scp_get32(s, p + 4))
        ns = _scp_get32(s, p + 4) - _scp_get32(s, p) + UInt64(1)
        if i < length(s.nsamp)
            s.nsamp[i+1] = ns
        else
            push!(s.nsamp, ns)
        end
        i += Int32(1)
        p += _SCP_LEADDEF_SIZE
        len -= _SCP_LEADDEF_SIZE
    end

    # allocate space for 4 extra signals that will be calculated later, and
    # for a NULL pointer to signal the end of the array
    s.ecg = _ScpSigs(nothing, s.nleads + _SCP_NEXTRA + 1)
    s.have_ecg = true

    for k in 1:s.nleads+_SCP_NEXTRA
        if k - 1 >= s.nleads
            s.nsamp[k] = Int64(nsmax) % UInt64
        elseif s.nsamp[k] > Int64(nsmax) % UInt64
            nsmax = s.nsamp[k] % Int32
        end
        s.nsamp[k] < 1 && (s.nsamp[k] = 1)
        sig = _scp_newsig(s.nsamp[k])
        if sig === nothing
            v && cprintf("  Error: too many (%d) leads\n", s.nleads)
            return 0
        end
        s.ecg[k] = sig
    end

    len < 0 && return 0
    1
end

const _SCP_SUBZONE_SIZE = 14        # bytes per subtraction zone in section 4
const _SCP_QRSLOC_SIZE = 8          # bytes per QRS location in section 4
const _SCP_NOZONE_TYPE = Int16(9)   # type given to type-0 beats without a zone

function _scp_section4(s::_Scp, p::Int64, len::Int64)
    stat = 1
    v = s.vflag != 0

    p += _SCP_SECHDR_SIZE
    len -= _SCP_SECHDR_SIZE         # move to data area
    if len < 6
        v && cprintf("  Error: section 4 contains no data\n")
        return 0
    end
    s.rblenms = _scp_get16(s, p)
    s.fc_m = _scp_get16(s, p + 2) % Int32
    s.nqrs = _scp_get16(s, p + 4) % Int32
    if v
        cprintf("  Length of reference beat type 0 data: %lld msec\n", s.rblenms)
        cprintf("  Sample # of fiducial relative to start of ref beat type 0: %d\n", s.fc_m)
        cprintf("  Number of QRS complexes in the entire record: %d\n", s.nqrs)
    end

    s.nqrs < 1 && return 0          # no beats -- nothing else to do here

    p += 6
    len -= 6
    s.subz = Vector{Union{Nothing,_ScpSubzone}}(nothing, s.nqrs)

    if len >= Int64(s.nqrs) * _SCP_SUBZONE_SIZE
        v && cprintf("  Reference beat subtraction zones:\n")
        i = Int32(0)
        while i < s.nqrs && len >= _SCP_SUBZONE_SIZE
            ztype = _scp_get16(s, p) % Int16
            t0 = _scp_get32(s, p + 2) % Int64
            t1 = _scp_get32(s, p + 6) % Int64
            t2 = _scp_get32(s, p + 10) % Int64
            ztype == 0 && t2 == 0 && (ztype = _SCP_NOZONE_TYPE)
            s.subz[i+1] = _ScpSubzone(ztype, t0, t1, t2)
            if v
                cprintf("   %2d  Type: %2d  start: %7lld  fiducial: %7lld  end: %7lld\n",
                        i + Int32(1), ztype, t0, t1, t2)
                if ztype != 0 && (t0 != 0 || t2 != 0)
                    cprintf("  Error: start and end should be zero for beats of non-zero types\n")
                end
            end
            p += _SCP_SUBZONE_SIZE
            len -= _SCP_SUBZONE_SIZE
            i += Int32(1)
        end
    else
        v && cprintf("  Error: reference beat subtraction zones are missing\n")
        stat = 0
    end
    if len >= Int64(s.nqrs) * _SCP_QRSLOC_SIZE
        v && cprintf("  QRS locations:\n")
        for i in 1:s.nqrs
            v && cprintf("   %2d  start: %7llu  end: %7llu\n", i % Int32, _scp_get32(s, p),
                         _scp_get32(s, p + 4))
            p += _SCP_QRSLOC_SIZE
        end
    else
        v && cprintf("  Error: QRS locations are missing\n")
        stat = 0
    end
    stat
end

function _scp_section5(s::_Scp, p::Int64, len::Int64)
    p += _SCP_SECHDR_SIZE
    len -= _SCP_SECHDR_SIZE         # move to data area
    if len <= 0
        s.vflag != 0 && cprintf(" Error: section 5 contains no data\n")
        return 0
    end

    # Calculate length of template in samples (double arithmetic, as C: a
    # zero sample interval gives an infinite or NaN length)
    x = Float64(s.rblenms) * 1000.0
    x /= Float64(_scp_get16(s, p + 2))
    s.rblen = d2l(x)

    s.refbeat = _ScpSigs(nothing, max(s.nleads + 1, 0))
    for i in 1:max(s.nleads, 0)
        if s.rblen < 0 || s.rblen % UInt64 > _SCP_MAXALLOC
            ceprintf("  Error: too many (%d) leads\n", s.nleads)
            return 0
        end
        s.refbeat[i] = zeros(Int16, s.rblen)
    end
    _scp_huffdecode(s, p, len, 5)
end

# Read bits from the input buffer, beginning ibits bits from the MSB of the
# byte at p, until a Huffman-encoded value is recognized. Returns the number
# of bits read and the decoded value (x, unchanged, after an error).
function _scp_getbits(s::_Scp, x::Int16, p::Int64, ibits::UInt64)
    bitbuffer = 0x0000
    nbits = UInt32(0)               # number of bits read on this call
    while true
        bitbuffer <<= 1             # make room for a bit
        if (ibits & 7) == 0         # once every 8 bits ... get 8
            s.w = _scp_b(s, p + (ibits ÷ 8) % Int64) % UInt8
        end
        # copy next bit from w into bitbuffer ...
        (s.w & 0x80) != 0 && (bitbuffer |= 0x0001)
        s.w <<= 1                   # ... and discard it from w
        ibits += 1
        nbits += 1
        # check bitbuffer against all of the Huffman table entries
        for (pattern, suffixbits, basevalue) in _SCP_HTDEFAULT
            bitbuffer == pattern || continue
            # we have a match
            j = Int32(suffixbits)
            if j == 0
                x = basevalue
            else
                # j is the number of additional bits we need; as above, get
                # 8 more bits if needed
                (ibits & 7) == 0 && (s.w = _scp_b(s, p + (ibits ÷ 8) % Int64) % UInt8)
                # Get the first (most significant) bit of the value; if
                # it's a 1, sign-extend it.
                if (s.w & 0x80) != 0
                    val = Int16(1)
                    for _ in j:_SCP_HUFF_WORDBITS-1
                        val = (val << 1) | Int16(1)     # shift in another 1
                    end
                else
                    val = Int16(0)
                end
                s.w <<= 1
                ibits += 1
                nbits += 1
                j -= Int32(1)
                while j > 0
                    val <<= 1
                    (ibits & 7) == 0 && (s.w = _scp_b(s, p + (ibits ÷ 8) % Int64) % UInt8)
                    (s.w & 0x80) != 0 && (val |= Int16(1))
                    s.w <<= 1
                    j -= Int32(1)
                    ibits += 1
                    nbits += 1
                end
                x = val
            end
            return (UInt64(nbits), x)
        end
        nbits >= _SCP_HUFF_MAXBITS && break
    end
    s.vflag != 0 && cprintf("Huffman encoding error\n")
    (_SCP_HUFF_ERROR, x)
end

function _scp_section6(s::_Scp, p::Int64, len::Int64)
    p += _SCP_SECHDR_SIZE
    len -= _SCP_SECHDR_SIZE         # move to data area
    if len <= 6
        s.vflag != 0 && cprintf(" Error: section 6 contains no data\n")
        return 0
    end
    _scp_huffdecode(s, p, len, 6)
end

_scp_plural(d::Integer) = d == 1 ? "" : "s"

function _scp_huffdecode(s::_Scp, p::Int64, len::Int64, section::Int)
    v = s.vflag != 0
    tleadlen = UInt64(0)
    g = Float64(_scp_get16(s, p))

    if section == 5
        s.gref = g / _SCP_NV_PER_UNIT
    else
        s.gres = g / _SCP_NV_PER_UNIT
    end
    v && cprintf("  Amplitude value multiplier: %g nanovolts per unit\n", g)
    sampint = _scp_get16(s, p + 2) % Int32
    v && cprintf("  Sample time interval: %d microseconds\n", sampint)
    if sampint > 0
        if s.sfreq > 0.0 && s.sfreq != _SCP_US_PER_S / Float64(sampint)
            cprintf("Warning: section 5 and 6 sample intervals don't match")
        end
        # FIXME: If this ever happens, we need to redo the reconstruction
        # code in main()
        s.sfreq = _SCP_US_PER_S / Float64(sampint)
    elseif wfdbx_get_legacy() != 0  # wfdb-x: as in the C program
        cprintf("Error: sampling frequency not specified;  assuming 500 Hz\n")
        s.sfreq = _SCP_LEGACY_FREQ
    else                            # wfdb-x: the C program assumed 500 Hz
        cprintf("Error: sampling frequency not specified\n")
    end
    # (the encoding type is read from the high byte of the sample interval:
    # see docs/KNOWN_C_BEHAVIORS.md)
    e = _scp_b(s, p + 3)
    v && cprintf("  Encoding type: %d ", e % Int32)
    if e == 0
        v && cprintf("(amplitudes)\n")
    elseif e == 1
        v && cprintf("(first differences)\n")
    elseif e == 2
        v && cprintf("(second differences)\n")
    else
        v && cprintf("<undefined, assuming second differences>\n")
    end
    enctype = min(e, UInt32(2))     # 0: amplitudes, 1: first, 2: second differences
    if section == 6
        c = _scp_b(s, p + 4)
        v && cprintf("  Compression type: %d ", c % Int32)
        if c == 0
            v && cprintf("(non-bimodal)\n")
        elseif c == 1
            v && cprintf("(bimodal)\n")
        else
            v && cprintf("<undefined, assuming bimodal>\n")
        end
    end
    p += 6
    len -= 6

    if s.nleads < 0
        v && cprintf("  Error: number of leads undefined -- section 3 missing or out of order\n")
        return 0
    end
    if s.nleads == 0
        v && cprintf("  Error: no leads recorded\n")
        return 0
    end
    nleads = Int(s.nleads)
    leadlen = zeros(UInt64, nleads)
    for i in 1:nleads
        leadlen[i] = _scp_get16(s, p)
        tleadlen += leadlen[i]
        v && cprintf("  Lead %d:%5llu bytes\n", (i - 1) % Int32, leadlen[i])
        p += 2
        len -= 2
    end

    ulen = len % UInt64
    if ulen < tleadlen
        if v
            d = tleadlen - ulen
            cprintf("  Error: %llu data byte%s missing from section %d\n", d, _scp_plural(d),
                    section % Int32)
        end
        return 0
    elseif ulen > ((tleadlen + 1) & ~UInt64(1))
        # the expression above rounds tleadlen up to an even number
        if v
            d = ulen - tleadlen
            cprintf("  Warning: %llu extra byte%s in section %d\n", d, _scp_plural(d),
                    section % Int32)
        end
    end

    for i in 1:nleads
        if v
            cprintf("  Lead %d data\n", (i - 1) % Int32)
            for j in 0:9
                cprintf(" %02x", _scp_b(s, p + j))
            end
            cprintf("\n")
        end
        s.hxxx = 0
        s.hxx = 0
        if section == 6
            explen = s.nsamp[i] % Int32
            gain = s.gres
            sigs = s.ecg
        else
            explen = s.rblen % Int32
            gain = s.gref
            sigs = s.refbeat
        end
        dest = i <= length(sigs) ? sigs[i] : nothing
        tbits = leadlen[i] * UInt64(8)
        ibits = UInt64(0)
        j = Int32(0)
        while j < explen && ibits < tbits
            nb, x = _scp_getbits(s, s.hx, p, ibits)
            ibits += nb
            s.hx = x
            if j == 0
                s.hxx = x
                s.hxxx = x
            elseif j == 1
                s.hdx = x - s.hxxx
                s.hxxx = x
                s.hxx += x
            else
                s.hdx += x
                s.hxxx += s.hdx
                s.hxx += x
            end
            s.hxout = enctype == 0 ? x : enctype == 1 ? s.hxx : s.hxxx
            val = _scp_d2s(Float64(s.hxout) * gain)
            dest !== nothing && j < length(dest) && (dest[j+1] = val)
            s.vflag > 1 && cprintf("   %5d %5d %5d %5d\n", j, x, s.hxx, s.hxxx)
            j += Int32(1)
        end
        if j < explen && v
            d = leadlen[i] - (Int64(j) % UInt64)
            cprintf("   Error: %lld sample%s missing in lead %d\n", d % Int64, _scp_plural(d),
                    (i - 1) % Int32)
        end
        if ibits < tbits && v
            d = tbits - ibits
            cprintf("   Warning: %lld extra bit%s in lead %d\n", d % Int64, _scp_plural(d),
                    (i - 1) % Int32)
        end
        p += leadlen[i] % Int64
        v && cprintf("\n")
    end
    1
end

const _SCP_MEASBLOCK_SIZE = 16      # bytes per measurement block in section 7
const _SCP_SPIKE_SIZE = 4           # bytes per pacemaker spike measurement
const _SCP_SPIKEINFO_SIZE = 6       # bytes per pacemaker spike information
const _SCP_SPIKEDATA_SIZE = 10      # SPIKE_SIZE + SPIKEINFO_SIZE

function _scp_axis(label::String, n::Int16)
    if n == _SCP_UNDEF_AXIS
        cprintf("    %s undefined\n", label)
    else
        cprintf("    %s %d degrees\n", label, n)
    end
end

function _scp_section7(s::_Scp, p::Int64, len::Int64)
    v = s.vflag != 0
    p += _SCP_SECHDR_SIZE
    len -= _SCP_SECHDR_SIZE         # move to data area
    if len <= 0
        v && cprintf(" Error: section 7 contains no data\n")
        return 0
    end

    s.xflag != 0 && v && _scp_hexdump(s, p, len)

    if len < 20                     # there isn't enough room left for measurements
        v && cprintf(" Error: section 7 is too short (len = %lld)\n", len)
        return 0
    end

    s.rrint = _scp_get16(s, p + 2) % Int32

    # get P onset, etc from first measurement block
    q = p + 6
    s.pon = _scp_get16(s, q) % Int32
    s.pend = _scp_get16(s, q + 2) % Int32
    s.qrson = _scp_get16(s, q + 4) % Int32
    s.qrsend = _scp_get16(s, q + 6) % Int32
    s.tend = _scp_get16(s, q + 8) % Int32
    s.paxis = _scp_get16(s, q + 10) % Int16
    s.qrsaxis = _scp_get16(s, q + 12) % Int16
    s.taxis = _scp_get16(s, q + 14) % Int16

    nmb = _scp_b(s, p)
    nps = _scp_b(s, p + 1)
    sec7qrs_offset = (6 + _SCP_MEASBLOCK_SIZE * nmb + _SCP_SPIKEDATA_SIZE * nps) % Int16
    sec7qrs_offset > len && (sec7qrs_offset = len % Int16)
    if sec7qrs_offset > len
        v && cprintf(" Error: section 7 is too short (nmb = %d, nps = %d)\n", nmb % Int32,
                     nps % Int32)
        return 0
    end

    sec7qrs = _scp_get16(s, p + sec7qrs_offset) & 0xff

    if v
        cprintf(" QRS complexes measured: %d\n", sec7qrs % Int32)
        cprintf(" Measurement blocks: %d\n", nmb % Int32)
        if nmb == sec7qrs + 1
            cprintf("  (First measurement block contains measurements for reference beat type 0;\n   Others contain measurements for each individual beat)\n")
        else
            cprintf("  (Measurements for each reference beat type)\n")
        end
        cprintf("  Number of measurement blocks: %d\n", nmb % Int32)
        cprintf("  Number of pacemaker spikes: %d\n", nps % Int32)
        cprintf("  Mean RR interval: %d ms\n", s.rrint)
        cprintf("  Mean PP interval: %d ms\n", _scp_get16(s, p + 4) % Int32)
        q = p + 6
        for i in Int32(0):Int32(nmb)-Int32(1)
            cprintf("   Block %d\n", i)
            cprintf("    P onset:   %d ms\n", _scp_get16(s, q) % Int32)
            cprintf("    P end:     %d ms\n", _scp_get16(s, q + 2) % Int32)
            cprintf("    QRS onset: %d ms\n", _scp_get16(s, q + 4) % Int32)
            cprintf("    QRS  end:  %d ms\n", _scp_get16(s, q + 6) % Int32)
            cprintf("    T end:     %d ms\n", _scp_get16(s, q + 8) % Int32)
            _scp_axis("P axis:   ", _scp_get16(s, q + 10) % Int16)
            _scp_axis("QRS axis: ", _scp_get16(s, q + 12) % Int16)
            _scp_axis("T axis:   ", _scp_get16(s, q + 14) % Int16)
            q += _SCP_MEASBLOCK_SIZE
        end
        nps > 0 && cprintf(" Pacemaker spike measurement data\n")
        r = q + Int64(nps) * _SCP_SPIKE_SIZE
        for i in Int32(0):Int32(nps)-Int32(1)
            cprintf("Spike %d: %u ms, %d microvolts ", i, _scp_get16(s, q),
                    _scp_get16(s, q + 2) % Int32)
            c = _scp_b(s, r)
            if c == 0
                cprintf("(unknown spike type, ")
            elseif c == 1
                cprintf("(triggers neither P nor QRS, ")
            elseif c == 2
                cprintf("(triggers a QRS, ")
            elseif c == 3
                cprintf("(triggers a P, ")
            else
                cprintf("(spike type %d, ", c % Int32)
            end
            c = _scp_b(s, r + 1)
            if c == 0
                cprintf("source unknown, ")
            elseif c == 1
                cprintf("internal, ")
            elseif c == 2
                cprintf("external, ")
            else
                cprintf("source type %d, ", c % Int32)
            end
            n = _scp_get16(s, r + 2) % Int16
            if n == 0
                cprintf(" not linked to a QRS, ")
            else
                cprintf(" linked to QRS #%d, ", n)
            end
            n = _scp_get16(s, r + 4) % Int16
            if n == 0
                cprintf("width unknown)\n")
            else
                cprintf("%d microseconds\n)", n)
            end
            q += _SCP_SPIKE_SIZE
            r += _SCP_SPIKEINFO_SIZE
        end

        # The next part doesn't seem to be right ...
        cprintf(" <!> sec7qrs = <%d>\n", sec7qrs % Int32)
        sec7qrs > 0 && cprintf(" QRS type information (%d beats)\n", _scp_get16(s, r) % Int32)
        q = r + 2
        for i in Int32(0):Int32(sec7qrs)-Int32(1)
            cprintf("  QRS %d: reference beat type %d\n", i, _scp_b(s, q) % Int32)
            q += 1
        end

        cprintf("%lld bytes remaining in section 7\n", len - (q - p))
        o = UInt8[]
        while q < p + len
            # get16(q) reads one byte past the end of the section at the last
            # iteration (read as 0 beyond the end of the data)
            sprintf!(o, " %5d [%3d]", _scp_get16(s, q) % Int32, _scp_b(s, q) % Int32)
            q += 1
        end
        push!(o, UInt8('\n'))
        cout_write(o)
    end

    # ** more to do here **
    1
end

function _scp_section8(s::_Scp, p::Int64, len::Int64)
    v = s.vflag != 0
    p += _SCP_SECHDR_SIZE
    len -= _SCP_SECHDR_SIZE         # move to data area
    if len <= 0
        v && cprintf(" Error: section 8 contains no data\n")
        return 0
    end

    if v
        c = _scp_b(s, p)
        cprintf(" Status: %d ", c % Int32)
        cprintf(c == 0 ? "(original report, not confirmed)\n" :
                c == 1 ? "(confirmed report)\n" :
                c == 2 ? "(overread report, but not confirmed)\n" : "<undefined>\n")
        cprintf(" Date: %4d/%02d/%02d\n", _scp_get16(s, p + 1) % Int32,
                _scp_b(s, p + 3) % Int32, _scp_b(s, p + 4) % Int32)
        cprintf(" Time: %02d:%02d:%02d\n", _scp_b(s, p + 5) % Int32,
                _scp_b(s, p + 6) % Int32, _scp_b(s, p + 7) % Int32)
    end
    n = _scp_b(s, p + 8) % Int32
    s.stmnts = n
    v && cprintf(" Number of statements: %d\n", n)
    p += 9
    len -= 9

    i = Int32(0)
    while i < n && len > 2
        s.report[i+1] = p + 3
        slen = _scp_get16(s, p + 1) % Int32
        if v
            cprintf("  Statement %2d: (%d bytes)\n", _scp_b(s, p) % Int32, slen)
            cprintf("   [%*s]\n", slen, _scp_cstr(s, p + 3))
        end
        p += slen + 3
        len -= slen + 3
        i += Int32(1)
    end
    if i < n
        v && cprintf("  Error: data missing in section 8\n")
        return 0
    end
    1
end

function _scp_section9(s::_Scp, p::Int64, len::Int64)
    p += _SCP_SECHDR_SIZE
    len -= _SCP_SECHDR_SIZE         # move to data area
    if len <= 0
        s.vflag != 0 && cprintf(" Error: section 9 contains no data\n")
        return 0
    end
    # FIXME: more to do here
    if s.vflag != 0
        o = Vector{UInt8}(b"  Data:\n   ")
        while len > 0
            len -= 1
            _scp_putbyte!(o, _scp_b(s, p))
            p += 1
        end
        push!(o, UInt8('\n'))
        cout_write(o)
    end
    1
end

function _scp_section10(s::_Scp, p::Int64, len::Int64)
    p += _SCP_SECHDR_SIZE
    len -= _SCP_SECHDR_SIZE         # move to data area
    if len <= 0
        s.vflag != 0 && cprintf(" Error: section 10 contains no data\n")
        return 0
    end

    # Section 10 data area begins with a 4-byte header. The first 2 bytes
    # specify the number of leads for which measurements are stored.
    s.nsecleads = _scp_get16(s, p) % Int32
    # FIXME: the draft standard doesn't say what the next 2 bytes are -- so
    # they are ignored here.

    # Fill the array of structures.
    meas = zeros(Int16, _SCP_NMEAS, s.nsecleads)
    p += 4
    for k in 1:s.nsecleads
        for f in 1:_SCP_NMEAS
            meas[f, k] = _scp_get16(s, p + 2 * (f - 1)) % Int16
        end
        p += Int64(meas[_SCP_M_VLEN+1, k]) + 4
    end
    s.ecgmeas = meas

    if s.vflag != 0
        cprintf(" Results for %d leads\n", s.nsecleads)
        cout_write(_scp_precgmeas(s))
    end
    1
end

function _scp_section11(s::_Scp, p::Int64, len::Int64)
    len -= _SCP_SECHDR_SIZE         # move to data area
    if len <= 0
        s.vflag != 0 && cprintf(" Error: section 11 contains no data\n")
        return 0
    end
    # ** more to do here **
    1
end

function _scp_section(s::_Scp, id::Int, p::Int64, len::Int64)
    id == 0 ? _scp_section0(s, p, len) :
    id == 1 ? _scp_section1(s, p, len) :
    id == 2 ? _scp_section2(s, p, len) :
    id == 3 ? _scp_section3(s, p, len) :
    id == 4 ? _scp_section4(s, p, len) :
    id == 5 ? _scp_section5(s, p, len) :
    id == 6 ? _scp_section6(s, p, len) :
    id == 7 ? _scp_section7(s, p, len) :
    id == 8 ? _scp_section8(s, p, len) :
    id == 9 ? _scp_section9(s, p, len) :
    id == 10 ? _scp_section10(s, p, len) : _scp_section11(s, p, len)
end

# ---- reconstruction of the ECG ----

# Low-pass filter the residuals (with -t, they are replaced by zeros), except
# within the protected zones of the reference beats.
function _scp_filter_residuals(s::_Scp)
    for i in 1:max(s.nleads, 0)
        n = _scp_nsampk(s, i - 1)
        inp = i <= length(s.ecg) ? s.ecg[i] : nothing
        inp === nothing && continue
        out = _scp_newsig(n)
        if out === nothing
            ceprintf("Insufficient memory for filtering\n")
            break
        end
        if s.tflag == 0             # true unless -t debugging option was given
            out[1] = inp[1]
            j = UInt64(1)           # (0-based)
            while j + 1 < n
                t = Int32(inp[j]) + Int32(inp[j+1]) + Int32(inp[j+2])
                out[j+1] = t > 0 ? ((t + Int32(2)) ÷ Int32(3)) % Int16 :
                           t < 0 ? ((t - Int32(2)) ÷ Int32(3)) % Int16 : Int16(0)
                j += 1
            end
            out[j+1] = inp[j+1]
            for k in 1:max(s.nqrs, 0)
                z = k <= length(s.subz) ? s.subz[k] : nothing
                (z === nothing || z.ztype != 0) && continue
                # restore unfiltered samples within protected zones and
                # adjacent samples on either end of protected zones
                j0 = max(z.t0 - 1, 0)
                j1 = min(z.t2 + 2, length(out))
                for jx in j0+1:j1
                    out[jx] = inp[jx]
                end
            end
        end
        s.ecg[i] = out
    end
end

# Add the reference beats back into the residuals to obtain the raw ECG.
function _scp_add_refbeats(s::_Scp)
    for k in 1:max(s.nqrs, 0)
        z = k <= length(s.subz) ? s.subz[k] : nothing
        (z === nothing || z.ztype != 0) && continue
        for i in 1:max(s.nleads, 0)
            m = (Int64(s.fc_m) - z.t1 + z.t0 - 1) % Int32
            if z.t2 - z.t0 + 1 > s.rblen || m < 0
                ceprintf("error: subtraction zone is larger than template\n")
                cexit(1)
            end
            rf = i <= length(s.refbeat) ? s.refbeat[i] : nothing
            sig = i <= length(s.ecg) ? s.ecg[i] : nothing
            (rf === nothing || sig === nothing) && continue
            jlo = z.t0 - 1 + s.shift
            jhi = z.t2 - 1 + s.shift
            mm = Int64(m)
            if jlo < 0              # skip samples before the start of the signal
                mm -= jlo
                jlo = 0
            end
            # (samples outside the signal or the template are skipped)
            jx = jlo
            while jx <= jhi && jx < length(sig) && mm < length(rf)
                sig[jx+1] += rf[mm+1]
                jx += 1
                mm += 1
            end
        end
    end
end

# Ways of deriving a lead from two others (see _scp_derive!).
const _SCP_SUM = 0                  # a + b
const _SCP_DIFF = 1                 # a - b
const _SCP_AVR = 2                  # -(a + b)/2
const _SCP_HALFDIFF = 3             # a/2 - b
const _SCP_HALFSUM = 4              # a/2 + b

# Derive a missing lead (0-based index k, the next free signal) from leads
# a and b, for the first n samples.
function _scp_derive!(s::_Scp, op::Int, k::Int16, a::Int16, b::Int16, n::UInt64)
    s.nsamp[k+1] = min(_scp_nsampk(s, a), _scp_nsampk(s, b))
    la = _scp_srcsig(s, a)
    lb = _scp_srcsig(s, b)
    out = _scp_sigp(s, k)
    out === nothing && return
    for j in 1:Int(n)
        x, y = la[j], lb[j]
        out[j] = op == _SCP_SUM ? x + y :
                 op == _SCP_DIFF ? x - y :
                 op == _SCP_AVR ? (-((Int32(x) + Int32(y)) ÷ Int32(2))) % Int16 :
                 op == _SCP_HALFDIFF ? (_scp_half(x) - Int32(y)) % Int16 :
                 (_scp_half(x) + Int32(y)) % Int16
    end
    nothing
end

# C integer division of an int by 2 (truncation toward zero).
@inline _scp_half(x::Int16) = Int32(x) ÷ Int32(2)

# Calculate the missing leads.
function _scp_derive_leads(s::_Scp, n0::UInt64)
    vflag = s.vflag != 0
    # Normally the input contains only two of the three limb leads (I, II,
    # and III) and the missing one (usually III) must be calculated from the
    # other two, using the relationship:
    #          lead III = lead II - lead I
    if s.lead_iii < 0               # we need to calculate lead III
        if s.lead_i >= 0 && s.lead_ii >= 0
            vflag && cprintf(" Calculating lead III\n")
            s.lead_iii = s.nleads % Int16
            s.nleads += Int32(1)
            k = s.lead_iii
            s.nsamp[k+1] = min(_scp_nsampk(s, s.lead_i), _scp_nsampk(s, s.lead_ii))
            l1 = _scp_srcsig(s, s.lead_i)
            l2 = _scp_srcsig(s, s.lead_ii)
            l3 = _scp_sigp(s, k)
            if l3 !== nothing
                ne = min(s.nsamp[k+1], UInt64(length(l1)), UInt64(length(l2)), UInt64(length(l3)))
                for j in 1:Int(ne)
                    l3[j] = l2[j] - l1[j]
                end
            end
        elseif s.lead_i < 0
            ceprintf(s.lead_ii < 0 ? "Leads I, II, and III are missing\n" :
                                     "Leads I and III are missing\n")
        else
            ceprintf("Leads II and III are missing\n")
        end
    elseif s.lead_ii < 0            # we need to calculate lead II
        if s.lead_i >= 0
            vflag && cprintf(" Calculating lead II\n")
            s.lead_ii = s.nleads % Int16
            s.nleads += Int32(1)
            _scp_derive!(s, _SCP_SUM, s.lead_ii, s.lead_i, s.lead_iii, n0)
        else
            ceprintf("Leads I and II are missing\n")
        end
    elseif s.lead_i < 0             # we need to calculate lead I
        vflag && cprintf(" Calculating lead I\n")
        s.lead_i = s.nleads % Int16
        s.nleads += Int32(1)
        _scp_derive!(s, _SCP_DIFF, s.lead_i, s.lead_ii, s.lead_iii, n0)
    end

    # We need both lead I and lead II to derive aVR.
    if s.avr < 0
        if s.lead_i >= 0 && s.lead_ii >= 0
            vflag && cprintf(" Calculating lead aVR\n")
            s.avr = s.nleads % Int16
            s.nleads += Int32(1)
            _scp_derive!(s, _SCP_AVR, s.avr, s.lead_i, s.lead_ii, n0)
        else
            ceprintf("Lead aVR cannot be derived\n")
        end
    end

    # We need both lead II and lead III to derive aVL.
    if s.avl < 0
        if s.lead_ii >= 0 && s.lead_iii >= 0
            vflag && cprintf(" Calculating lead aVL\n")
            s.avl = s.nleads % Int16
            s.nleads += Int32(1)
            _scp_derive!(s, _SCP_HALFDIFF, s.avl, s.lead_ii, s.lead_iii, n0)
        else
            ceprintf("Lead aVL cannot be derived\n")
        end
    end

    # We need both lead I and lead III to derive aVF. (C tests leads I and
    # II.)
    if s.avf < 0
        if s.lead_i >= 0 && s.lead_ii >= 0
            vflag && cprintf(" Calculating lead aVF\n")
            s.avf = s.nleads % Int16
            s.nleads += Int32(1)
            _scp_derive!(s, _SCP_HALFSUM, s.avf, s.lead_i, s.lead_iii, n0)
        else
            ceprintf("Lead aVF cannot be derived\n")
        end
    end

    s.v1 < 0 && ceprintf("Lead V1 is missing\n")
    s.v2 < 0 && ceprintf("Lead V2 is missing\n")
    s.v3 < 0 && ceprintf("Lead V3 is missing\n")
    s.v4 < 0 && ceprintf("Lead V4 is missing\n")
    s.v5 < 0 && ceprintf("Lead V5 is missing\n")
    s.v6 < 0 && ceprintf("Lead V6 is missing\n")

    if s.nleads > 0 && any(<(0), _scp_order(s))
        # Use an array of zero samples for the missing lead(s).
        nl = s.nleads % Int16
        s.ecg[nl+1] === nothing && (s.ecg[nl+1] = _scp_newsig(UInt64(0)))
        s.lead_i < 0 && (s.lead_i = nl)
        s.lead_ii < 0 && (s.lead_ii = nl)
        s.lead_iii < 0 && (s.lead_iii = nl)
        s.avr < 0 && (s.avr = nl)
        s.avf < 0 && (s.avf = nl)
        s.avl < 0 && (s.avl = nl)
        s.v1 < 0 && (s.v1 = nl)
        s.v2 < 0 && (s.v2 = nl)
        s.v3 < 0 && (s.v3 = nl)
        s.v4 < 0 && (s.v4 = nl)
        s.v5 < 0 && (s.v5 = nl)
        s.v6 < 0 && (s.v6 = nl)
    end
end

function _scp_help(pname)
    ceprintf("usage: %s -o RECORD [OPTIONS ...] <SCPFILE\n", pname)
    ceprintf("  where RECORD is the name (<= 11 alphanumeric characters) of this case,\n" *
             "  SCPFILE is the name of a file containing ECG data in SCP-ECG format, and\n" *
             "  OPTIONS may include:\n" *
             "   -a    anonymize and copy stdin to stdout (suppresses other output).\n" *
             "   -f    force parsing of a file with CRC errors.\n" *
             "   -h    print brief help\n" *
             "   -l    low-pass filter (smooth) the output waveforms.\n" *
             "   -v    option to print a (very) detailed analysis of SCPFILE.\n" *
             "   -w    produce a WFDB-format record\n" *
             "   -z    zero-mean the input\n\n" *
             "  Additional options for debugging only:\n" *
             "   -b    show baseline (residuals);  suppress templates\n" *
             "   -s N  shift templates by N samples before adding\n" *
             "   -S N  skip parsing of section N\n" *
             "   -t    show templates; suppress baseline\n" *
             "   -x    show hex dumps (implies -v)\n")
end

const _SCP_READ_CHUNK = 1 << 16     # bytes read from the input at a time

function parsescp_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    wfdbx_legacy_args(args)
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "parsescp"
    s = _Scp(pname)

    i = 1
    while i < argc
        a = argv[i]
        if _annapp_c0(a) == UInt8('-')
            c = _annapp_c1(a)
            if c == UInt8('a')      # write an anonymized version of stdin to stdout
                s.aflag = 1
                s.xflag = 0
                s.vflag = 0         # incompatible with -v and -x
            elseif c == UInt8('b')  # show baseline (residuals);  suppress templates
                s.bflag = 1
                s.tflag = 0
            elseif c == UInt8('f')  # force parsing even if CRC error(s) found
                s.fflag = 1
            elseif c == UInt8('h')  # print a usage summary
                _scp_help(pname)
                cexit(1)
            elseif c == UInt8('l')  # low-pass filter the output waveforms
                s.lflag = 1
            elseif c == UInt8('o')  # record name follows
                i += 1
                if i < argc && length(argv[i]) <= _SCP_MAXRECNAME
                    s.recname = copy(argv[i])
                else
                    ceprintf("%s: a record name of 11 or fewer alphanumericcharacters must\n follow -o\n",
                             pname)
                    cexit(1)
                end
            elseif c == UInt8('s')  # shift templates by N samples
                i += 1
                if i < argc
                    s.shift = atoi(argv[i])
                else
                    ceprintf("%s: number of samples to shift templates must follow -s\n", pname)
                    cexit(1)
                end
            elseif c == UInt8('S')  # skip a section (may be repeated)
                i += 1
                if i < argc
                    if _annapp_c0(argv[i]) == UInt8('-')
                        fill!(s.skip, 1)
                    else
                        index = atoi(argv[i])
                        if 0 <= index < _SCP_NSECTIONS
                            s.skip[index+1] = 1 - s.skip[index+1]
                        end
                    end
                else
                    ceprintf("%s: number of section to skip, or '-', must follow -S\n", pname)
                    cexit(1)
                end
            elseif c == UInt8('t')  # show templates;  suppress baseline
                s.tflag = 1
                s.bflag = 0
            elseif c == UInt8('v')  # print a detailed analysis of the record contents
                s.vflag += Int32(1)
                s.aflag = 0         # incompatible with -a
            elseif c == UInt8('w')  # create a WFDB-format record
                s.wflag += Int32(1)
            elseif c == UInt8('x')  # print a hex dump (implies -v)
                s.xflag = 1
                s.vflag = 1
                s.aflag = 0
            elseif c == UInt8('z')  # suppress final transients and zero-mean the ECGs
                s.zflag += Int32(1)
            else
                ceprintf("%s: unrecognized option '%s'\n", pname, a)
                _scp_help(pname)
                cexit(1)
            end
        else
            ceprintf("%s: unrecognized argument '%s'\n", pname, a)
            _scp_help(pname)
            cexit(1)
        end
        i += 1
    end

    # Read the record header (CRC and length), then the rest of the record.
    input = wfdb_stdin()
    header = zeros(UInt8, _SCP_HEADER_SIZE)
    bytesread = UInt64(fread!(input, header, 1, _SCP_HEADER_SIZE))
    if bytesread != _SCP_HEADER_SIZE
        ceprintf("%s: input too short (only %llu bytes)\n", pname, bytesread)
        cexit(1)
    end
    s.data = header
    crc = _scp_get16(s, 0) % UInt16
    reclen = _scp_get32(s, 2)
    s.vflag != 0 && cprintf("CRC = %d, expected length = %lld bytes\n", crc, reclen % Int64)
    if reclen > typemax(Int64)
        ceprintf("%s: insufficient memory (%lld bytes needed)\n", pname, reclen % Int64)
        cexit(2)
    end
    buf = Vector{UInt8}(undef, _SCP_READ_CHUNK)
    while bytesread < reclen
        want = Int(min(reclen - bytesread, UInt64(_SCP_READ_CHUNK)))
        n = fread!(input, buf, 1, want)
        n == 0 && break
        append!(s.data, view(buf, 1:n))
        bytesread += n
    end
    if bytesread < reclen
        d = reclen - bytesread
        ceprintf("%s: input too short (%llu byte%s missing)\n", pname, d, _scp_plural(d))
        cexit(3)
    end
    fclose(input)
    s.vflag != 0 && cprintf("Record length: %lld bytes\n", reclen % Int64)
    _scp_crcok(s, Int64(2), (reclen % Int64) - 2, crc, "Top-level CRC")

    # Now check the sections.
    p = Int64(_SCP_HEADER_SIZE)     # skip the record header -- p points to section 0
    while (p % UInt64) < reclen     # true if there is at least 1 more section
        crc = _scp_get16(s, p) % UInt16
        sec_id = _scp_get16(s, p + 2)
        sec_len = _scp_get32(s, p + 4)
        v = s.vflag != 0
        v && cprintf("\nSection %d length: %lld bytes\n", sec_id % Int32, sec_len % Int64)
        if sec_len < _SCP_MIN_SECLEN
            v && cprintf(" Warning: section length too short (must be at least 8 bytes)\n  Remaining data (%llu bytes) following short section will not be read\n",
                         reclen - ((p + 8) % UInt64))
            sec_len = UInt64(_SCP_MIN_SECLEN)
        end
        if sec_len > reclen - (p % UInt64)
            v && cprintf(" Warning: section length exceeds amount of remaining data\n  This section will not be parsed\n")
            break
        end
        _scp_crcok(s, p + 2, (sec_len % Int64) - 2, crc, cformat(" Section %d CRC", sec_id % Int32))
        if v
            cprintf(" Section version number: %d\n", _scp_b(s, p + 8) % Int32)
            cprintf(" Protocol version number: %d\n", _scp_b(s, p + 9) % Int32)
            cprintf(" Contents: ")
        end
        sl = sec_len % Int64
        if sec_id < _SCP_NSECTIONS
            id = Int(sec_id)
            v && cprintf("%s", _SCP_CONTENTS[id+1])
            if s.skip[id+1] != 0
                cprintf("  [skipped]\n")
            else
                _scp_section(s, id, p, sl)
            end
        elseif v
            cprintf(" Manufacturer-defined (non-standard) section %d\n", sec_id % Int32)
        end
        p += sl
    end

    _scp_filter_residuals(s)
    s.bflag == 0 && _scp_add_refbeats(s)    # true unless -b debugging option was given

    # wfdb-x: signals that could not be allocated (undefined behavior in C)
    # are read as zeros, and so are samples beyond the end of a signal
    # shorter than lead 0.
    n0 = UInt64(0)
    if s.have_ecg
        n0 = isempty(s.nsamp) ? UInt64(0) : s.nsamp[1]
        n0 > _SCP_MAXALLOC && (n0 = UInt64(0))
        s.nout = n0
        for k in eachindex(s.ecg)
            s.ecg[k] === nothing && (s.ecg[k] = _scp_newsig(UInt64(0)))
            sig = s.ecg[k]::_ScpSig
            nk = UInt64(length(sig))
            nk < n0 && append!(sig, zeros(Int16, n0 - nk))
        end
    end

    _scp_derive_leads(s, n0)

    if s.aflag != 0
        # Recalculate the top-level CRC.
        crc = _scp_getcrc(s, Int64(2), (bytesread % Int64) - 2)
        _scp_put16!(s, UInt32(crc), Int64(0))
        cout_write(view(s.data, 1:Int(bytesread)))
    elseif s.nleads > 0
        _scp_write_output(s)
    end
    cexit(0)
end

register_workload("parsescp") do
    with_workload_data() do dir
        scp = read(joinpath(dir, "example.scp"))
        for opts in (["-w", "-o", "ex"], String[], ["-l", "-z", "-w", "-o", "ex"],
                     ["-b", "-w", "-o", "ex"], ["-t", "-w", "-o", "ex"],
                     ["-s", "3", "-w", "-o", "ex"], ["-s", "-2", "-t", "-w", "-o", "ex"],
                     ["-S", "5", "-w", "-o", "ex"], ["-S", "6", "-w", "-o", "ex"],
                     ["-S", "3", "-w", "-o", "ex"], ["-S", "-"], ["-f", "-w", "-o", "ex"],
                     ["-a"], ["-v", "-S", "7"], ["-v", "-v", "-o", "ex"], ["-x", "-o", "ex"])
            workload_tool("parsescp", opts...; stdin=scp)
        end
        # Damaged inputs (with and without -v): CRC errors, truncation, bytes
        # changed in each part of the record.
        bad = copy(scp)
        bad[301] = 0x55
        workload_tool("parsescp", "-w", "-o", "x"; stdin=bad)
        workload_tool("parsescp", "-f", "-v", "-o", "x"; stdin=bad)
        workload_tool("parsescp", "-w", "-o", "x"; stdin=scp[1:20000])
        workload_tool("parsescp", "-w", "-o", "x"; stdin=UInt8[1, 2, 3])
        g = GlibcRand(1)
        for k in 1:24
            d = copy(scp)
            for _ in 1:4
                d[1 + glibc_rand!(g) % length(d)] = glibc_rand!(g) % UInt8
            end
            workload_tool("parsescp", "-f", "-v", "-z", "-l", "-o", "x"; stdin=d)
        end
        workload_tool("parsescp", "-w", "-o", "x"; stdin=read(joinpath(dir, "scp62.scp")))
        workload_tool("parsescp", "-o", "123456789012")
        workload_tool("parsescp", "-h")
        workload_tool("parsescp", "-q")
        workload_tool("parsescp", "extra")
        # wfdb-x: legacy mode (original behavior)
        workload_tool("parsescp", "--legacy", "-w", "-o", "ex"; stdin=scp)
        workload_tool("parsescp", "--legacy", "-f", "-v", "-o", "x"; stdin=bad)
        g = GlibcRand(2)
        for k in 1:8
            d = copy(scp)
            for _ in 1:4
                d[1 + glibc_rand!(g) % length(d)] = glibc_rand!(g) % UInt8
            end
            workload_tool("parsescp", "--legacy", "-f", "-v", "-w", "-o", "x"; stdin=d)
        end
    end
end
