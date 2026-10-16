# wfdbcat: copy WFDB files (found in the WFDB path) to the standard output
# (port of app/wfdbcat.c).
#
# Copyright (C) 2000 George B. Moody (original C program, app/wfdbcat.c;
# revised 2018 by Benjamin Moody).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

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
