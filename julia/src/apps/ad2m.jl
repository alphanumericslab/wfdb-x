# ad2m: convert an AHA format signal file to MIT format.
#
# The input is either an AHA DB distribution tape format file (read as
# record `16`, two signals in format 16 on the standard input), or a
# compressed (*.CMP) file from an AHA DB CD-ROM or floppy diskette.
#
# Where the C program has undefined behavior (an input file name ending in
# `/` without -r, a record name of more than 7 characters, or a directory as
# input file), this translation uses an empty record name, the full signal
# file name, and reports the directory as unreadable (see
# docs/KNOWN_C_BEHAVIORS.md).
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of convert/ad2m.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in signal parameters: the new options -F
# FREQ, -G GAIN, -R BITS and -U UNITS give the sampling frequency, gain, ADC
# resolution and units, and are required (-U unless the gain is 0; the original
# assumed those of the AHA database: 250 Hz, 400 adu/mV, 12 bits and
# millivolts); the -f and -t times are converted at the -F frequency; --legacy,
# as the first argument, restores the original behavior. Each change is marked
# "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
#
# Original C program: convert/ad2m.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1983-2007 George B. Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

const _AD2M_HELP = (
    "usage: %s -i AHAFILE [ OPTIONS ... ]\n",
    "where AHAFILE is the name of the AHA-format input signal file,",
    "and OPTIONS may include:",
    " -c         process a compressed input file (default if AHAFILE ends",
    "             with .CMP or .cmp;  otherwise old AHA tape format assumed)",
    " -f TIME    begin at specified TIME (default: 0, i.e., the beginning",
    "             of the input file)",
    " -F FREQ    sampling frequency in Hz (required; AHA database: 250)",
    " -G GAIN    gain in adu per physical unit (required; AHA database: 400)",
    " -h         print this usage summary",
    # (two strings concatenated by a misplaced comma in C)
    " -r RECORD  specify the name of the output RECORD (default: use the," *
    "            input file name, less path info and extension, as RECORD)",
    " -R BITS    ADC resolution in bits (required; AHA database: 12)",
    " -t TIME    stop at specified TIME (default: 35 minutes after the",
    "             starting time if RECORD=x2xx or x3xx, 3 hours if",
    "             RECORD=x0xx or x1xx, or the end of the input file)",
    " -U UNITS   physical units (required unless the gain is 0; AHA: mV)")
# wfdb-x: the help text of the original program, printed in legacy mode
const _AD2M_LEGACY_HELP = _help_without(_AD2M_HELP, [8, 9, 12, 16])

const _AD2M_EODF = Int32(0o100000)  # AHA data file end-of-data marker
# The parameters of the AHA database (legacy mode: those set by the C program)
const _AD2M_AHA_FREQ = 250.0        # sampling frequency (Hz)
const _AD2M_AHA_GAIN = 400.0        # gain (adu/mV)
const _AD2M_AHA_ADCRES = Int32(12)  # ADC resolution (bits)
const _AD2M_FMT = Int32(212)        # output signal format
const _AD2M_TAPE_RECORD = "16"      # the record that reads tape-format input

# Reader of compressed-format input (the static variables of C's getcvec).
mutable struct _Ad2mCmp
    input::WfdbFile
    v0::Int32
    v1::Int32
end

# Read a pair of samples; 2 on success, 0 at end of file.
function _ad2m_getcvec(c::_Ad2mCmp, v::Vector{Int32})
    x = getc(c.input)
    x == EOF && return Int32(0)
    y = getc(c.input)
    if y == EOF
        ceprintf("unexpected EOF in input file\n")
        return Int32(0)
    end
    if (x & 0x80) == 0              # two 7- and 8-bit first differences
        c.v0 += x & Int32(0x7f)
        (x & 0x40) != 0 && (c.v0 -= Int32(128))
        c.v1 += y
        (y & 0x80) != 0 && (c.v1 -= Int32(256))
    else                            # two 14- and 16-bit first differences
        x = (x & 0x40) != 0 ? (x | ~Int32(0x3f)) : (x & Int32(0x7f))
        c.v0 += x * Int32(256) + y
        x = getc(c.input)
        x != EOF && (y = getc(c.input))
        if x == EOF || y == EOF
            ceprintf("unexpected EOF in input file\n")
            return Int32(0)
        end
        (x & 0x80) != 0 && (x |= ~Int32(0xff))
        c.v1 += x * Int32(256) + y
    end
    v[1] = c.v0
    v[2] = c.v1
    Int32(2)
end

