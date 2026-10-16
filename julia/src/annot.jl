# annot.jl: annotations (port of lib/annot.c): MIT and AHA annotation
# files, annotation code mnemonics and descriptions, annotation time
# resolution.
#
# This file contains annopen, getann, ungetann, putann, iannsettime, the
# annotation code/mnemonic/description conversion functions (ecgstr,
# strecg, setecgstr, annstr, strann, setannstr, anndesc, setanndesc), the
# time resolution functions (setafreq, getafreq, setiafreq, getiafreq,
# getiaorigfreq), iannclose, oannclose, and the library-private functions
# wfdb_anclose and wfdb_oaflush (called by wfdbquit and wfdbflush).
#
# Modification labels (NOTE annotations at time 0 that redefine annotation
# mnemonics and descriptions, and the time resolution record) are read by
# annopen and written before the first annotation of each output file.
# Output files whose annotations are not in canonical order are sorted when
# they are closed, by running the sortann program (`run_sortann`).
#
# Copyright (C) 1989-2013 George B. Moody (original C implementation,
# lib/annot.c; revised 2015-2020 by Benjamin Moody).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

# Annotation word format
const _CODE = UInt32(0o176000)  # annotation code segment of word
const _CS = 10                  # places by which code must be shifted
const _DATA = UInt32(0o1777)    # data segment of annotation word
const _MAXRR = UInt64(0o1777)   # longest interval coded in a word

const _MAXSKIP = Int64(0x7fffffff)  # largest interval of a SKIP
const _MINSKIP = -Int64(0x7fffffff) # smallest interval of a SKIP

# Pseudo-annotation codes
const _PAMIN = UInt32(59) << _CS    # lowest pseudo-annotation code
const _SKIP = UInt32(59) << _CS     # long null annotation
const _NUM = UInt32(60) << _CS      # change 'num' field
const _SUB = UInt32(61) << _CS      # subtype
const _CHN = UInt32(62) << _CS      # change 'chan' field
const _AUX = UInt32(63) << _CS      # auxiliary information

const _AUXLEN_MASK = UInt32(0o377)  # length of the aux data in an AUX word
"Maximum length of an annotation's aux data (its length is stored in one byte)."
const AUX_MAX = 255

# Constants for AHA annotation files only
const _ABLKSIZ = 1024           # AHA annotation file block length
const _AUXBUFLEN = 771          # size of the aux string buffer
const _AUXLEN = 6               # length of AHA aux field
const _EOAF = 0o377             # padding for end of AHA annotation files
const _AHA_AUXBUF_WRAP = 256    # AHA aux strings are kept in the first 256 bytes

"Number of annotation codes (0 .. ACMAX)."
const _NCODES = Int(ACMAX) + 1

# An input annotator.
mutable struct _IaData
    file::WfdbFile          # input annotation file
    info::Anninfo           # input annotator information
    ann::Annotation         # next annotation to be returned by getann
    pann::Annotation        # pushed-back annotation from ungetann
    afreq::Float64          # time resolution, in ticks/second
    word::UInt32            # next word from the input file
    ateof::Int32            # EOF-reached indicator
    auxstr::Vector{UInt8}   # aux string buffer (_AUXBUFLEN bytes)
    index::Int              # next available position in auxstr (0-based)
    auxpos::Int             # position of the aux string of `ann` in auxstr (-1: none)
    tmul::Float64           # tmul * annotation time = sample count
    tt::Float64             # annotation time (MIT format only)
    ann_tt::Float64         # unscaled annotation time of `ann`
    pann_tt::Float64        # unscaled annotation time of `pann`
    prev_tt::Float64        # unscaled time of the last annotation returned by getann
    prev_time::Int64        # sample number of the last annotation returned by getann
end

# An output annotator.
mutable struct _OaData
    file::WfdbFile          # output annotation file
    info::Anninfo           # output annotator information
    ann::Annotation         # most recent annotation written by putann
    afreq::Float64          # time resolution, in ticks/second
    seqno::Int32            # annotation serial number (AHA only)
    rname::Vector{UInt8}    # record with which the annotator is associated
    out_of_order::Bool      # if true, annotations are not in order
    table_written::Bool     # if true, the table has been written
end

const _DEFAULT_MNEMONICS = (
    " ", "N", "L", "R", "a",                    # 0 - 4
    "V", "F", "J", "A", "S",                    # 5 - 9
    "E", "j", "/", "Q", "~",                    # 10 - 14
    "[15]", "|", "[17]", "s", "T",              # 15 - 19
    "*", "D", "\"", "=", "p",                   # 20 - 24
    "B", "^", "t", "+", "u",                    # 25 - 29
    "?", "!", "[", "]", "e",                    # 30 - 34
    "n", "@", "x", "f", "(",                    # 35 - 39
    ")", "r", "[42]", "[43]", "[44]",           # 40 - 44
    "[45]", "[46]", "[47]", "[48]", "[49]")     # 45 - 49

