# time2sec: convert a time interval to seconds (port of app/time2sec.c).
#
# Copyright (C) 2003-2009 George B. Moody (original C program, app/time2sec.c).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

"Milliseconds per second."
const _TIME2SEC_MS = 1000

function time2sec_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    wfdbx_legacy_args(args)
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "time2sec"

    if argc == 4 && argv[1] == b"-r"
        isigopen(argv[2], nothing, 0)
        t = Float64(strtim(argv[3]))
        t < 0 && (t = -t)
        seconds = d2l(t / sampfreq(nothing))
        t -= Float64(seconds) * sampfreq(nothing)
        # (C: a long converted to int.)
        milliseconds = d2l((t * _TIME2SEC_MS) / sampfreq(nothing) + 0.5) % Int32
        if milliseconds >= _TIME2SEC_MS
            seconds += 1
            milliseconds -= Int32(_TIME2SEC_MS)
        end
        cprintf("%ld", seconds)
        milliseconds != 0 && cprintf(".%03d", milliseconds)
        cprintf("\n")
        cexit(0)
    elseif argc == 2 && get(argv[1], 1, 0x00) != UInt8('-')
        # Without a record, times are converted at 1000 "samples" per second.
        setsampfreq(Float64(_TIME2SEC_MS))
        cprintf("%.12g\n", Float64(strtim(argv[1])) / _TIME2SEC_MS)
        cexit(0)
    end

    ceprintf("usage: %s [-r RECORD] TIME\n", pname)
    ceprintf(" where TIME (in hh:mm:ss format) is a time interval\n")
    ceprintf(" to be converted into seconds.  Enclose TIME in\n")
    ceprintf(" square brackets (e.g., [9:0:0]) to convert a time\n")
    ceprintf(" of day to the elapsed time in seconds from the\n")
    ceprintf(" beginning of the (optionally) specified RECORD.\n")
    cexit(1)
end

register_workload("time2sec") do
    with_workload_data() do dir
        for tm in ("1:2:3.5", "[9:0:0]", "s100", "e")
            workload_tool("time2sec", tm)
            workload_tool("time2sec", "-r", "100s", tm)
        end
        workload_tool("time2sec")
        workload_tool("time2sec", "-x")
    end
end
