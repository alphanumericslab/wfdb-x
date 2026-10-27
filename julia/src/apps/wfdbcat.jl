# wfdbcat: copy WFDB files to the standard output.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of app/wfdbcat.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior). Through
# the library, each file is read from where it is named (the input directory, a
# full path or a URL), not found by a search of the WFDB path; see
# docs/DIVERGENCES.md.
#
# Original C program: app/wfdbcat.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2000 George B. Moody; revised 2018 by Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

"Bytes copied at a time (C `BUFSIZE`)."
const _WFDBCAT_BUFSIZE = 1024

function wfdbcat_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    wfdbx_legacy_args(args)
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "wfdbcat"
    buf = Vector{UInt8}(undef, _WFDBCAT_BUFSIZE)

    if argc < 2 || (argc == 2 && argv[1] == b"-h")
        ceprintf("usage: %s FILE [FILE ...]\n", pname)
        cexit(1)
    end

    for i in 1:argc-1
        ifile = wfdb_open(argv[i], nothing, WFDB_READ)
        if ifile === nothing
            cflush()
            ceprintf("%s: `%s' not found\n", pname, argv[i])
        else
            while true
                n = fread!(ifile, buf, 1, length(buf))
                n == 0 && break
                cout_write(view(buf, 1:n))
                cout_error() && break
            end
            fclose(ifile)
        end
    end
    cexit(0)
end

register_workload("wfdbcat") do
    with_workload_data() do dir
        workload_tool("wfdbcat", "100s.hea", "100s.atr", "nosuch")
        workload_tool("wfdbcat", "-h")
    end
end
