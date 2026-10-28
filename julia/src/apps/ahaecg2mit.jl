# ahaecg2mit: convert *.ecg or *.txt files from an AHA Database DVD to
# WFDB-compatible format.
#
# Behaviors of the C program that are undefined are resolved as in the other
# WFDB-x implementations (see docs/KNOWN_C_BEHAVIORS.md): the 16-byte line
# buffer of readtxtdata keeps the bytes of earlier lines of the same input
# file and is not NUL-terminated (bytes beyond it are treated as NUL), and
# the record name is made of the (up to 4) characters that precede the
# extension. The line buffer, the samples and the annotation are reset for
# each input file; with -s, a record name of fewer than 2 characters is left
# unchanged.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of convert/ahaecg2mit.c from the WFDB Software
# Package 10.7.0, by George B. Moody. The translation follows the logic and
# behavior of the original program, but it is new code, not the original C
# code.
#
# Changes from the original: no built-in signal parameters: the new options -F
# FREQ, -G GAIN, -R BITS and -U UNITS give the sampling frequency, gain, ADC
# resolution and units, and are required (-U unless the gain is 0; the original
# assumed those of the AHA database: 250 Hz, 400 adu/mV, 12 bits and
# millivolts); the options precede the input files, in any order; the
# short-format part of a long-format file (skipped by -s) is located from -F;
# --legacy, as the first argument, restores the original behavior. Each change
# is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
#
# Original C program: convert/ahaecg2mit.c, WFDB Software Package 10.7.0.
#   By George B. Moody (2008); revised 2017 by Benjamin Moody. The C source has
#   no copyright or license notice.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

const _AHAECG_FMT = Int32(212)      # output signal format
const _AHAECG_BINSIZE = 5           # bytes per sample frame in .ecg files
const _AHAECG_TXTBUF = 16           # size of readtxtdata's line buffer
const _AHAECG_NAMELEN = 4           # AHA record names are 4 (ASCII) digits
# A long-format AHA record begins with 145 minutes that are not part of the
# short-format (35-minute) record (skipped by -s).
const _AHAECG_SKIP_MINUTES = 145

# WFDB-x: the signal parameters (-F, -G, -R, -U); the C program assumed those
# of the AHA database (250 Hz, 400 adu/mV, 12 bits, millivolts).
struct _AhaecgParams
    freq::Float64
    gain::Float64
    adcres::Int32
    units::Union{Nothing,Vector{UInt8}}
end
# The parameters of the AHA database (legacy mode: those set by the C program)
const _AHAECG_AHA_PARAMS = _AhaecgParams(250.0, 400.0, Int32(12), Vector{UInt8}(b"mV"))
const _AHAECG_SHORT_NAME = 2        # -s adds this to the second digit of the name

# The state of the C program (its global variables), reset for each input
# file.
mutable struct _AhaecgState
    format::Int                     # 1: .ecg (binary), 2: .txt
    ifile::WfdbFile
    a::Annotation
    v::Vector{Int32}
    txtbuf::Vector{UInt8}           # readtxtdata's line buffer
    scan_v0::Base.RefValue{Int64}
    scan_v1::Base.RefValue{Int64}
    scan_c::Base.RefValue{UInt8}
end

_AhaecgState(format::Int, ifile::WfdbFile) =
    _AhaecgState(format, ifile, Annotation(), zeros(Int32, 2), zeros(UInt8, _AHAECG_TXTBUF),
                 Ref{Int64}(0), Ref{Int64}(0), Ref{UInt8}(0))

# Set the annotation from an AHA label; `U' (unreadable data) is subtype -1.
function _ahaecg_setann(st::_AhaecgState, label::Int8)
    st.a.anntyp = ammap(label) % Int8
    st.a.subtyp = label == Int8('U') ? Int8(-1) : Int8(0)
end

