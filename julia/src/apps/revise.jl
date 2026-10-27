# revise: convert obsolete-format header files into new ones.
#
# Like the C program (which includes <wfdb/wfdblib.h>), this translation
# opens the old header with the library's internal wfdb_open. As in C, an
# old-style header that describes exactly 32 signals is rejected (see
# docs/KNOWN_C_BEHAVIORS.md).
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of convert/revise.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in ADC resolution: a missing resolution
# stays unspecified (the original assumed 12 bits); --legacy, as the first
# argument, restores the original behavior. Each change is marked "wfdb-x:" in
# the code; docs/DIVERGENCES.md gives the reasons.
#
# Original C program: convert/revise.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1999 George B. Moody; revised 2018 by Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

"Field separators of old-style header lines."
const _REVISE_SEP = b" \t\n"
"Size of the line buffer of the C program (fgets reads up to 255 bytes)."
const _REVISE_LINEBUF = 256

# The first token of the next line (C `fgets(...) == NULL || (p =
# strtok(linebuf, sep)) == NULL` gives nothing), with the tokenizer for the
# rest of the line.
function _revise_next_line(f::WfdbFile, linebuf::Vector{UInt8})
    fgets!(f, linebuf, _REVISE_LINEBUF) || return nothing, nothing
    tk = Strtok(linebuf)
    strtok(tk, _REVISE_SEP), tk
end

function _revise_incorrect(record)
    wfdb_error("init: incorrect format in record %s header\n", record)
    Int32(-2)
end

# Read an old-style header into siarray; returns the number of signals, or a
# negative value on error. (As in C, the header file is left open.)
function _revise_readoldheader(record::Vector{UInt8}, siarray::Vector{Siginfo})
    linebuf = UInt8[]
    nsamples = Int64(0)

    # Try to open the header file.
    iheader = wfdb_open("header", record, WFDB_READ)
    if iheader === nothing
        wfdb_error("init: can't open header for record %s\n", record)
        return Int32(-1)
    end

    # Get the first token (the record name) from the first non-empty,
    # non-comment line.
    local p, tk
    while true
        if !fgets!(iheader, linebuf, _REVISE_LINEBUF)
            wfdb_error("init: can't find record name in record %s header\n", record)
            return Int32(-2)
        end
        tk = Strtok(linebuf)
        p = strtok(tk, _REVISE_SEP)
        (p === nothing || p[1] == UInt8('#')) || break
    end
    if !is_std(iheader) && p != record
        wfdb_error("init: record name in record %s header is incorrect\n", record)
        return Int32(-2)
    end

    # Identify which type of header file is being read by trying to get
    # another token from the line which contains the record name. (Old-style
    # headers have only one token on the first line, but new-style headers
    # have two or more.)
    if strtok(tk, _REVISE_SEP) !== nothing
        ceprintf("The header for record %s appears not to be an old-style header.\n", record)
        return Int32(-2)
    end

    # The file appears to be an old-style header file.

    # Determine the number of signal groups.
    p, _ = _revise_next_line(iheader, linebuf)
    p === nothing && return _revise_incorrect(record)
    ng = atoi(p) % UInt32

    # Now get information for each signal group.
    s = 0                           # C index of the current signal
    mpx = Int32(0)
    g = UInt32(0)
    while g < ng
        si = siarray[s+1]
        # Set the group number for the first signal in the group.
        si.group = g

        # Get the signal file name.
        p, _ = _revise_next_line(iheader, linebuf)
        p === nothing && return _revise_incorrect(record)
        si.fname = p

        # Determine the gain.
        p, _ = _revise_next_line(iheader, linebuf)
        p === nothing && return _revise_incorrect(record)
        si.gain = atof(p)

        # Determine the sampling frequency.
        p, _ = _revise_next_line(iheader, linebuf)
        p === nothing && return _revise_incorrect(record)
        f = atof(p)
        f <= 0.0 && return _revise_incorrect(record)
        setsampfreq(f)

        # Determine the format, block size, and number of signals in this
        # group. In old-style headers these three quantities are encoded
        # into two fields.
        p, tk = _revise_next_line(iheader, linebuf)
        p === nothing && return _revise_incorrect(record)
        i = atoi(p) % UInt32
        p = strtok(tk, _REVISE_SEP)
        mpx = p === nothing ? Int32(1) : atoi(p)
        mpx == 0 && (mpx = Int32(1))
        if i != 8 && i != 16
            si.bsize = i % Int32
            if mpx < 0
                mpx = -mpx
                si.fmt = 8
            else
                si.fmt = 16
            end
        else
            si.fmt = i % Int32
            si.bsize = 0
        end

        # Determine the ADC resolution.
        p = strtok(tk, _REVISE_SEP)
        # wfdb-x: C (and legacy mode) assumed WFDB_DEFRES
        si.adcres = p !== nothing ? atoi(p) : wfdbx_get_legacy() != 0 ? WFDB_DEFRES : Int32(0)

        # Determine the ADC zero.
        p = strtok(tk, _REVISE_SEP)
        si.adczero = p === nothing ? Int32(0) : atoi(p)

        # Determine the initial value.
        p, tk = _revise_next_line(iheader, linebuf)
        p === nothing && return _revise_incorrect(record)
        si.initval = atoi(p)

        # Determine the number of samples.
        p = strtok(tk, _REVISE_SEP)
        ns = p === nothing ? Int64(0) : atol(p)
        ns < 0 && return _revise_incorrect(record)
        if nsamples == 0
            nsamples = ns
        elseif ns > 0 && ns != nsamples
            wfdb_error("warning (init):\n")
            wfdb_error(" record %s durations are inconsistent\n", record)
            # nsamples must match the shortest record duration.
            nsamples > ns && (nsamples = ns)
        end

        # Determine the checksum.
        p = strtok(tk, _REVISE_SEP)
        if p !== nothing
            si.cksum = atoi(p)
            si.nsamp = ns
        else
            si.cksum = 0
            si.nsamp = 0
        end

        # If this signal group contains more than one signal, make
        # additional copies of the siginfo structure for the other signals.
        while true
            s += 1
            s < WFDB_MAXSIG || break
            mpx -= Int32(1)
            mpx > 0 || break
            siarray[s+1] = copy(siarray[s])
        end

        if s == WFDB_MAXSIG && (mpx > 0 || g < ng - UInt32(1))
            wfdb_error("init: too many signals in record %s\n", record)
            return Int32(-2)
        end
        g += UInt32(1)
    end

    # Now generate signal descriptions for each signal.
    for i in 1:s
        siarray[i].desc = cformat("record %s, signal %d", record, Int32(i - 1))
    end

    Int32(s)                        # return number of available signals