function ad2m_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "ad2m"
    ifname = record = nothing
    cflag = false
    v = zeros(Int32, 2)
    t = start_time = end_time = Int64(0)
    # wfdb-x: the signal parameters (-F, -G, -R, -U), and the -f and -t
    # arguments (converted once -F is known)
    fstr = tstr = uunits = nothing
    ffreq = Ref{Float64}(0.0)
    ggain = Ref{Float64}(0.0)
    rres = Ref{Int32}(0)
    gset = false
    if legacy
        # wfdb-x: in legacy mode, the parameters of the AHA database, set by
        # the C program (250 Hz, 400 adu/mV, 12 bits, and no units, i.e.,
        # millivolts); -F, -G, -R and -U are not options then.
        ffreq[] = _AD2M_AHA_FREQ
        ggain[] = _AD2M_AHA_GAIN
        gset = true
        rres[] = _AD2M_AHA_ADCRES
        setsampfreq(_AD2M_AHA_FREQ)
    end

    i = 1
    while i < argc
        a = argv[i]
        if _annapp_c0(a) == UInt8('-')
            c = _annapp_c1(a)
            if c == UInt8('c')
                cflag = true
            elseif c == UInt8('f')
                i += 1
                if i >= argc
                    ceprintf("%s: start time must follow -f\n", pname)
                    cexit(1)
                end
                if legacy               # wfdb-x: as in the C program
                    start_time = strtim(argv[i])
                else
                    fstr = argv[i]      # converted once -F is known (wfdb-x)
                end
            elseif c == UInt8('h')      # help requested
                _annapp_help(pname, legacy ? _AD2M_LEGACY_HELP : _AD2M_HELP)
                cexit(1)
            elseif c == UInt8('i')      # input file name follows
                i += 1
                if i >= argc
                    ceprintf("%s: name of AHA-format input file must follow -i\n", pname)
                    cexit(1)
                end
                ifname = argv[i]
            elseif c == UInt8('r')
                i += 1
                if i >= argc
                    ceprintf("%s: record name must follow -r\n", pname)
                    cexit(1)
                end
                record = argv[i]
            elseif c == UInt8('t')
                i += 1
                if i >= argc
                    ceprintf("%s: end time must follow -t\n", pname)
                    cexit(1)
                end
                if legacy               # wfdb-x: as in the C program
                    end_time = strtim(argv[i])
                else
                    tstr = argv[i]      # converted once -F is known (wfdb-x)
                end
            elseif c == UInt8('F') && !legacy   # sampling frequency (wfdb-x)
                i += 1
                if i >= argc || csscanf(argv[i], "%lf", ffreq) != 1 || ffreq[] <= 0.0
                    ceprintf("%s: sampling frequency (> 0) must follow -F\n", pname)
                    cexit(1)
                end
            elseif c == UInt8('G') && !legacy   # gain in adu per physical unit (wfdb-x)
                i += 1
                if i >= argc || csscanf(argv[i], "%lf", ggain) != 1 || ggain[] < 0.0
                    ceprintf("%s: gain (>= 0) must follow -G\n", pname)
                    cexit(1)
                end
                gset = true
            elseif c == UInt8('R') && !legacy   # ADC resolution in bits (wfdb-x)
                i += 1
                if i >= argc || csscanf(argv[i], "%d", rres) != 1 || rres[] < 1 || rres[] > 32
                    ceprintf("%s: ADC resolution (1-32 bits) must follow -R\n", pname)
                    cexit(1)
                end
            elseif c == UInt8('U') && !legacy   # physical units (wfdb-x)
                i += 1
                if i >= argc
                    ceprintf("%s: units must follow -U\n", pname)
                    cexit(1)
                end
                uunits = argv[i]
            else
                ceprintf("%s: unrecognized option %s\n", pname, a)
                cexit(1)
            end
        else
            ceprintf("%s: unrecognized argument %s\n", pname, a)
            cexit(1)
        end
        i += 1
    end
    if ifname === nothing
        _annapp_help(pname, legacy ? _AD2M_LEGACY_HELP : _AD2M_HELP)
        cexit(1)
    end
    # wfdb-x: the signal parameters must be given explicitly; the C program
    # assumed those of the AHA database (250 Hz, 400 adu/mV, 12 bits, and no
    # units, i.e., millivolts), as legacy mode does (the values set above for
    # legacy mode pass these checks, and no units are required then).
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
    if ggain[] != 0.0 && uunits === nothing && !legacy
        ceprintf("%s: the units must be specified (-U)\n", pname)
        cexit(1)
    end
    setsampfreq(ffreq[])
    fstr !== nothing && (start_time = strtim(fstr))
    tstr !== nothing && (end_time = strtim(tstr))
    if 0 < end_time && end_time <= start_time
        _annapp_help(pname, legacy ? _AD2M_LEGACY_HELP : _AD2M_HELP)
        cexit(1)
    end
    if !cflag && length(ifname) > 4
        ext = @view ifname[end-3:end]
        (ext == b".CMP" || ext == b".cmp") && (cflag = true)
    end

    # Attach the input file to the standard input. (C reads a directory
    # forever; wfdb-x reports it as unreadable.)
    if ifname != b"-" && (_is_directory(ifname) || !freopen_stdin(ifname))
        ceprintf("%s: can't read input file `%s'\n", pname, ifname)
        cexit(2)
    end

    # If no output record name was specified, use the basename of the input
    # file, less any extension.
    record === nothing && (record = _aha_record_name(ifname))

    if end_time == 0 && length(record) == 4    # assume AHA DB input
        if record[2] == UInt8('2') || record[2] == UInt8('3')
            end_time = strtim("35:0")           # short format record
        elseif record[2] == UInt8('0') || record[2] == UInt8('1')
            end_time = strtim("3:0:0")          # long format record
        end
    end

    if end_time == 0
        ceprintf("%s: warning: end time not specified, output may be truncated\n", pname)
        ceprintf("               rerun with -t TIME to override\n")
        end_time = start_time + strtim("100:0:0")
    end

    dfname = append!(copy(record), b".dat")
    dfarray = Siginfo[]
    for _ in 1:2
        push!(dfarray, Siginfo(fname=copy(dfname), desc=UInt8[], gain=ggain[],
                               units=uunits === nothing ? nothing : copy(cstr(uunits)),
                               fmt=_AD2M_FMT, adcres=rres[]))
    end
    osigfopen(dfarray, 2) < 0 && cexit(3)

    if !cflag                       # process tape-format input file
        isigopen(_AD2M_TAPE_RECORD, dfarray, 2) < 2 && cexit(2)
        if start_time > 0
            t = start_time
            isigsettime(t) < 0 && cexit(2)
        end
        # continue to soft EOF, hard error, or specified time
        while getvec(v) == 2 && v[1] != _AD2M_EODF && putvec(v) > 0
            t += 1
            t < end_time || break
        end
        # write header with correct signal length and checksums
        newheader(record)
        # continue to hard EOF (to position tape properly if reading from tape)
        while getvec(v) >= 0
        end
    else                            # process compressed-format input file
        cmp = _Ad2mCmp(wfdb_stdin(), Int32(0), Int32(0))
        while t < start_time && _ad2m_getcvec(cmp, v) == 2
            t += 1
        end
        # continue to hard EOF, hard error, or specified time
        while _ad2m_getcvec(cmp, v) == 2 && putvec(v) > 0
            t += 1
            t < end_time || break
        end
        # write header with correct signal length and checksums
        newheader(record)
    end

    wfdbquit()
    cexit(0)