const _DEFAULT_DESCRIPTIONS = (
    "",
    "Normal beat",
    "Left bundle branch block beat",
    "Right bundle branch block beat",
    "Aberrated atrial premature beat",
    "Premature ventricular contraction",
    "Fusion of ventricular and normal beat",
    "Nodal (junctional) premature beat",
    "Atrial premature beat",
    "Supraventricular premature or ectopic beat",
    "Ventricular escape beat",
    "Nodal (junctional) escape beat",
    "Paced beat",
    "Unclassifiable beat",
    "Change in signal quality",
    nothing,
    "Isolated QRS-like artifact",
    nothing,
    "ST segment change",
    "T-wave change",
    "Systole",
    "Diastole",
    "Comment annotation",
    "Measurement annotation",
    "P-wave peak",
    "Bundle branch block beat (unspecified)",
    "(Non-captured) pacemaker artifact",
    "T-wave peak",
    "Rhythm change",
    "U-wave peak",
    "Beat not classified during learning",
    "Ventricular flutter wave",
    "Start of ventricular flutter/fibrillation",
    "End of ventricular flutter/fibrillation",
    "Atrial escape beat",
    "Supraventricular escape beat",
    "Link to external data (aux contains URL)",
    "Non-conducted P-wave (blocked APC)",
    "Fusion of paced and normal beat",
    "Waveform onset",
    "Waveform end",
    "R-on-T premature ventricular contraction",
    nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing)

"""
The state of annot.c (the `ann` field of a `Wfdb`): input and output
annotators, mnemonic and description tables, annotation time resolution.
"""
mutable struct AnnState
    iad::Vector{_IaData}                        # input annotators
    oad::Vector{_OaData}                        # output annotators
    oafreq::Float64                             # time resolution for new output annotators
    annclose_error::Int32                       # if < 0, error while closing files
    modified::Vector{Bool}                      # mnemonic or description modified
    cstring::Vector{Vector{UInt8}}              # ECG mnemonics for each code
    astring::Vector{Vector{UInt8}}              # mnemonic strings for each code
    tstring::Vector{Union{Nothing,Vector{UInt8}}}   # descriptions for each code
end

AnnState() = AnnState(_IaData[], _OaData[], 0.0, 0, fill(false, _NCODES),
                      [Vector{UInt8}(codeunits(s)) for s in _DEFAULT_MNEMONICS],
                      [Vector{UInt8}(codeunits(s)) for s in _DEFAULT_MNEMONICS],
                      Union{Nothing,Vector{UInt8}}[s === nothing ? nothing : Vector{UInt8}(codeunits(s))
                                                   for s in _DEFAULT_DESCRIPTIONS])

# Round a double to the nearest time, with halfway cases always rounded up.
function _round_to_time(x::Float64)
    isnan(x) && return WFDB_TIME_MIN    # as on x86
    if x >= 0.0
        x >= Float64(WFDB_TIME_MAX) && return WFDB_TIME_MAX
        t = trunc(Int64, x)
        return x - Float64(t) >= 0.5 ? t + 1 : t
    else
        x <= Float64(WFDB_TIME_MIN) && return WFDB_TIME_MIN
        t = trunc(Int64, x)
        return x - Float64(t) < -0.5 ? t - 1 : t
    end
end

# The aux string of an annotation as a C string (the data following the
# length byte, up to the first null).
_aux_text(aux::Vector{UInt8}) = cstr(length(aux) >= 1 ? aux[2:end] : UInt8[])

# An aux field (length byte first) holding s.
_make_aux(s::AbstractVector{UInt8}) = UInt8[length(s) % UInt8; s]

# The aux string at (0-based) position pos of the aux buffer: the length
# byte, the data, and any following bytes up to a null (as a C string would
# be read).
function _aux_from_buffer(ia::_IaData, pos::Int)
    buf = ia.auxstr
    len = Int(buf[pos+1])
    s = UInt8[len % UInt8]
    i = pos + 1
    while i < _AUXBUFLEN && (i - pos - 1 < len || buf[i+1] != 0)
        push!(s, buf[i+1])
        i += 1
    end
    s
end

