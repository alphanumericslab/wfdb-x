# edf2mit: convert EDF (European Data Format) file to MIT format header and
# signal files.
#
# As in the C program, the header fields are read into one reusable 81-byte
# buffer, so a 16-character signal label is followed by a space and by the
# bytes that remain in the buffer from earlier fields (see
# docs/KNOWN_C_BEHAVIORS.md). Where the C program has undefined behavior,
# this translation uses: 0 for header fields that cannot be parsed and are
# left uninitialized in C; the characters of the input file name only (not
# the bytes beyond its end) for the default record name; 0 for samples
# beyond the end of a data record (if the samples per frame do not divide
# the samples per record); 0 frames per record if a signal has 0 samples per
# frame; and INT_MIN for out-of-range conversions of doubles to int (as on
# x86).
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of convert/edf2mit.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior).
#
# Original C program: convert/edf2mit.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1996-2004 George B. Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

"Size of the C program's header field buffer (the longest field is 80 bytes)."
const _EDF2MIT_BUFLEN = 81
"Lengths of the fields of the fixed part of an EDF header."
const _EDF_VERSION_LEN = 8
const _EDF_ID_LEN = 80
const _EDF_SHORT_LEN = 8
const _EDF_RESERVED_LEN = 44
const _EDF_NSIG_LEN = 4
"Lengths of the per-signal fields of an EDF header."
const _EDF_LABEL_LEN = 16
const _EDF_SIGRESERVED_LEN = 32
"Bytes per EDF sample."
const _EDF_SAMPLE_BYTES = 2
"Relative tolerance of the gcd of sampling frequencies."
const _EDF2MIT_GCD_TOL = 0.001
"First year represented by a two-digit EDF year (with the 1900 offset)."
const _EDF2MIT_EPOCH = 1970

const _EDF2MIT_HELP = (
    "usage: %s [OPTIONS ...]\n",
    "where OPTIONS may include:",
    " -b          input is in big-endian byte order (default: little-endian)",
    " -h          print this usage summary",
    " -i EDFILE   read the specified European Data Format file",
    " -r RECORD   create the specified RECORD (default: input file name without",
    "              suffix)",
    " -s SIGNAL [SIGNAL ...]  copy only the specified signal(s) (use signal",
    "              numbers, beginning with zero;  default: copy all signals)",
    " -v          print debugging output",
    "This program reads an EDF file and creates MIT-format signal and header",
    "files containing the same data.")

# Usage summary (help strings: a format for the program name, then lines);
# shared by the converters (edf2mit, mit2edf, rdedfann, wav2mit, mit2wav,
# wfdb2mat).
function _convert_help(pname, help)
    ceprintf(help[1], pname)
    for k in 2:length(help)
        ceprintf("%s\n", help[k])
    end
end

# Calculate the greatest common divisor of x and y. This function uses
# Euclid's algorithm, modified so that an exact answer is not required if
# the (possibly non-integral) arguments do not have a common divisor that
# can be represented exactly.
function _edf2mit_gcd(x::Float64, y::Float64)
    tol = _EDF2MIT_GCD_TOL * (x > y ? y : x)
    while true
        if x > y && x - y > tol
            x -= y
        elseif y > x && y - x > tol
            y -= x
        else
            return x
        end
    end
end

# Read a header field of n bytes into buf, mark its end with a space, and
# replace trailing spaces (from C index t backward) with NULs. Returns the
# C index of the last non-space character (or -1).
function _edf2mit_field!(buf::Vector{UInt8}, f::WfdbFile, n::Integer, t::Integer = n)
    fread!(f, buf, n)
    buf[n+1] = UInt8(' ')
    j = Int(t)
    while j >= 0 && buf[j+1] == UInt8(' ')
        buf[j+1] = 0x00
        j -= 1
    end
    j
end

