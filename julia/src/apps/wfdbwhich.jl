# wfdbwhich: find a WFDB file and print its pathname (port of
# app/wfdbwhich.c).
#
# Copyright (C) 1999 George B. Moody (original C program, app/wfdbwhich.c).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

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
