# sampfreq: print the sampling frequency of a record.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of app/sampfreq.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior). Through
# the library, a record whose header gives no sampling frequency has the
# frequency 0, which is printed (the original printed 250); see
# docs/DIVERGENCES.md.
#
# Original C program: app/sampfreq.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1998-2012 George B. Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

const _SAMPFREQ_HELP =
    " where RECORD is the name of the input record\n" *
    " and OPTION may be either of:\n" *
    "  -a   list all signals and their sampling frequencies\n" *
    "  -h   show this help\n" *
    "  -H   show the maximum sampling frequency of a multifrequency record)\n" *
    " If no OPTION is used, show the base sampling frequency (frame rate).\n"

function _sampfreq_help(pname)
    ceprintf("usage: %s [OPTION] RECORD\n", pname)
    ceprintf("%s", _SAMPFREQ_HELP)
end

function sampfreq_main(args::Vector{String})
    # WFDB-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    wfdbx_legacy_args(args)
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "sampfreq"

    if argc == 1
        _sampfreq_help(pname)
        cexit(1)
    elseif argc == 2
        cprintf("%g\n", sampfreq(argv[1]))
        cexit(0)
    elseif argc == 3 && (argv[1] == b"-a" || argv[1] == b"-H")
        si = Siginfo[]
        nsig = isigopen(argv[2], nothing, 0)
        if nsig > 0
            si = [Siginfo() for _ in 1:nsig]
            isigopen(argv[2], si, nsig)
        end
        if argv[1][2] == UInt8('H')
            setgvmode(WFDB_HIGHRES)
            cprintf("%g\n", sampfreq(nothing))
            cexit(0)
        else
            setgvmode(WFDB_LOWRES)
            freq = sampfreq(nothing)
            for i in 1:max(nsig, 0)
                cprintf("%s\t%g\n", si[i].desc, si[i].spf * freq)
            end
        end
    end
    # (The C program falls off the end of main; its exit status is 0.)
    cexit(0)
end

register_workload("sampfreq") do
    with_workload_data() do dir
        for rec in ("100s", "mfreq", "nosuch")
            workload_tool("sampfreq", rec)
            workload_tool("sampfreq", "-a", rec)
            workload_tool("sampfreq", "-H", rec)
        end
        workload_tool("sampfreq")
        workload_tool("sampfreq", "-x", "100s")
    end
end