end

function revise_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    wfdbx_legacy_args(args)
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "revise"

    if argc < 2
        ceprintf("usage: %s record\n", pname)
        ceprintf(" This program converts obsolete-format header files into new ones.\n")
        cexit(1)
    end
    record = cstr(argv[1])
    prefix = b"header."
    if length(record) >= length(prefix) && view(record, 1:length(prefix)) == prefix
        record = record[length(prefix)+1:end]
    end
    si = [Siginfo() for _ in 1:WFDB_MAXSIG]
    nsig = _revise_readoldheader(record, si)
    nsig < 0 && cexit(2)
    setheader(record, si, nsig % UInt32)
    cexit(0)
end

register_workload("revise") do
    o2 = "o2g\n2\n100s.dat\n200\n360\n212 16 11 1024\n995 21600 0\n" *
         "100s.dat\n200\n360\n212 -2 11 1024\n995 21000 0 7\n"
    files = Dict{String,Any}("o2g.header" => o2,
                             "o33.header" => "o33\n1\n100s.dat\n200\n360\n212 33 11 1024\n995 21600 0\n",
                             "100s.header" => "100s 2 360 21600\n")     # (a new-style header)
    with_workload_data(; files=files) do dir
        workload_tool("revise", "old")
        workload_tool("revise", "header.old")
        workload_tool("revise", "o2g")
        workload_tool("revise", "o33")
        workload_tool("revise", "100s")
        workload_tool("revise", "nosuch")
        workload_tool("revise")
        for rec in ("old", "o2g", "o33")    # wfdb-x: legacy mode (original behavior)
            workload_tool("revise", "--legacy", rec)
        end
    end
end