end

register_workload("ad2m") do
    with_workload_data() do dir
        aha = ("-F", "250", "-G", "400", "-R", "12", "-U", "mV")
        workload_tool("ad2m", "-i", "100s.aha.dat", "-r", "adm", aha...)
        workload_tool("ad2m", "-i", "100s.aha.dat", "-r", "adm", "-f", "10", "-t", "20", aha...)
        workload_tool("ad2m", "-i", "1201.CMP", aha...)
        workload_tool("ad2m", "-i", "1201.CMP", "-r", "adm", "-f", "s100", "-t", "s300", aha...)
        workload_tool("ad2m", "-i", "1201.CMP", "-r", "1301", "-c", aha...)
        workload_tool("ad2m", "-i", "100s.aha.dat", "-r", "adm", "-f", "20", "-t", "10", aha...)
        workload_tool("ad2m", "-i", "nosuch", "-r", "adm", aha...)
        workload_tool("ad2m", "-i", ".", "-r", "adm", aha...)
        workload_tool("ad2m", "-i", "100s.aha.dat", "-r", "adm")
        workload_tool("ad2m", "-i", "100s.aha.dat", "-r", "adm", "-F", "250")
        workload_tool("ad2m", "-i", "100s.aha.dat", "-r", "adm", "-F", "250", "-G", "400")
        workload_tool("ad2m", "-i", "100s.aha.dat", "-r", "adm", "-F", "250", "-G", "400", "-R",
                      "12")
        workload_tool("ad2m", "-i", "100s.aha.dat", "-r", "adm", "-F", "500", "-G", "200", "-R",
                      "16", "-U", "uV", "-t", "5")
        workload_tool("ad2m", "-i", "100s.aha.dat", "-r", "adm", "-F", "250", "-G", "400", "-R",
                      "40", "-U", "mV")
        workload_tool("ad2m", "-i", "100s.aha.dat", "-r", "adm", "-F", "0")
        workload_tool("ad2m", "-i", "100s.aha.dat", "-r", "adm", "-G", "x")
        workload_tool("ad2m", "-h")
        workload_tool("ad2m", "-q")
        workload_tool("ad2m", "x")
        # wfdb-x: legacy mode (original behavior)
        workload_tool("ad2m", "--legacy", "-i", "100s.aha.dat", "-r", "adm", "-f", "10", "-t", "20")
        workload_tool("ad2m", "--legacy", "-i", "1201.CMP", "-r", "adm", "-f", "s100")
        workload_tool("ad2m", "--legacy", "-i", "100s.aha.dat", "-r", "adm", "-F", "250")
        workload_tool("ad2m", "--legacy", "-i", "100s.aha.dat", "-f", "20", "-t", "10")
        workload_tool("ad2m", "--legacy", "-h")
    end
end
