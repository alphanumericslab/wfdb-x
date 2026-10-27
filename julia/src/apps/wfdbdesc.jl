# wfdbdesc: describe signal specifications.
#
# This program is an expanded version of Example 5 in the WFDB Programmer's
# Guide.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of app/wfdbdesc.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency, gain, ADC
# resolution or units: an unspecified sampling frequency or ADC resolution is
# shown as "not specified" (lengths are then given in sample intervals only), a
# gain of 0 as "uncalibrated" (the original: "uncalibrated; assume 200"), and
# unspecified units as "adu/nd" (the original assumed 250 Hz, 12 bits and
# millivolts); --legacy, as the first argument, restores the original behavior.
# Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the
# reasons.
#
# Original C program: app/wfdbdesc.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1989-2012 George B. Moody; revised 2018-2020 by
#   Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

# The size of a regular file (C: stat, fopen, fseek to the end, ftell), or
# nothing.
function _wfdbdesc_file_size(name::Vector{UInt8})
    (isempty(name) || 0x00 in name || !isfile(bstr(name))) && return nothing
    f = cfopen(name, "rb")
    f === nothing && return nothing
    if fseek(f, 0, SEEK_END) != 0
        fclose(f)
        return nothing
    end
    n = ftell(f)
    fclose(f)
    n
end