# Read the next annotation of an input annotator into ia.ann (the second
# part of getann). Returns an error message to report, if any.
function _getann_next!(ia::_IaData)
    msg = nothing
    f = ia.file
    if ia.info.stat == WFDB_AHA_READ
        if (ia.word & 0xff) == _EOAF        # logical end of file
            ia.ateof = 1
            return nothing
        end
        a = (ia.word >> 8) % Int32          # AHA annotation code
        ia.ann.anntyp = wfdb_ammap(a) % Int8
        ia.ann_tt = Float64(wfdb_g32(f))
        if wfdb_g16(f) <= 0                 # serial number (starts at 1)
            msg = cformat("getann: unexpected annot number in annotator %s\n", ia.info.name)
        end
        ia.ann.subtyp = getc(f) % Int8
        if a == Int32('U') && ia.ann.subtyp == 0
            ia.ann.subtyp = -1              # unreadable (noise subtype -1)
        end
        ia.ann.chan = getc(f) % UInt8
        if ia.index >= _AHA_AUXBUF_WRAP - (_AUXLEN + 2)
            ia.index = 0
        end
        # read aux data
        ix = ia.index
        fread!(f, view(ia.auxstr, ix+2:ix+1+_AUXLEN))
        # There is very limited space in AHA format files for auxiliary
        # information, so no length byte is recorded; instead, we assume
        # that if the first byte of auxiliary data is not null, that up to
        # AUXLEN bytes may be significant.
        if ia.auxstr[ix+2] != 0
            ia.auxstr[ix+1] = _AUXLEN % UInt8
            ia.auxpos = ix                  # save position
            ia.auxstr[ix+2+_AUXLEN] = 0     # add a null
            ia.index += _AUXLEN + 2         # update buffer index
        else
            ia.auxpos = -1
        end
        ia.word = wfdb_g16(f) % UInt32
    else                                    # MIT-format input file
        if ia.word == 0                     # logical end of file
            ia.ateof = 1
            return nothing
        end
        ia.tt += Float64(ia.word & _DATA)   # annotation time
        ia.ann_tt = ia.tt
        ia.ann.anntyp = ((ia.word & _CODE) >> _CS) % Int8
        ia.ann.subtyp = 0                   # reset subtype field
        ia.auxpos = -1                      # reset aux field
        while true
            ia.word = wfdb_g16(f) % UInt32
            ((ia.word & _CODE) < _PAMIN || feof(f)) && break
            code = ia.word & _CODE          # process pseudo-annotations
            if code == _SKIP
                ia.tt += Float64(wfdb_g32(f))
            elseif code == _SUB
                ia.ann.subtyp = (_DATA & ia.word) % Int8
            elseif code == _CHN
                ia.ann.chan = (_DATA & ia.word) % UInt8
            elseif code == _NUM
                ia.ann.num = (_DATA & ia.word) % Int8
            elseif code == _AUX             # auxiliary information
                len = Int(ia.word & _AUXLEN_MASK)   # length of auxiliary data
                if ia.index >= _AUXBUFLEN - 2 - len
                    ia.index = 0            # buffer index
                end
                ia.auxpos = ia.index        # save position
                ia.auxstr[ia.index+1] = len % UInt8
                ia.index += 1
                # Now read the data. Note that an extra byte may be present
                # in the annotation file to preserve word alignment; if so,
                # this extra byte is read and then overwritten by the null
                # below.
                ix = ia.index
                fread!(f, view(ia.auxstr, ix+1:ix+((len + 1) & ~1)))
                ia.auxstr[ix+len+1] = 0     # add a null
                ia.index += len + 1         # update buffer index
            end
        end
    end
    ia.ann.time = _round_to_time(ia.ann_tt * ia.tmul)
    feof(ia.file) && (ia.ateof = -1)
    msg
end

# Copy the fields of an annotation (C structure assignment; aux shared).
function _setann!(dst::Annotation, src::Annotation)
    dst.time = src.time
    dst.anntyp = src.anntyp
    dst.subtyp = src.subtyp
    dst.chan = src.chan
    dst.num = src.num
    dst.aux = src.aux
    dst
end

# ---------------------------------------------------------------------------
# Private functions (for the use of other WFDB library functions only)

"""
    wfdb_oaflush([w])

Flush the output annotation files (library-private; called by `wfdbflush`).
"""
function wfdb_oaflush(w::Wfdb)
    for oa in w.ann.oad
        fflush(oa.file)
    end
    nothing
end

"""
    wfdb_anclose([w])

Close all annotators (library-private; called by `wfdbquit` and `annopen`).
"""
function wfdb_anclose(w::Wfdb)
    for an in length(w.ann.iad)-1:-1:0
        iannclose(w, an)
    end
    for an in length(w.ann.oad)-1:-1:0
        oannclose(w, an)
    end
    nothing
end

const _TIME_RESOLUTION_LABEL = b"## time resolution: "
const _TABLE_START_LABEL = b"## annotation type definitions"
const _TABLE_END_LABEL = b"## end of definitions"
# Length of "## time resolution:" (the number follows, after a space).
const _TIME_RESOLUTION_PREFIX = 19

_is_blank(c::UInt8) = c == UInt8(' ') || c == UInt8('\t')

# Read the modification labels at the beginning of input annotator i
# (0-based), and set its time resolution.
function _get_ann_table(w::Wfdb, i::Int)
    ia = w.ann.iad[i+1]
    ia.tmul = 1.0
    ia.afreq = 0.0
    annot = Annotation()
    getann(w, i, annot) < 0 && return Int32(-1)     # prime the pump
    while getann(w, i, annot) == 0 && annot.time == 0 && annot.anntyp == NOTE &&
          annot.subtyp == 0
        aux = annot.aux
        (aux === nothing || isempty(aux) || aux[1] < 1) && continue
        text = _aux_text(aux)
        if !isempty(text) && text[1] == UInt8('#')
            if length(text) >= length(_TIME_RESOLUTION_LABEL) &&
               view(text, 1:length(_TIME_RESOLUTION_LABEL)) == _TIME_RESOLUTION_LABEL
                f = Ref(ia.afreq)
                csscanf(view(text, _TIME_RESOLUTION_PREFIX+1:length(text)), "%lf", f)
                ia.afreq = f[]
            end
            continue
        end
        n = length(text)
        p1 = 0                              # whitespace before code
        while p1 < n && _is_blank(text[p1+1])
            p1 += 1
        end
        v, nconv = strtol(view(text, p1+1:n), 10)
        a = v % Int32
        (a < 0 || a > ACMAX || nconv == 0) && continue
        p2 = p1 + nconv                     # non-whitespace after code
        while p2 < n && !_is_blank(text[p2+1])
            p2 += 1
        end
        p1 = p2                             # whitespace before mnemonic
        while p1 < n && _is_blank(text[p1+1])
            p1 += 1
        end
        p2 = p1                             # non-whitespace (mnemonic)
        while p2 < n && !_is_blank(text[p2+1])
            p2 += 1
        end
        if p2 != p1
            if p2 < n
                setanndesc(w, a, text[p2+2:n])
            else
                setanndesc(w, a, nothing)
            end
            setannstr(w, a, text[p1+1:p2])
        end
    end
    if annot.time != 0 || annot.anntyp != NOTE || annot.subtyp != 0 || annot.aux === nothing
        ungetann(w, i, annot)
    end
    setiafreq(w, i, getifreq(w))
    Int32(0)