# Read a sample pair (and label) from a .ecg file: 0 at end of file, 1 for
# samples, 2 for samples and an annotation.
function _ahaecg_readbindata(st::_AhaecgState, data::Vector{UInt8})
    fread!(st.ifile, data, 1, _AHAECG_BINSIZE) != _AHAECG_BINSIZE && return 0  # EOF
    st.v[1] = Int32(data[1]) | (Int32(data[2]) << 8)
    st.v[2] = Int32(data[3]) | (Int32(data[4]) << 8)
    data[5] == UInt8('.') && return 1   # samples, no annotation
    _ahaecg_setann(st, data[5] % Int8)
    2                                   # samples and annotation
end

# Read a line `V0,V1,"L"' from a .txt file (as readbindata).
function _ahaecg_readtxtdata(st::_AhaecgState)
    buf = st.txtbuf
    c = Int8(0)                     # C char (signed)
    for i in 1:_AHAECG_TXTBUF
        c = getc(st.ifile) % Int8
        (c == Int8('\r') || c == EOF || c == Int8('\n')) && break
        buf[i] = c % UInt8
    end
    c == EOF && return 0
    s = cstr(buf)
    st.scan_v0[] = st.v[1]
    st.scan_v1[] = st.v[2]
    n = csscanf(s, "%ld,%ld,\"%c", st.scan_v0, st.scan_v1, st.scan_c)
    n >= 1 && (st.v[1] = st.scan_v0[] % Int32)
    n >= 2 && (st.v[2] = st.scan_v1[] % Int32)
    n >= 3 && (c = st.scan_c[] % Int8)
    if n < 3
        ceprintf("Error: improperly formatted input!\n")
        ceprintf(" n = %d, buf = |%s|, v[0] = %d, v[1] = %d, c = |%c|\n",
                 n, s, st.v[1], st.v[2], c)
        return 0
    end
    c == Int8('"') && return 1      # samples, no annotation
    _ahaecg_setann(st, c)
    2                               # samples and annotation
end

function _ahaecg_process(st::_AhaecgState, record::Vector{UInt8}, par::_AhaecgParams)
    t = Int64(-1)

    setsampfreq(par.freq)           # WFDB-x: -F (the C program set 250 Hz)
    ofname = append!(copy(record), b".dat")
    un() = par.units === nothing ? nothing : copy(par.units)
    si = [Siginfo(fname=ofname, desc=Vector{UInt8}(b"ECG0"), units=un(),
                  gain=par.gain, fmt=_AHAECG_FMT, adcres=par.adcres),
          Siginfo(fname=copy(ofname), desc=Vector{UInt8}(b"ECG1"), units=un(),
                  gain=par.gain, fmt=_AHAECG_FMT, adcres=par.adcres)]
    ai = [Anninfo(b"atr", WFDB_WRITE)]
    if osigfopen(si, 2) != 2 || annopen(record, ai, 1) < 0
        wfdbquit()
        return
    end
    if st.format == 1
        # (the time counter is incremented after the annotation is written:
        # see docs/KNOWN_C_BEHAVIORS.md)
        data = Vector{UInt8}(undef, _AHAECG_BINSIZE)
        while (stat = _ahaecg_readbindata(st, data)) != 0
            putvec(st.v)
            if stat > 1
                st.a.time = t
                putann(0, st.a)
            end
            t += 1
        end
    else
        while (stat = _ahaecg_readtxtdata(st)) != 0
            t += 1
            putvec(st.v)
            if stat > 1
                st.a.time = t
                putann(0, st.a)
            end
        end
    end
    newheader(record)
    wfdbquit()
    ceprintf("wrote %s.atr, %s.dat, and %s.hea\n", record, record, record)
    nothing
end