function wfdbdesc_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "wfdbdesc"
    msrec = false

    if argc < 2
        ceprintf("usage: %s RECORD [-readable]\n", pname)
        cexit(1)
    end
    # Discover the number of signals defined in the header.
    nsig = isigopen(argv[1], nothing, 0)
    # (The C library's isigopen() removes a trailing ".hea" from its argument
    # in place, which changes the record name printed below.)
    rec = wfdb_striphea(argv[1])
    nsig < 0 && cexit(2)

    # Allocate storage for nsig signal information structures.
    s = [Siginfo() for _ in 1:max(nsig, 0)]

    # If the `-readable' option is given, report only on signals which can be
    # opened. Otherwise, report on all signals named in the header file,
    # without attempting to open them.
    readable = argc > 2 && (a = cstr(argv[2]); length(a) <= 9 && a == view(b"-readable", 1:length(a)))
    if nsig > 0 && readable
        nsig = isigopen(rec, s, nsig)
    elseif nsig > 0
        nsig = isigopen(rec, s, -nsig)
    end
    cprintf("Record %s", rec)
    setgvmode(WFDB_LOWRES)
    t = strtim("e")
    if nsig > 0 && (s[1].fmt == 0 || s[1].nsamp != 0) && s[1].nsamp != t
        msrec = true
        cprintf(" (a %s-layout multi-segment record)\n", s[1].nsamp == 0 ? "variable" : "fixed")
        if s[1].nsamp != 0
            cprintf("----------------------------------------------\n")
            cprintf("The following data apply to the entire record:\n")
            cprintf("----------------------------------------------")
        end
    end
    info = getinfo(rec)
    if info !== nothing
        cprintf("\nNotes\n=====\n")
        while info !== nothing
            cprintf("%s\n", info)
            info = getinfo(nothing)
        end
        cprintf("=====\n")
    end
    # wfdb-x: if the sampling frequency is not specified, times are not
    # shown (the C program assumed 250 Hz). In legacy mode, the output is
    # that of the C program.
    freq = sampfreq(nothing)
    showfreq = freq > 0.0 || legacy
    p = showfreq ? mstimstr(0) : ""
    cprintf("\nStarting time: %s\n", startswith(p, '[') ? p : "not specified")
    cprintf("Length: ")
    if !showfreq && (nsig < 1 || t > 0)
        cprintf("%lld sample intervals\n", t)
    elseif nsig < 1 || t > 0
        cprintf("%s (%lld sample intervals)\n", t > 0 ? mstimstr(t) : "0", t)
    else
        fname = s[1].fname
        size = (fname !== nothing && s[1].fmt != 0) ? _wfdbdesc_file_size(cstr(fname)) : nothing
        if size !== nothing
            framesize = Int64(0)
            nbytes = size - wfdbgetstart(0)
            for x in view(s, 1:nsig)
                x.group != 0 && break
                framesize += x.spf
            end
            fmt = s[1].fmt
            t = (fmt == 8 || fmt == 80) ? nbytes ÷ framesize :
                (fmt == 16 || fmt == 61 || fmt == 160) ? nbytes ÷ (2 * framesize) :
                fmt == 24 ? nbytes ÷ (3 * framesize) :
                fmt == 32 ? nbytes ÷ (4 * framesize) :
                fmt == 212 ? (2 * nbytes) ÷ (3 * framesize) :
                (fmt == 310 || fmt == 311) ? (3 * nbytes) ÷ (4 * framesize) : Int64(-1)
            if t >= 0 && !showfreq
                cprintf("%lld sample intervals [from signal file size]\n", t)
            elseif t >= 0
                cprintf("%s (%lld sample intervals) [from signal file size]\n", mstimstr(t), t)
            else
                cprintf("not specified\n")
            end
        else
            cprintf("not specified\n")
        end
    end
    if showfreq
        cprintf("Sampling frequency: %.12g Hz\n", freq)
    else
        cprintf("Sampling frequency: not specified\n")
    end
    cprintf("%d signal%s\n", nsig, nsig == 1 ? "" : "s")
    nsig < 1 && cexit(2)
    if msrec && s[1].nsamp != 0
        cprintf("----------------------------------------------\n")
        cprintf("The following data apply to the first segment:\n")
        cprintf("----------------------------------------------\n")
        if showfreq
            cprintf("Segment length: %s (%ld sample intervals)\n", mstimstr(s[1].nsamp),
                    s[1].nsamp)
        else
            cprintf("Segment length: %ld sample intervals\n", s[1].nsamp)
        end
    end
    for i in 1:nsig
        x = s[i]
        cprintf("Group %d, Signal %d:\n", x.group, Int32(i - 1))
        cprintf(" File: %s\n", x.fmt != 0 ? x.fname : "[none]")
        cprintf(" Description: %s\n", x.desc)
        cprintf(" Gain: ")
        if legacy                   # wfdb-x: as in the C program
            if x.gain == 0.0
                cprintf("uncalibrated; assume %g", WFDB_DEFGAIN)
            else
                cprintf("%.12g", x.gain)
            end
            cprintf(" adu/%s\n", x.units === nothing ? "mV" : x.units)
        elseif x.gain == 0.0        # wfdb-x: no default gain
            cprintf("uncalibrated\n")
        else
            # wfdb-x: unspecified units are shown as "nd" (C assumed mV)
            cprintf("%.12g adu/%s\n", x.gain, x.units === nothing ? "nd" : x.units)
        end
        cprintf(" Initial value: %d\n", x.initval)
        x.fmt != 0 && cprintf(" Storage format: %d", x.fmt)
        x.spf > 1 && cprintf(" (%d samples per frame)", x.spf)
        (x.fmt != 0 || x.spf > 1) && cprintf("\n")
        cprintf(" I/O: ")
        if x.bsize == 0
            cprintf("can be unbuffered\n")
        else
            cprintf("%d-byte blocks\n", x.bsize)
        end
        if x.adcres > 0 || legacy
            cprintf(" ADC resolution: %d bits\n", x.adcres)
        else                        # wfdb-x: no default resolution
            cprintf(" ADC resolution: not specified\n")
        end
        cprintf(" ADC zero: %d\n", x.adczero)
        cprintf(" Baseline: %d\n", x.baseline)
        x.nsamp > 0 && cprintf(" Checksum: %d\n", x.cksum)
    end
    cexit(0)
end

register_workload("wfdbdesc") do
    with_workload_data() do dir
        for rec in ("100s", "fmt212", "flac16", "100s.edf", "nosuch")
            workload_tool("wfdbdesc", rec)
            workload_tool("wfdbdesc", rec, "-readable")
        end
        workload_tool("wfdbdesc")
    end
    with_workload_data(files=merge(NODEFAULTS_FILES,
                                   Dict{String,Any}("nfz.hea" => "nfz 1\n100s.dat 212 0 11\n"))) do dir
        for rec in ("nf", "uc", "nfz", "nr")
            workload_tool("wfdbdesc", rec)
            workload_tool("wfdbdesc", "--legacy", rec)     # wfdb-x: legacy mode
        end
    end
end
