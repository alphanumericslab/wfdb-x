# signame: print the names of the signals of a record.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of app/signame.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior).
#
# Original C program: app/signame.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2008 George B. Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

const _SIGNAME_HELP = (
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -h          print this usage summary",
    " -s SIGNAL [SIGNAL ...]  print signal name(s) for the specified signal(s)",
    "If no -s option is given, the names of all signals in the record are output.")

function _signame_help(pname)
    ceprintf(_SIGNAME_HELP[1], pname)
    for i in 2:length(_SIGNAME_HELP)
        ceprintf("%s\n", _SIGNAME_HELP[i])
    end
end

function signame_main(args::Vector{String})
    # WFDB-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    wfdbx_legacy_args(args)
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "signame"
    record = nothing
    isiglist = 0
    nosig = 0

    i = 1
    while i < argc
        if get(argv[i], 1, 0x00) == UInt8('-')
            c = get(argv[i], 2, 0x00)
            if c == UInt8('h')          # help requested
                _signame_help(pname)
                cexit(0)
            elseif c == UInt8('r')      # record name
                i += 1
                if i >= argc
                    ceprintf("%s: record name must follow -r\n", pname)
                    cexit(1)
                end
                record = argv[i]
            elseif c == UInt8('s')      # signal list follows
                isiglist = i + 1        # index of 1st argument containing a signal #
                while i + 1 < argc && get(argv[i+1], 1, 0x00) != UInt8('-')
                    i += 1
                    nosig += 1          # number of elements in signal list
                end
                if nosig == 0
                    ceprintf("%s: signal list must follow -s\n", pname)
                    cexit(1)
                end
            else
                ceprintf("%s: unrecognized option %s\n", pname, argv[i])
                cexit(1)
            end
        else
            ceprintf("%s: unrecognized argument %s\n", pname, argv[i])
            cexit(1)
        end
        i += 1
    end
    if record === nothing
        _signame_help(pname)
        cexit(1)
    end
    nsig = isigopen(record, nothing, 0)
    nsig <= 0 && cexit(2)
    si = [Siginfo() for _ in 1:nsig]
    nsig = isigopen(record, si, -nsig)
    nsig <= 0 && cexit(2)
    if isiglist != 0
        for k in 0:nosig-1
            j = atoi(argv[isiglist+k])
            # (The C program also accepts j == nsig, reading past the end of
            # its array; see docs/KNOWN_C_BEHAVIORS.md.)
            if 0 <= j < nsig
                cprintf("%s\n", si[j+1].desc)
            else
                cprintf("%s\n", "[INVALID]")
            end
        end
    else
        for k in 1:nsig
            cprintf("%s\n", si[k].desc)
        end
    end
    wfdbquit()
    cexit(0)
end

register_workload("signame") do
    with_workload_data() do dir
        workload_tool("signame", "-r", "100s")
        workload_tool("signame", "-r", "100s", "-s", "1", "0", "7")
        workload_tool("signame", "-r", "100s", "-s")
        workload_tool("signame", "-r", "nosuch")
        workload_tool("signame")
        workload_tool("signame", "-h")
        workload_tool("signame", "-x")
        workload_tool("signame", "x")
        workload_tool("signame", "-r")
    end
end