# WFDB-x: the options of ahaecg2mit (-s and the signal parameters, which
# precede the input files, in any order): returns the index of the first
# input file, the -s flag, and the signal parameters.
function _ahaecg_options(pname::String, argv::Vector{Vector{UInt8}}, argc::Int)
    sflag = false
    ffreq = Ref{Float64}(0.0)
    ggain = Ref{Float64}(0.0)
    rres = Ref{Int32}(0)
    gset = false
    uunits = nothing
    i = 1
    while i < argc && length(argv[i]) == 2 && argv[i][1] == UInt8('-') &&
          argv[i][2] in b"sFGRU"
        c = argv[i][2]
        if c == UInt8('s')
            sflag = true            # produce short-format (35-minute) records
        elseif c == UInt8('F')      # sampling frequency (WFDB-x)
            i += 1
            if i >= argc || csscanf(argv[i], "%lf", ffreq) != 1 || ffreq[] <= 0.0
                ceprintf("%s: sampling frequency (> 0) must follow -F\n", pname)
                cexit(1)
            end
        elseif c == UInt8('G')      # gain in adu per physical unit (WFDB-x)
            i += 1
            if i >= argc || csscanf(argv[i], "%lf", ggain) != 1 || ggain[] < 0.0
                ceprintf("%s: gain (>= 0) must follow -G\n", pname)
                cexit(1)
            end
            gset = true
        elseif c == UInt8('R')      # ADC resolution in bits (WFDB-x)
            i += 1
            if i >= argc || csscanf(argv[i], "%d", rres) != 1 || rres[] < 1 || rres[] > 32
                ceprintf("%s: ADC resolution (1-32 bits) must follow -R\n", pname)
                cexit(1)
            end
        else                        # physical units (WFDB-x)
            i += 1
            if i >= argc
                ceprintf("%s: units must follow -U\n", pname)
                cexit(1)
            end
            uunits = copy(cstr(argv[i]))
        end
        i += 1
    end
    # WFDB-x: the signal parameters must be given explicitly (see
    # docs/DIVERGENCES.md).
    if ffreq[] <= 0.0
        ceprintf("%s: the sampling frequency must be specified (-F)\n", pname)
        cexit(1)
    end
    if !gset
        ceprintf("%s: the gain must be specified (-G)\n", pname)
        cexit(1)
    end
    if rres[] < 1
        ceprintf("%s: the ADC resolution must be specified (-R)\n", pname)
        cexit(1)
    end
    if ggain[] != 0.0 && uunits === nothing
        ceprintf("%s: the units must be specified (-U)\n", pname)
        cexit(1)
    end
    i, sflag, _AhaecgParams(ffreq[], ggain[], rres[], uunits)
end