function edf2mit_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    wfdbx_legacy_args(args)
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "edf2mit"
    record = UInt8[]
    ifile = nothing
    big_endian = false
    vflag = false
    siglist = Int32[]
    day, month, year = Ref{Int32}(0), Ref{Int32}(0), Ref{Int32}(0)
    hour, minute, second = Ref{Int32}(0), Ref{Int32}(0), Ref{Int32}(0)
    dref = Ref{Float64}(0.0)
    iref = Ref{Int32}(0)
    lref = Ref{Int64}(0)

    i = 1
    while i < argc
        a = argv[i]
        if !isempty(a) && a[1] == UInt8('-')
            c = length(a) >= 2 ? a[2] : 0x00
            if c == UInt8('b')          # input is in big-endian byte order
                big_endian = true
            elseif c == UInt8('h')      # show usage and quit
                _convert_help(pname, _EDF2MIT_HELP)
                cexit(0)
            elseif c == UInt8('i')      # file name follows
                i += 1
                if i < argc
                    if cstr(argv[i]) == b"-"
                        ifile = wfdb_stdin()
                    else
                        ifile = cfopen(argv[i], "rb")
                        if ifile === nothing
                            ceprintf("%s: can't read %s\n", pname, argv[i])
                            cexit(1)
                        end
                        if isempty(record)
                            name = cstr(argv[i])
                            for k in 1:min(length(name), WFDB_MAXRNL)
                                ch = name[k]
                                if c_isalnum(ch)
                                    push!(record, ch)
                                elseif ch == UInt8('.')
                                    break
                                else
                                    push!(record, UInt8('_'))
                                end
                            end
                        end
                    end
                end
            elseif c == UInt8('r')      # record name follows
                i += 1
                if i < argc
                    r = cstr(argv[i])
                    record = r[1:min(length(r), WFDB_MAXRNL)]
                else
                    ceprintf("%s: record name must follow -r\n", pname)
                    cexit(1)
                end
            elseif c == UInt8('s')      # signal list follows
                # count the number of output signals
                j = 0
                while true
                    i += 1
                    (i < argc && !(!isempty(argv[i]) && argv[i][1] == UInt8('-'))) || break
                    j += 1
                end
                if j == 0
                    ceprintf("%s: signal list must follow -s\n", pname)
                    cexit(1)
                end
                # fill the signal list
                i -= j
                while i < argc && !(!isempty(argv[i]) && argv[i][1] == UInt8('-'))
                    push!(siglist, atoi(argv[i]))
                    i += 1
                end
                i -= 1
            elseif c == UInt8('v')      # select verbose mode
                vflag = true
            end
        end
        i += 1
    end
    nosig = length(siglist)

    if ifile === nothing
        _convert_help(pname, _EDF2MIT_HELP)
        cexit(1)
    end

    if isempty(record) || newheader(record) < 0
        ceprintf("\n")
        _convert_help(pname, _EDF2MIT_HELP)
        ceprintf("\nRun %s again, specifying a valid name for the output record,\n", pname)
        ceprintf("using the -r option as described above.\n\n")
        ceprintf("  Valid record names may include letters, digits, and underscores only.\n")
        cexit(1)
    end

    buf = zeros(UInt8, _EDF2MIT_BUFLEN)
    fread!(ifile, buf, _EDF_VERSION_LEN)
    # Check to see that the input is an EDF file. (This check will detect
    # most but not all other types of files.)
    if view(buf, 1:_EDF_VERSION_LEN) != b"0       "
        ceprintf("%s: input does not appear to be EDF -- no conversion attempted.\n", pname)
        cexit(2)
    end
    buf[_EDF_VERSION_LEN+1] = UInt8(' ')
    j = _EDF_VERSION_LEN
    while j >= 0 && buf[j+1] == UInt8(' ')
        buf[j+1] = 0x00
        j -= 1
    end
    vflag && cprintf("EDF version number: '%s'\n", cstr(buf))

    _edf2mit_field!(buf, ifile, _EDF_ID_LEN)
    vflag && cprintf("Patient ID: '%s'\n", cstr(buf))

    _edf2mit_field!(buf, ifile, _EDF_ID_LEN)
    vflag && cprintf("Recording ID: '%s'\n", cstr(buf))

    _edf2mit_field!(buf, ifile, _EDF_SHORT_LEN)
    vflag && cprintf("Recording date: '%s'\n", cstr(buf))
    csscanf(cstr(buf), "%d%*c%d%*c%d", day, month, year)
    year[] < _EDF2MIT_EPOCH && (year[] += Int32(1900))
    year[] < _EDF2MIT_EPOCH && (year[] += Int32(100))    # should work for a while

    _edf2mit_field!(buf, ifile, _EDF_SHORT_LEN)
    vflag && cprintf("Recording time: '%s'\n", cstr(buf))
    csscanf(cstr(buf), "%d%*c%d%*c%d", hour, minute, second)

    _edf2mit_field!(buf, ifile, _EDF_SHORT_LEN)
    vflag && cprintf("Number of bytes in header record: '%s'\n", cstr(buf))

    j = _edf2mit_field!(buf, ifile, _EDF_RESERVED_LEN)
    j > 0 && vflag && cprintf("Free space: '%s'\n", cstr(buf))

    _edf2mit_field!(buf, ifile, _EDF_SHORT_LEN)
    vflag && cprintf("Number of data records: '%s'\n", cstr(buf))

    _edf2mit_field!(buf, ifile, _EDF_SHORT_LEN)
    vflag && cprintf("Duration of each data record in seconds: '%s'\n", cstr(buf))
    dref[] = 0.0
    csscanf(cstr(buf), "%lf", dref)
    spr = dref[] <= 0.0 ? 1.0 : dref[]

    _edf2mit_field!(buf, ifile, _EDF_NSIG_LEN)
    vflag && cprintf("Number of signals: '%s'\n", cstr(buf))
    iref[] = 0
    csscanf(cstr(buf), "%d", iref)
    nsig = iref[]

    nsig < 1 && cexit(1)
    ns = Int(nsig)

    si = [Siginfo() for _ in 1:ns]
    spb = zeros(Int32, ns)
    sigdmax = zeros(Int64, ns)
    sigdmin = zeros(Int64, ns)
    sigpmax = zeros(Float64, ns)
    sigpmin = zeros(Float64, ns)
    sampfreq = zeros(Float64, ns)

    if nosig == 0                   # initialize signal list if necessary
        siglist = collect(Int32(0):nsig-Int32(1))
        nosig = ns
    else
        for s in siglist
            if s < 0 || s >= nsig
                ceprintf("%s: invalid signal number, %d, in signal list\n", pname, s)
                cexit(1)
            end
        end
    end
    sl = Int[s + 1 for s in siglist]   # 1-based signal indices

    for i in 1:ns
        _edf2mit_field!(buf, ifile, _EDF_LABEL_LEN, _EDF_LABEL_LEN - 1)
        vflag && cprintf("Signal %d label: '%s'\n", Int32(i - 1), cstr(buf))
        si[i].desc = copy(cstr(buf))
    end

    for i in 1:ns
        j = _edf2mit_field!(buf, ifile, _EDF_ID_LEN)
        vflag && j > 0 && cprintf("Signal %d transducer type: '%s'\n", Int32(i - 1), cstr(buf))
    end

    for i in 1:ns
        _edf2mit_field!(buf, ifile, _EDF_SHORT_LEN)
        vflag && cprintf("Signal %d physical dimension: '%s'\n", Int32(i - 1), cstr(buf))
        si[i].units = copy(cstr(buf))
    end

    for i in 1:ns
        _edf2mit_field!(buf, ifile, _EDF_SHORT_LEN)
        vflag && cprintf("Signal %d physical minimum: '%s'\n", Int32(i - 1), cstr(buf))
        dref[] = sigpmin[i]
        csscanf(cstr(buf), "%lf", dref)
        sigpmin[i] = dref[]
    end

    for i in 1:ns
        _edf2mit_field!(buf, ifile, _EDF_SHORT_LEN)
        vflag && cprintf("Signal %d physical maximum: '%s'\n", Int32(i - 1), cstr(buf))
        dref[] = sigpmax[i]
        csscanf(cstr(buf), "%lf", dref)
        sigpmax[i] = dref[]
    end

    for i in 1:ns
        _edf2mit_field!(buf, ifile, _EDF_SHORT_LEN)
        vflag && cprintf("Signal %d digital minimum: '%s'\n", Int32(i - 1), cstr(buf))
        lref[] = sigdmin[i]
        csscanf(cstr(buf), "%ld", lref)
        sigdmin[i] = lref[]
    end

    for i in 1:ns
        _edf2mit_field!(buf, ifile, _EDF_SHORT_LEN)
        vflag && cprintf("Signal %d digital maximum: '%s'\n", Int32(i - 1), cstr(buf))
        lref[] = sigdmax[i]
        csscanf(cstr(buf), "%ld", lref)
        sigdmax[i] = lref[]
    end

    for i in 1:ns
        if sigpmax[i] == sigpmin[i]
            ceprintf("gain for signal %d is undefined\n", Int32(i - 1))
            continue
        end
        s = si[i]
        s.adczero = ((sigdmax[i] + 1 + sigdmin[i]) ÷ 2) % Int32
        adcrange = sigdmax[i] - sigdmin[i]
        s.gain = adcrange / (sigpmax[i] - sigpmin[i])
        bits = Int32(0)
        while adcrange > 1
            adcrange ÷= 2
            bits += Int32(1)
        end
        s.adcres = bits
        s.baseline = d2i(sigdmax[i] - sigpmax[i] * s.gain + 1)
    end

    for i in 1:ns
        j = _edf2mit_field!(buf, ifile, _EDF_ID_LEN)
        vflag && j > 0 && cprintf("Signal %d filtering information: '%s'\n", Int32(i - 1), cstr(buf))
    end

    for i in 1:ns
        _edf2mit_field!(buf, ifile, _EDF_SHORT_LEN)
        vflag && cprintf("Signal %d number of samples per record: '%s'\n", Int32(i - 1), cstr(buf))
        b = cstr(buf)
        dref[] = sampfreq[i]
        csscanf(b, "%lf", dref)
        sampfreq[i] = dref[]
        iref[] = spb[i]
        csscanf(b, "%d", iref)
        spb[i] = iref[]
        sampfreq[i] /= spr
    end

    for i in 1:ns
        j = _edf2mit_field!(buf, ifile, _EDF_SIGRESERVED_LEN)
        vflag && j > 0 && cprintf("Signal %d free space: '%s'\n", Int32(i - 1), cstr(buf))
    end

    # Determine the base sampling frequency (the greatest common divisor of
    # all sampling frequencies for the signals in the signal list)
    sps = sampfreq[sl[1]]
    for k in 2:nosig
        sampfreq[sl[k]] != sps && (sps = _edf2mit_gcd(sps, sampfreq[sl[k]]))
    end
    setsampfreq(sps)

    bt = cformat("%02d:%02d:%02d %02d/%02d/%04d", hour[], minute[], second[], day[], month[], year[])
    length(bt) >= _EDF2MIT_BUFLEN && resize!(bt, _EDF2MIT_BUFLEN - 1)
    setbasetime(bt)

    fname = vcat(record, b".dat")
    so = Siginfo[]
    for s in sl
        si[s].fname = fname
        si[s].fmt = 16
        si[s].spf = d2i(sampfreq[s] / sps + 0.5)
        push!(so, copy(si[s]))
    end

    spf1 = si[sl[1]].spf
    fpb = spf1 != 0 ? spb[sl[1]] ÷ spf1 : Int32(0)

    vflag && cprintf("\nOUTPUT:\nBase sampling frequency: %g Hz\n", sps)
    if vflag
        for (k, s) in enumerate(sl)
            n = si[s].spf
            cprintf(" Signal %d samples per second: %g (%d sample%s per frame)\n",
                    Int32(k - 1), sampfreq[s], n, n > 1 ? "s" : "")
        end
    end

    vin = [zeros(UInt8, max(Int(spb[k]), 0) * _EDF_SAMPLE_BYTES) for k in 1:ns]
    vi = zeros(Int, nosig)          # C offsets within vin[siglist[j]]
    vout = zeros(Int32, sum(o -> max(Int(o.spf), 0), so))
    osigfopen(so, nosig)
    while true
        nread = 0
        for k in 1:ns
            nread = spb[k] > 0 ? fread!(ifile, vin[k], _EDF_SAMPLE_BYTES, spb[k]) : 0
        end
        nread == 0 && break
        fill!(vi, 0)
        for _ in 1:fpb
            vo = 0
            for k in 1:nosig
                v = vin[sl[k]]
                for _ in 1:so[k].spf
                    p = vi[k]
                    b0 = p < length(v) ? Int32(reinterpret(Int8, v[p+1])) : Int32(0)
                    b1 = p + 1 < length(v) ? Int32(reinterpret(Int8, v[p+2])) : Int32(0)
                    vi[k] += _EDF_SAMPLE_BYTES
                    h, l = big_endian ? (b0, b1) : (b1, b0)
                    vo += 1
                    vout[vo] = Int32(((h << 8) | (l & Int32(0xff))) % Int16)
                end
            end
            putvec(vout)
        end
    end
    is_std(ifile) || fclose(ifile)

    newheader(record)
    wfdbquit()
    cexit(0)
end

register_workload("edf2mit") do
    with_workload_data() do dir
        for f in ("fmt16.edf", "100s.edf", "edfp.edf")
            workload_tool("edf2mit", "-i", f)
            workload_tool("edf2mit", "-i", f, "-r", "e2m", "-v")
        end
        workload_tool("edf2mit", "-i", "fmt16.edf", "-r", "e2m", "-s", "2", "0")
        workload_tool("edf2mit", "-i", "fmt16.edf", "-r", "e2m", "-s", "5")
        workload_tool("edf2mit", "-i", "fmt16.edf", "-r", "e2m", "-b")
        workload_tool("edf2mit", "-i", "100s.hea", "-r", "e2m")
        workload_tool("edf2mit", "-i", "nosuch.edf")
        workload_tool("edf2mit", "-i", "fmt16.edf", "-r", "bad*name")
        workload_tool("edf2mit", "-i", "-", "-r", "e2s"; stdin=read("fmt16.edf"))
        workload_tool("edf2mit", "-s")
        workload_tool("edf2mit", "-h")
        workload_tool("edf2mit", "-r")
        workload_tool("edf2mit")
    end
end