end

# Write the modification labels at the beginning of output annotator i
# (0-based).
function _put_ann_table(w::Wfdb, i::Int)
    flag = 0
    annot = Annotation(time=0, anntyp=NOTE % Int8)
    oafreq = w.ann.oafreq
    oa = w.ann.oad[i+1]
    if oafreq != oa.afreq && oafreq > 0.0
        annot.aux = _make_aux(cformat("## time resolution: %.12g", oafreq))
        oa.afreq = oafreq
        putann(w, i, annot) < 0 && return Int32(-1)
        flag = 1
    end
    for a in 0:_NCODES-1
        if w.ann.modified[a+1]
            if flag < 2                     # mark the beginning of the table
                annot.aux = _make_aux(_TABLE_START_LABEL)
                putann(w, i, annot) < 0 && return Int32(-1)
            end
            m = annstr(w, a)
            d = anndesc(w, a)
            s = d === nothing ? cformat("%d %s ", Int32(a), m) : cformat("%d %s %s", Int32(a), m, d)
            annot.aux = UInt8[min(length(s), AUX_MAX) % UInt8; s]
            putann(w, i, annot) < 0 && return Int32(-1)
            flag = 2
        end
    end
    if flag == 2                            # if a table was written, mark its end
        annot.aux = _make_aux(_TABLE_END_LABEL)
        putann(w, i, annot) < 0 && return Int32(-1)
    end
    if flag != 0                            # if a table was written, mark its end
        annot.anntyp = 0
        annot.aux = nothing
        putann(w, i, annot) < 0 && return Int32(-1)
    end
    Int32(0)
end

# ---------------------------------------------------------------------------
# WFDB library functions

"""
    annopen([w], record, aiarray::Vector{Anninfo}, nann) -> Int32

C `annopen`: open the annotation files of `record` for the first `nann`
annotators of `aiarray` (see [`Anninfo`](@ref)): input files (`WFDB_READ`,
`WFDB_AHA_READ`) are looked for in the WFDB path, output files
(`WFDB_WRITE`, `WFDB_AHA_WRITE`) are created in the current directory.
Unless `record` begins with `+`, the annotators open before are closed
first. Input annotators are then numbered 0, 1, ... in the order given (the
`n` argument of [`getann`](@ref)), and so are output annotators (the `n` of
[`putann`](@ref)).

Returns 0, or -3 (an input file cannot be read), -4 (an output file cannot
be written, or an illegal annotator name), -5 (an illegal `stat`); with
`nann` 0, the status of closing the previously opened annotators (-6 or -7
on errors).

# Examples
```julia-repl
julia> annopen("100s", [Anninfo("atr", WFDB_READ)], 1)
0

julia> a = Annotation();

julia> getann(0, a), a.time, String(annstr(a.anntyp))
(0, 18, "+")
```
"""
function annopen(w::Wfdb, record::OptByteStr, aiarray::AbstractVector{Anninfo}, nann::Integer)
    w.ann.annclose_error = 0
    rec = record === nothing ? UInt8[] : cstr(bytes(record))
    if !isempty(rec) && rec[1] == UInt8('+')    # don't close open annotation files
        rec = rec[2:end]                        # discard the '+' prefix
    else
        wfdb_anclose(w)                         # close previously opened annotation files
    end

    # If no annotation files are to be opened, report whether errors
    # occurred while closing previously-opened files.
    nann == 0 && return w.ann.annclose_error
    n = min(Int(nann % UInt32), length(aiarray))

    # Remove trailing .hea, if any, from record name.
    rec = wfdb_striphea(rec)

    # Check the stat of each annotator.
    for k in 1:n
        ai = aiarray[k]
        if !(ai.stat in (WFDB_READ, WFDB_AHA_READ, WFDB_WRITE, WFDB_AHA_WRITE))
            wfdb_error(w, "annopen: illegal stat %d for annotator %s, record %s\n", ai.stat,
                       cstr(ai.name), rec)
            return Int32(-5)
        end
    end

    for k in 1:n                                # open the annotation files
        ai = aiarray[k]
        name = copy(cstr(ai.name))
        if ai.stat == WFDB_READ || ai.stat == WFDB_AHA_READ
            # standard (MIT-format) or AHA-format input file
            wfdb_setirec(w, rec)
            file = wfdb_open(w, name, rec, WFDB_READ)
            if file === nothing
                wfdb_error(w, "annopen: can't read annotator %s for record %s\n", name, rec)
                return Int32(-3)
            end
            # Try to figure out what format the file is in. AHA-format
            # files begin with a null byte and an ASCII character which is
            # one of the legal AHA annotation codes other than '[' or ']'.
            # MIT annotation files cannot begin in this way.
            word = wfdb_g16(file) % UInt32
            a = ((word >> 8) & 0xff) % Int32
            tt = 0.0
            if (word & 0xff) != 0 || wfdb_ammap(a) == NOTQRS || a == Int32('[') ||
               a == Int32(']')
                if ai.stat != WFDB_READ
                    wfdb_error(w, "warning (annopen, annotator %s, record %s):\n", name, rec)
                    wfdb_error(w, " file appears to be in MIT format\n")
                    wfdb_error(w, " ... continuing under that assumption\n")
                end
                stat = WFDB_READ
                # read any initial null annotation(s)
                while (word & _CODE) == _SKIP
                    tt += Float64(wfdb_g32(file))
                    word = wfdb_g16(file) % UInt32
                end
            else
                if ai.stat != WFDB_AHA_READ
                    wfdb_error(w, "warning (annopen, annotator %s, record %s):\n", name, rec)
                    wfdb_error(w, " file appears to be in AHA format\n")
                    wfdb_error(w, " ... continuing under that assumption\n")
                end
                stat = WFDB_AHA_READ
            end
            push!(w.ann.iad, _IaData(file, Anninfo(copy(ai.name), stat),
                                     Annotation(), Annotation(),  # any pushed-back annot is invalid
                                     0.0, word, 0, zeros(UInt8, _AUXBUFLEN), 0, -1,
                                     0.0, tt, 0.0, 0.0, 0.0, 0))
            _get_ann_table(w, length(w.ann.iad) - 1)
        else
            # standard (MIT-format) or AHA-format output file. Quit (with
            # message from wfdb_checkname) if name is illegal.
            wfdb_checkname(w, name, "annotator") != 0 && return Int32(-4)
            file = wfdb_open(w, name, rec, WFDB_WRITE)
            if file === nothing
                wfdb_error(w, "annopen: can't write annotator %s for record %s\n", name, rec)
                return Int32(-4)
            end
            push!(w.ann.oad, _OaData(file, Anninfo(copy(ai.name), ai.stat), Annotation(), 0.0, 0,
                                     copy(rec), false, false))
        end
    end
    Int32(0)
