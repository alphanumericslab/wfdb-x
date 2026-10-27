# wfdbwhich: find a WFDB file and print its pathname.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of app/wfdbwhich.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior). Through
# the library, the file is looked for only where it is named (the input
# directory, a full path or a URL), not by a search of the WFDB path; see
# docs/DIVERGENCES.md.
#
# Original C program: app/wfdbwhich.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1999 George B. Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

function wfdbwhich_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    wfdbx_legacy_args(args)
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "wfdbwhich"
    status = 0

    if argc == 2 && argv[1] == b"-h"
        argc = 0    # give usage instructions and quit
    end
    if argc == 2
        filename = wfdbfile(argv[1], nothing)
        if filename !== nothing
            cprintf("%s\n", filename)
        else
            ceprintf("`%s' not found\n", argv[1])
            ceprintf("(WFDB path = %s)\n", getwfdb())
            status = 2
        end
    elseif argc == 3
        wfdbquiet()
        isigopen(argv[2], nothing, 0)
        filename = wfdbfile(argv[1], argv[2])
        if filename !== nothing
            cprintf("%s\n", filename)
        else
            ceprintf("No file of type `%s' found for record `%s'\n", argv[1], argv[2])
            ceprintf("(WFDB path = %s)\n", getwfdb())
            status = 2
        end
    elseif argc != 4 || argv[1] != b"-r"
        ceprintf("usage: %s [-r RECORD ] FILENAME\n", pname)
        ceprintf(" -or-  %s FILE-TYPE RECORD\n", pname)
        status = 1
    else
        isigopen(argv[2], nothing, 0)
        filename = wfdbfile(argv[3], nothing)
        if filename !== nothing
            cprintf("%s\n", filename)
        else
            ceprintf("`%s' not found\n", argv[3])
            ceprintf("(WFDB path = %s)\n", getwfdb())
            status = 2
        end
    end
    cexit(status)
end

register_workload("wfdbwhich") do
    with_workload_data() do dir
        workload_tool("wfdbwhich", "100s.hea")
        workload_tool("wfdbwhich", "nosuch.hea")
        workload_tool("wfdbwhich", "hea", "100s")
        workload_tool("wfdbwhich", "dat", "nosuch")
        workload_tool("wfdbwhich", "-r", "100s", "100s.dat")
        workload_tool("wfdbwhich", "-r", "100s", "nosuch")
        workload_tool("wfdbwhich", "-h")
    end
end
