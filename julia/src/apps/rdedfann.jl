# rdedfann: print annotations from an EDF+ file.
#
# This program prints the annotations from an EDF+ file in the same format
# as rdann does for WFDB-compatible annotation files. As in the C program,
# an annotation without a duration repeats the duration of the previous one
# (see docs/KNOWN_C_BEHAVIORS.md). Where the C program would overflow its
# 1024-byte onset, duration, or text buffers, the excess characters are
# discarded.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of convert/rdedfann.c from the WFDB Software
# Package 10.7.0, by George B. Moody. The translation follows the logic and
# behavior of the original program, but it is new code, not the original C
# code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior).
#
# Original C program: convert/rdedfann.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2008-2014 George B. Moody; bug fix and -x option contributed
#   by Luca Citi, 2014.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

"Size of the onset, duration, and text buffers of the C program."
const _RDEDFANN_BUFLEN = 1024
# Characters that delimit the parts of an EDF+ time-stamped annotation list
# (TAL).
const _EDF_TAL_START = 0x2b          # '+': start of a TAL (sign of its onset)
const _EDF_TAL_DURATION = 0o25       # end of onset, start of duration
const _EDF_TAL_SEP = 0o24            # end of onset/duration/annotation

# The annotation type printed with -x, and an empty string.
const _RDEDFANN_QUOTE = UInt8[UInt8('"')]
const _RDEDFANN_EMPTY = UInt8[]

const _RDEDFANN_HELP = (
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input EDF+ record, and OPTIONS may include:",
    " -F FREQ     set the sampling frequency to FREQ Hz\n",
    " -h          print this usage summary",
    " -v          print column headings",
    " -x          print EDF+ annotation text in aux (default: print in anntyp)")

# A fixed-size character buffer with a write position, as in C (characters
# that would overflow the buffer are discarded).
mutable struct _RdedfannBuf
    b::Vector{UInt8}
    pos::Int
end
_RdedfannBuf() = _RdedfannBuf(zeros(UInt8, _RDEDFANN_BUFLEN), 0)

function _rdedfann_put!(buf::_RdedfannBuf, c::Integer)
    buf.pos < length(buf.b) && (buf.b[buf.pos+1] = c % UInt8)
    buf.pos += 1
end

mutable struct _RdedfannState
    sfreq::Float64
    state::Int
    xflag::Bool
    onset::_RdedfannBuf
    duration::_RdedfannBuf
    text::_RdedfannBuf
end

# Process one byte of the annotation signal.
function _rdedfann_proc!(st::_RdedfannState, pname, x::Integer)
    x = Int32(x & 0xff)
    if st.state == 0                # looking for a new TAL
        x == 0 && return
        if x != _EDF_TAL_START
            ceprintf("%s: unexpected character '%c' in input\n", pname, x)
        else
            st.state = 1
            st.onset.pos = 0
            st.duration.pos = 0
            st.text.pos = 0
            st.text.b[1] = 0x00
        end
    elseif st.state == 1            # accumulate characters from onset until 024 or 025
        if x == _EDF_TAL_DURATION    # end of onset, start of duration
            x = Int32(0)
            st.state = 2
        elseif x == _EDF_TAL_SEP     # end of onset, start of annotation
            x = Int32(0)
            st.state = 3
        end
        _rdedfann_put!(st.onset, x)
    elseif st.state == 2            # accumulate characters from duration until 024
        if x == _EDF_TAL_SEP         # end of onset, start of annotation
            x = Int32(0)
            st.state = 3
        end
        _rdedfann_put!(st.duration, x)
    elseif st.state == 3            # accumulate characters from annotation until 024
        if x == _EDF_TAL_SEP         # end of annotation
            x = Int32(0)
            st.state = 4
        end
        _rdedfann_put!(st.text, x)
    elseif st.state == 4            # annot just ended, there may be another
        text = st.text.b
        if text[1] != 0             # the annotation was not empty -- output it
            t = d2l(atof(cstr(st.onset.b)) * st.sfreq + 0.5)
            # replace whitespace with '_'
            k = 1
            while k <= length(text) && text[k] != 0
                (text[k] == UInt8(' ') || text[k] == UInt8('\t')) && (text[k] = UInt8('_'))
                k += 1
            end
            ts = cstr(text)
            tstr = t != 0 ? mstimstr(t) : "    0:00.000"
            anntyp, aux = st.xflag ? (_RDEDFANN_QUOTE, ts) : (ts, _RDEDFANN_EMPTY)
            cprintf("%s  %7ld %5s%5d%5d%5d\t%s", tstr, t, anntyp, Int32(0), Int32(0), Int32(0), aux)
            if st.duration.b[1] != 0
                cprintf("%cduration: %s", st.xflag ? UInt8(' ') : UInt8('\t'), cstr(st.duration.b))
            end
            cprintf("\n")
        end
        if x != 0
            text[1] = x % UInt8
            st.text.pos = 1
            st.state = 3
        else                        # end of TAL
            st.state = 0
        end
    end
    nothing