end

"""
    getann([w], n, annot::Annotation) -> Int32

C `getann`: read the next annotation from input annotator `n` (numbered
from 0, in the order given to [`annopen`](@ref)) into `annot`. Returns 0,
-1 at the end of the file, -2 if `n` is not an open input annotator, -3 at
an unexpected end of file.

`annot.aux` receives a copy of the auxiliary data (with its leading length
byte; see [`Annotation`](@ref)). In C, `aux` points into a 771-byte circular
buffer of the library, which already holds the data of the following
annotation when `getann` returns; that data can overwrite the end of long
aux strings. The copy reproduces the C result exactly, including in that
case.
"""
function getann(w::Wfdb, n::Integer, annot::Annotation)
    k = Int(n % UInt32)
    if k >= length(w.ann.iad)
        wfdb_error(w, "getann: can't read annotator %d\n", n % UInt32)
        return Int32(-2)
    end
    ia = w.ann.iad[k+1]
    if ia.pann.anntyp != 0                      # an annotation was pushed back
        _setann!(annot, ia.pann)
        annot.aux = ia.pann.aux === nothing ? nothing : copy(ia.pann.aux)
        ia.pann.anntyp = 0
        ia.prev_time = annot.time
        ia.prev_tt = ia.pann_tt
        return Int32(0)
    end
    if ia.ateof != 0
        ia.ateof != -1 && return Int32(-1)      # reached logical EOF
        wfdb_error(w, "getann: unexpected EOF in annotator %s\n", ia.info.name)
        return Int32(-3)
    end
    _setann!(annot, ia.ann)
    ia.prev_time = annot.time
    ia.prev_tt = ia.ann_tt
    retpos = ia.auxpos
    msg = _getann_next!(ia)
    annot.aux = retpos >= 0 ? _aux_from_buffer(ia, retpos) : nothing
    msg === nothing || wfdb_error_msg(w, msg)
    Int32(0)
end

"""
    ungetann([w], n, annot::Annotation) -> Int32

C `ungetann`: push back an annotation into input annotator `n` (one
annotation only). Returns 0, -1 if the pushback buffer is full, -2 if `n`
is not an open input annotator.
"""
function ungetann(w::Wfdb, n::Integer, annot::Annotation)
    k = Int(n % UInt32)
    if k >= length(w.ann.iad)
        wfdb_error(w, "ungetann: annotator %d is not initialized\n", n % UInt32)
        return Int32(-2)
    end
    ia = w.ann.iad[k+1]
    if ia.pann.anntyp != 0
        wfdb_error(w, "ungetann: pushback buffer is full\n")
        wfdb_error(w, "ungetann: annotation at %lld, annotator %d not pushed back\n",
                   annot.time, n % UInt32)
        return Int32(-1)
    end
    ia.pann = copy(annot)
    ia.pann_tt = annot.time == ia.prev_time ? ia.prev_tt : Float64(annot.time) / ia.tmul
    Int32(0)
end

