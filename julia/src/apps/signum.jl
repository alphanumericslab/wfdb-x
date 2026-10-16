# signum: print the numbers of the signals of a record named as arguments
# (port of app/signum.c).
#
# Copyright (C) 2008 George B. Moody (original C program, app/signum.c; revised
# 2021 by Benjamin Moody).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

const _SIGNUM_HELP = (
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -h          print this usage summary",
    " -s SIGNAL [SIGNAL ...]  print signal number(s) for the specified signal(s)")

function _signum_help(pname)
    ceprintf(_SIGNUM_HELP[1], pname)
    for i in 2:length(_SIGNUM_HELP)
        ceprintf("%s\n", _SIGNUM_HELP[i])
    end
end

function signum_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    wfdbx_legacy_args(args)
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "signum"
    record = nothing
    isiglist = 0
    nosig = 0

    i = 1
    while i < argc
        if get(argv[i], 1, 0x00) == UInt8('-')
            c = get(argv[i], 2, 0x00)
            if c == UInt8('h')          # help requested
                _signum_help(pname)
                cexit(0)
            elseif c == UInt8('r')      # record name
                i += 1
                if i >= argc
                    ceprintf("%s: record name must follow -r\n", pname)
                    cexit(1)
                end
                record = argv[i]
            elseif c == UInt8('s')      # signal list follows
                isiglist = i + 1        # index of 1st argument containing a signal name
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
    if record === nothing || isiglist == 0
        _signum_help(pname)
        cexit(1)
    end
    nsig = isigopen(record, nothing, 0)
    nsig <= 0 && cexit(2)
    si = [Siginfo() for _ in 1:nsig]
    nsig = isigopen(record, si, -nsig)
    nsig <= 0 && cexit(2)
    for k in 0:nosig-1
        name = cstr(argv[isiglist+k])
        found = false
        for j in 1:nsig
            desc = si[j].desc
            if desc !== nothing && name == cstr(desc)
                found && cprintf("\t")
                cprintf("%d", Int32(j - 1))
                found = true
            end
        end
        found || cprintf("X")
        cprintf("\n")
    end
    wfdbquit()
    cexit(0)
end

register_workload("signum") do
    with_workload_data() do dir
        workload_tool("signum", "-r", "100s", "-s", "V5", "MLII", "x")
        workload_tool("signum", "-r", "fmt16", "-s", "sig1 fmt16")
        workload_tool("signum", "-r", "nosuch", "-s", "x")
        workload_tool("signum", "-r", "100s")
        workload_tool("signum", "-r", "100s", "-s")
        workload_tool("signum", "-h")
        workload_tool("signum", "-x")
        workload_tool("signum", "x")
        workload_tool("signum", "-r")
    end
end