end

function rdedfann_main(args::Vector{String})
    # WFDB-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    wfdbx_legacy_args(args)
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "rdedfann"
    record = nothing
    sfreq = 0.0
    vflag = xflag = false

    i = 1
    while i < argc
        a = argv[i]
        if !isempty(a) && a[1] == UInt8('-')
            c = length(a) >= 2 ? a[2] : 0x00
            if c == UInt8('F')
                i += 1
                if i >= argc
                    ceprintf("%s: sampling frequency must follow -F\n", pname)
                    cexit(1)
                end
                fref = Ref{Float64}(sfreq)
                csscanf(argv[i], "%lf", fref)
                sfreq = fref[]
                sfreq <= 0.0 && (sfreq = 1.0)
            elseif c == UInt8('h')      # help requested
                _convert_help(pname, _RDEDFANN_HELP)
                cexit(0)
            elseif c == UInt8('r')      # record name
                i += 1
                if i >= argc
                    ceprintf("%s: record name must follow -r\n", pname)
                    cexit(1)
                end
                record = cstr(argv[i])
            elseif c == UInt8('v')      # verbose output -- include column headings
                vflag = true
            elseif c == UInt8('x')      # save EDF annotation text in aux rather than anntyp
                xflag = true
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
    if record === nothing
        _convert_help(pname, _RDEDFANN_HELP)
        cexit(1)
    end
    setgvmode(WFDB_HIGHRES)
    nsig = isigopen(record, nothing, 0)
    nsig <= 0 && cexit(2)
    si = [Siginfo() for _ in 1:nsig]
    nsig = isigopen(record, si, nsig)
    nsig <= 0 && cexit(2)
    aindex = alen = framelen = 0
    for k in 1:nsig
        if si[k].desc == b"EDF Annotations"
            aindex = framelen
            alen = Int(si[k].spf)
        end
        framelen += Int(si[k].spf)
    end
    if alen == 0
        ceprintf("%s: record %s has no EDF annotations\n", pname, record)
        wfdbquit()
        cexit(3)
    end
    frame = zeros(Int32, framelen)

    if sfreq > 0.0
        setgvmode(WFDB_LOWRES)
        setsampfreq(sfreq)
    else
        sfreq = sampfreq(nothing)
    end

    # Print column headers if '-v' option selected.
    vflag && cprintf("      Time   Sample #  Type  Sub Chan  Num\tAux\n")

    st = _RdedfannState(sfreq, 0, xflag, _RdedfannBuf(), _RdedfannBuf(), _RdedfannBuf())
    while getframe(frame) > 0
        st.state = 0
        for k in aindex+1:aindex+alen
            p = frame[k]
            (p != 0 || st.state != 0) || break
            _rdedfann_proc!(st, pname, p)
            _rdedfann_proc!(st, pname, p >> 8)
        end
    end

    wfdbquit()
    cexit(0)
end

register_workload("rdedfann") do
    with_workload_data() do dir
        for opts in ((), ("-v",), ("-x",), ("-x", "-v"), ("-F", "100"), ("-F", "0"))
            workload_tool("rdedfann", "-r", "edfp.edf", opts...)
        end
        workload_tool("rdedfann", "-r", "fmt16.edf")
        workload_tool("rdedfann", "-r", "nosuch.edf")
        workload_tool("rdedfann", "-r", "edfp.edf", "-q")
        workload_tool("rdedfann", "-h")
        workload_tool("rdedfann", "x")
        workload_tool("rdedfann", "-r")
        workload_tool("rdedfann")
    end
end
