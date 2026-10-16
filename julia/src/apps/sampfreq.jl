# sampfreq: print the sampling frequency of a record (port of
# app/sampfreq.c).
#
# Copyright (C) 1998-2012 George B. Moody (original C program, app/sampfreq.c).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV, 12
# bits and millivolts), because a silently assumed value corrupts every result
# derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).

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
    # wfdb-x: --legacy as the first argument selects legacy mode (the
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