function ahaecg2mit_main(args::Vector{String})
    # WFDB-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "ahaecg2mit"            # (C argv[0])
    sflag = false

    if argc < 2 || argv[1] == b"-h"
        if legacy                   # WFDB-x: the usage of the C program
            ceprintf("usage: %s [-s] RECORD.XXX [RECORD.XXX]...\n", pname)
        else
            ceprintf("usage: %s [-s] -F FREQ -G GAIN -R BITS -U UNITS RECORD.XXX [RECORD.XXX]...\n",
                     pname)
        end
        ceprintf(" where RECORD.XXX is the name of the AHA DVD input file to be converted\n" *
                 " ('RECORD' is one of the 4-digit AHA DB record names, and 'XXX' may be either\n" *
                 " 'ecg' or 'txt', depending on the version of the AHA DVD.)\n" *
                 " Output files are RECORD.hea (text), RECORD.atr (binary), RECORD.dat (binary).\n" *
                 " Two or more input files may be converted in a single run.\n" *
                 " Use -s to make short-format (35-minute) records from long-format (2.5 hour)\n" *
                 " input files.  When using -s, the second digit in the output record name is\n" *
                 " incremented by 2.\n")
        legacy ||
            ceprintf(" -F, -G, -R and -U give the sampling frequency (Hz), gain (adu per physical\n" *
                     " unit), ADC resolution (bits) and units of the signals; for the AHA DVD\n" *
                     " files, use -F 250 -G 400 -R 12 -U mV.\n")
        cexit(1)
    end
    i = 1
    if legacy
        # WFDB-x: in legacy mode, the option of the C program (-s only, as the
        # first argument), and the parameters of the AHA database that it set
        # (250 Hz, 400 adu/mV, 12 bits, millivolts).
        if argv[1] == b"-s"
            sflag = true            # produce short-format (35-minute) records
            i = 2
        end
        par = _AHAECG_AHA_PARAMS
    else
        i, sflag, par = _ahaecg_options(pname, argv, argc)
    end
    # samples in the skipped part of a long-format record
    nskip = unsafe_trunc(Int64, _AHAECG_SKIP_MINUTES * 60 * par.freq)
    while i < argc
        arg = argv[i]
        len = length(arg)
        p = max(len - 4, 0)         # position of '.ecg' or '.txt' (0-based)
        ext = @view arg[p+1:end]
        format = if len >= 4 && (ext == b".ecg" || ext == b".ECG")
            1
        elseif len >= 4 && (ext == b".txt" || ext == b".TXT")
            2
        else
            ceprintf("%s: ignoring '%s'\n", pname, arg)
            i += 1
            continue                # not an .ecg or .txt file
        end
        ifile = cfopen(arg, "rb")
        if ifile === nothing
            # (C names argv[1], whose extension may have been stripped)
            ceprintf("%s: can't open '%s'\n", pname, argv[1])
            i += 1
            continue
        end
        record = arg[max(p - _AHAECG_NAMELEN, 0)+1:p]
        resize!(arg, p)             # strip off the extension (in place, as C)
        st = _AhaecgState(format, ifile)
        if sflag
            # skip first 145 minutes if making a short-format record
            if format == 1
                fseek(st.ifile, nskip * _AHAECG_BINSIZE, SEEK_SET)
            else
                for _ in 1:nskip
                    _ahaecg_readtxtdata(st)
                end
            end
            # fix record name (n0nn->n2nn, n1nn->n3nn)
            length(record) > 1 && (record[2] += UInt8(_AHAECG_SHORT_NAME))
        end
        _ahaecg_process(st, record, par)
        fclose(st.ifile)
        i += 1
    end
    cexit(0)
end

register_workload("ahaecg2mit") do
    with_workload_data() do dir
        aha = ("-F", "250", "-G", "400", "-R", "12", "-U", "mV")
        workload_tool("ahaecg2mit", aha..., "1001.ecg")
        workload_tool("ahaecg2mit", "-s", aha..., "1001.ecg")
        workload_tool("ahaecg2mit", aha..., "1002.txt", "x.dat", "nosuch.txt", "")
        workload_tool("ahaecg2mit", "-s", aha..., "1002.txt")
        write("bad.txt", "1,2,\"N\"\r\n3,4,\"\"\"\r\nxyz\r\n")
        workload_tool("ahaecg2mit", aha..., "bad.txt")
        workload_tool("ahaecg2mit", "1001.ecg")
        workload_tool("ahaecg2mit", "-F", "250", "1001.ecg")
        workload_tool("ahaecg2mit", "-F", "250", "-G", "400", "-R", "12", "1001.ecg")
        workload_tool("ahaecg2mit", "-G", "400", "-s", "-R", "12", "-U", "mV", "-F", "125",
                      "1001.ecg")
        workload_tool("ahaecg2mit", "-F", "250", "-G", "0", "-R", "12", "1001.ecg")
        workload_tool("ahaecg2mit", "-R", "40")
        workload_tool("ahaecg2mit", "-h")
        workload_tool("ahaecg2mit")
        # WFDB-x: legacy mode (original behavior)
        workload_tool("ahaecg2mit", "--legacy", "1001.ecg")
        workload_tool("ahaecg2mit", "--legacy", "-s", "1002.txt")
        workload_tool("ahaecg2mit", "--legacy", "-F", "250", "1001.ecg")
        workload_tool("ahaecg2mit", "--legacy", "-h")
    end
end