"""
    putann([w], n, annot::Annotation) -> Int32

C `putann`: write the annotation `annot` to output annotator `n`
(numbered from 0, in the order given to [`annopen`](@ref)). Annotations
should be written in time order; if they are not, the file is sorted when
it is closed (see [`oannclose`](@ref)). Returns 0, -1 on a write error (or
a time overflow), -2 if `n` is not an open output annotator.
"""
function putann(w::Wfdb, n::Integer, annot::Annotation)
    k = Int(n % UInt32)
    if k >= length(w.ann.oad)
        wfdb_error(w, "putann: can't write annotation file %d\n", n % UInt32)
        return Int32(-2)
    end
    t = annot.time
    oa = w.ann.oad[k+1]
    if !oa.table_written
        oa.table_written = true
        _put_ann_table(w, k) < 0 && return Int32(-1)
    end
    f = oa.file
    delta = (t % UInt64) - (oa.ann.time % UInt64)
    if !(annot.chan > oa.ann.chan || annot.num > oa.ann.num || t > oa.ann.time ||
         (t == 0 && oa.ann.time == 0))
        oa.out_of_order = true
    end
    aux = annot.aux
    # aux length (a null aux, or an empty string, has none)
    auxlen = (aux === nothing || isempty(aux)) ? 0 : Int(aux[1])
    if oa.info.stat == WFDB_AHA_WRITE           # AHA-format output file
        putc(f, 0)
        putc(f, wfdb_mamap(annot.anntyp, annot.subtyp) % UInt8)
        wfdb_p32(f, t)
        oa.seqno += Int32(1)
        wfdb_p16(f, oa.seqno)
        putc(f, annot.subtyp % UInt8)
        putc(f, annot.anntyp % UInt8)
        len = min(auxlen, _AUXLEN)
        for j in 1:len
            putc(f, j + 1 <= length(aux) ? aux[j+1] : 0x00)
        end
        for _ in len+1:_AUXLEN
            putc(f, 0)
        end
    else
        # MIT-format output file. Do not allow annotations to be written at
        # the minimum or maximum possible time value.
        if t == WFDB_TIME_MIN || t == WFDB_TIME_MAX
            wfdb_error(w, "putann: time overflow in annotation file %d\n", n % UInt32)
            return Int32(-1)
        end
        if t > oa.ann.time
            while delta > _MAXSKIP % UInt64
                wfdb_p16(f, _SKIP)
                wfdb_p32(f, _MAXSKIP)
                delta -= _MAXSKIP % UInt64
            end
        else
            while -delta > (-_MINSKIP) % UInt64
                wfdb_p16(f, _SKIP)
                wfdb_p32(f, _MINSKIP)
                delta -= _MINSKIP % UInt64
            end
        end
        if annot.anntyp == 0
            # putann must not write a word of zeroes that would be
            # interpreted as an EOF, so it writes a SKIP to the location
            # just before the desired one; thus annwd is never 0.
            wfdb_p16(f, _SKIP)
            wfdb_p32(f, (delta - 1) % Int64)
            delta = UInt64(1)
        elseif delta > _MAXRR
            # skip forward by more than MAXRR, or skip backward by any
            # distance
            wfdb_p16(f, _SKIP)
            wfdb_p32(f, delta % Int64)
            delta = UInt64(0)
        end
        annwd = (delta % Int32 % UInt32) + ((Int32(annot.anntyp) % UInt32) << _CS)
        wfdb_p16(f, annwd)
        annot.subtyp != 0 && wfdb_p16(f, _SUB + (_DATA & (Int32(annot.subtyp) % UInt32)))
        annot.chan != oa.ann.chan && wfdb_p16(f, _CHN + (_DATA & UInt32(annot.chan)))
        annot.num != oa.ann.num && wfdb_p16(f, _NUM + (_DATA & (Int32(annot.num) % UInt32)))
        if auxlen != 0
            wfdb_p16(f, _AUX + UInt32(auxlen))
            data = zeros(UInt8, auxlen)
            m = min(auxlen, length(aux) - 1)
            m > 0 && copyto!(data, 1, aux, 2, m)
            fwrite(f, data)
            isodd(auxlen) && putc(f, 0)
        end
    end
    if ferror(f)
        wfdb_error(w, "putann: write error on annotation file %s\n", oa.info.name)
        return Int32(-1)
    end
    oa.ann.time = t
    oa.ann.anntyp = annot.anntyp
    oa.ann.subtyp = annot.subtyp
    oa.ann.chan = annot.chan
    oa.ann.num = annot.num
    Int32(0)
end

"""
    iannsettime([w], t) -> Int32

C `iannsettime`: skip ahead (or rewind) the input annotators so that the
next annotation read from each has a time >= `t` (negative values are
treated as positive, except `WFDB_TIME_MIN`, which rewinds to the very
beginning). Returns 0, or -1 if no input annotator remains valid.
"""
function iannsettime(w::Wfdb, t::Integer)
    t = Int64(t)
    stat = Int32(0)
    niavalid = length(w.ann.iad)
    tempann = Annotation()

    # Handle negative arguments as equivalent positive arguments. As an
    # exception, WFDB_TIME_MIN indicates that we should rewind to the very
    # beginning of the annotation file, even if there are annotations at
    # negative time values.
    (t < 0 && t != WFDB_TIME_MIN) && (t = -t)

    for i in 0:length(w.ann.iad)-1
        ia = w.ann.iad[i+1]
        if ia.ann.time >= t                     # "rewind" the annotation file
            ia.pann.anntyp = 0                  # flush pushback buffer
            if fseek(ia.file, 0, SEEK_SET) == -1
                wfdb_error(w, "iannsettime: improper seek\n")
                return Int32(-1)
            end
            ia.ann.subtyp = 0
            ia.ann.chan = 0
            ia.ann.num = 0
            ia.ateof = 0
            ia.ann.time = 0
            ia.tt = 0.0
            ia.word = wfdb_g16(ia.file) % UInt32
            if ia.info.stat == WFDB_READ
                while (ia.word & _CODE) == _SKIP
                    ia.tt += Float64(wfdb_g32(ia.file))
                    ia.word = wfdb_g16(ia.file) % UInt32
                end
            end
            getann(w, i, tempann)
        end
        while ia.ann.time < t
            stat = getann(w, i, tempann)
            stat != 0 && break
        end
        stat < 0 && (niavalid -= 1)
    end
    niavalid > 0 ? Int32(0) : Int32(-1)
end

# ---------------------------------------------------------------------------
# Conversion between annotation codes, mnemonics, and descriptions

_validcode(code::Integer) = 0 <= code <= ACMAX

"""
    ecgstr([w], code) -> Vector{UInt8}

C `ecgstr`: the fixed mnemonic of an annotation code (`[N]` for codes
outside 0..ACMAX).
"""
ecgstr(w::Wfdb, code::Integer) =
    _validcode(code) ? copy(w.ann.cstring[code+1]) : cformat("[%d]", code % Int32)

"""
    strecg([w], str) -> Int32

C `strecg`: the annotation code of a fixed mnemonic (`NOTQRS` if none).
"""
function strecg(w::Wfdb, s::OptByteStr)
    str = s === nothing ? UInt8[] : cstr(bytes(s))
    for code in 1:ACMAX
        w.ann.cstring[code+1] == str && return Int32(code)
    end
    NOTQRS
end

"""
    setecgstr([w], code, string) -> Int32

C `setecgstr`: modify a fixed mnemonic.
"""
function setecgstr(w::Wfdb, code::Integer, s::OptByteStr)
    if NOTQRS <= code <= ACMAX
        w.ann.cstring[code+1] = s === nothing ? UInt8[] : copy(cstr(bytes(s)))
        return Int32(0)
    end
    wfdb_error(w, "setecgstr: illegal annotation code %d\n", code % Int32)
    Int32(-1)
end

"""
    annstr([w], code) -> Vector{UInt8}

C `annstr`: the (possibly redefined) mnemonic of an annotation code (`[N]`
for codes outside 0..ACMAX).
"""
annstr(w::Wfdb, code::Integer) =
    _validcode(code) ? copy(w.ann.astring[code+1]) : cformat("[%d]", code % Int32)

"""
    strann([w], str) -> Int32

C `strann`: the annotation code of a mnemonic (`NOTQRS` if none).
"""
function strann(w::Wfdb, s::OptByteStr)
    str = s === nothing ? UInt8[] : cstr(bytes(s))
    for code in 1:ACMAX
        w.ann.astring[code+1] == str && return Int32(code)
    end
    NOTQRS
end

"""
    setannstr([w], code, string) -> Int32

C `setannstr`: redefine the mnemonic of an annotation code. With a positive
code, the change is recorded in the modification labels of output
annotation files written later; with a negative code (-code is modified),
it is not.
"""
function setannstr(w::Wfdb, code::Integer, s::OptByteStr)
    code = code % Int32
    mflag = code > 0
    mflag || (code = -code)
    if _validcode(code)
        str = s === nothing ? UInt8[] : cstr(bytes(s))
        if w.ann.astring[code+1] != str
            w.ann.astring[code+1] = copy(str)
            mflag && (w.ann.modified[code+1] = true)
        end
        return Int32(0)
    end
    wfdb_error(w, "setannstr: illegal annotation code %d\n", code)
    Int32(-1)
end

"""
    anndesc([w], code) -> Union{Vector{UInt8},Nothing}

C `anndesc`: the description of an annotation code (`nothing` if it has
none; `illegal annotation code` for codes outside 0..ACMAX).
"""
function anndesc(w::Wfdb, code::Integer)
    if _validcode(code)
        d = w.ann.tstring[code+1]
        return d === nothing ? nothing : copy(d)
    end
    Vector{UInt8}(b"illegal annotation code")
end

"""
    setanndesc([w], code, string) -> Int32

C `setanndesc`: redefine the description of an annotation code (see
[`setannstr`](@ref) for the sign of `code`).
"""
function setanndesc(w::Wfdb, code::Integer, s::OptByteStr)
    code = code % Int32
    mflag = code > 0
    mflag || (code = -code)
    if _validcode(code)
        str = s === nothing ? UInt8[] : cstr(bytes(s))
        if w.ann.tstring[code+1] != str
            w.ann.tstring[code+1] = copy(str)
            mflag && (w.ann.modified[code+1] = true)
        end
        return Int32(0)
    end
    wfdb_error(w, "setanndesc: illegal annotation code %d\n", code)
    Int32(-1)
end

# ---------------------------------------------------------------------------
# Time resolution

"""
    setafreq([w], f)

C `setafreq`: set the time resolution (ticks per second) of output
annotation files opened later (0: the sampling frequency).
"""
setafreq(w::Wfdb, f::Real) = (w.ann.oafreq = Float64(f); nothing)

"""
    getafreq([w]) -> Float64

C `getafreq`: the time resolution of output annotation files.
"""
getafreq(w::Wfdb) = w.ann.oafreq

"""
    setiafreq([w], n, f)

C `setiafreq`: set the time resolution in which the times of the
annotations of input annotator `n` are returned.
"""
function setiafreq(w::Wfdb, n::Integer, f::Real)
    f = Float64(f)
    k = Int(n % UInt32)
    k >= length(w.ann.iad) && return nothing
    ia = w.ann.iad[k+1]
    tmul = if f > 0.0 && ia.afreq > 0.0
        f / ia.afreq
    elseif f > 0.0
        sfreq = sampfreq(w, nothing)
        sfreq > 0.0 ? f * getspf(w) / sfreq : 1.0
    else
        1.0
    end
    ia.tmul = tmul
    ia.ann.time = _round_to_time(ia.ann_tt * ia.tmul)
    ia.pann.time = _round_to_time(ia.pann_tt * ia.tmul)
    ia.prev_time = _round_to_time(ia.prev_tt * ia.tmul)
    nothing
end

"""
    getiafreq([w], n) -> Float64

C `getiafreq`: the time resolution of the annotation times returned for
input annotator `n` (-2 if `n` is not open).
"""
function getiafreq(w::Wfdb, n::Integer)
    k = Int(n % UInt32)
    if k < length(w.ann.iad)
        ia = w.ann.iad[k+1]
        ia.afreq > 0.0 && return ia.afreq * ia.tmul
        return sampfreq(w, nothing) * ia.tmul / getspf(w)
    end
    -2.0
end

"""
    getiaorigfreq([w], n) -> Float64

C `getiaorigfreq`: the time resolution recorded in the file of input
annotator `n` (0 if none; -2 if `n` is not open).
"""
function getiaorigfreq(w::Wfdb, n::Integer)
    k = Int(n % UInt32)
    k < length(w.ann.iad) ? w.ann.iad[k+1].afreq : -2.0
end

# ---------------------------------------------------------------------------
# Closing annotators

"""
    iannclose([w], n)

C `iannclose`: close input annotator `n` (the annotators after it are
renumbered, as in C).
"""
function iannclose(w::Wfdb, n::Integer)
    k = Int(n % UInt32)
    if k < length(w.ann.iad)
        ia = popat!(w.ann.iad, k + 1)
        fclose(ia.file)
    end
    nothing
end

"""
    oannclose([w], n)

C `oannclose`: close output annotator `n`, writing its end mark. If its
annotations were not written in canonical order, they are sorted by running
`sortann` (unless the environment variable `WFDBANNSORT` is 0).
"""
function oannclose(w::Wfdb, n::Integer)
    k = Int(n % UInt32)
    k >= length(w.ann.oad) && return nothing
    oa = popat!(w.ann.oad, k + 1)
    f = oa.file
    if oa.info.stat == WFDB_WRITE           # write logical EOF for MIT-format files
        wfdb_p16(f, 0)
    elseif oa.info.stat == WFDB_AHA_WRITE   # write logical EOF for AHA-format files
        pos = Int64(ftell(f) % UInt32)
        for _ in 1:_ABLKSIZ-pos%_ABLKSIZ
            putc(f, _EOAF)
        end
    end
    errflag = ferror(f)
    fclose(f) != 0 && (errflag = true)
    name = copy(cstr(oa.info.name))
    if errflag
        wfdb_error(w, "oannclose: write error on annotation file %s\n", name)
        w.ann.annclose_error = -7
    end
    out_of_order = oa.out_of_order
    if out_of_order
        p = cgetenv("WFDBANNSORT")
        dosort = p === nothing ? DEFWFDBANNSORT : strtol(p, 10)[1] % Int32
        if dosort != 0
            wfdb_error(w, "Rearranging annotations for output annotator %s ...", name)
            if run_sortann(oa.rname, name) == 0
                wfdb_error(w, "done!\n")
                out_of_order = false
            else
                wfdb_error(w, "\nAnnotations still need to be rearranged.\n")
            end
            w.ann.annclose_error == 0 && (w.ann.annclose_error = -6)
        end
    end
    if out_of_order
        wfdb_error(w, "Use the command:\n  sortann -r %s -a %s\n", oa.rname, name)
        wfdb_error(w, "to rearrange annotations in the correct order.\n")
        w.ann.annclose_error == 0 && (w.ann.annclose_error = -6)
    end
    nothing
end

# ---------------------------------------------------------------------------
# Default-instance methods

annopen(record::OptByteStr, aiarray::AbstractVector{Anninfo}, nann::Integer) =
    annopen(lib(), record, aiarray, nann)
getann(n::Integer, annot::Annotation) = getann(lib(), n, annot)
ungetann(n::Integer, annot::Annotation) = ungetann(lib(), n, annot)
putann(n::Integer, annot::Annotation) = putann(lib(), n, annot)
iannsettime(t::Integer) = iannsettime(lib(), t)
ecgstr(code::Integer) = ecgstr(lib(), code)
strecg(s::OptByteStr) = strecg(lib(), s)
setecgstr(code::Integer, s::OptByteStr) = setecgstr(lib(), code, s)
annstr(code::Integer) = annstr(lib(), code)
strann(s::OptByteStr) = strann(lib(), s)
setannstr(code::Integer, s::OptByteStr) = setannstr(lib(), code, s)
anndesc(code::Integer) = anndesc(lib(), code)
setanndesc(code::Integer, s::OptByteStr) = setanndesc(lib(), code, s)
setafreq(f::Real) = setafreq(lib(), f)
getafreq() = getafreq(lib())
setiafreq(n::Integer, f::Real) = setiafreq(lib(), n, f)
getiafreq(n::Integer) = getiafreq(lib(), n)
getiaorigfreq(n::Integer) = getiaorigfreq(lib(), n)
iannclose(n::Integer) = iannclose(lib(), n)
oannclose(n::Integer) = oannclose(lib(), n)
wfdb_anclose() = wfdb_anclose(lib())
wfdb_oaflush() = wfdb_oaflush(lib())

export annopen, getann, ungetann, putann, iannsettime, ecgstr, strecg, setecgstr, annstr,
       strann, setannstr, anndesc, setanndesc, setafreq, getafreq, setiafreq, getiafreq,
       getiaorigfreq, iannclose, oannclose
