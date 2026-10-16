# wfdbtime: convert times to sample numbers, elapsed times and times of
# day (port of app/wfdbtime.c).
#
# Copyright (C) 2001 George B. Moody (original C program, app/wfdbtime.c;
# revised 2017-2018 by Benjamin Moody).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling
# frequency, gain, ADC resolution or units. Values that the record or the
# user does not give are never assumed (the original package assumed 250
# Hz, 200 adu/mV, 12 bits and millivolts), because a silently assumed
# value corrupts every result derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).

function wfdbtime_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "wfdbtime"
    record = nothing

    i = 1
    while i < argc
        if argv[i] == b"-r"
            record === nothing || wfdbquit()
            i += 1
            i == argc && break
            record = argv[i]
            isigopen(record, nothing, 0) < 0 && cexit(2)
            # wfdb-x: no default frequency (except in legacy mode)
            if !legacy && sampfreq(nothing) <= 0.0
                ceprintf("%s: sampling frequency of record %s is not specified\n", pname, record)
                cexit(2)
            end
        elseif record !== nothing
            t = strtim(argv[i])
            t < 0 && (t = -t)
            sbuf = cformat("s%ld", t)    # (at most 21 bytes: fits C's sbuf[32])
            cprintf("%15s\t%15s", sbuf, t == 0 ? "0:00.000" : mstimstr(t))
            cprintf("\t%15s\n", mstimstr(-t))
        end
        i += 1
    end
    if record === nothing
        ceprintf("usage: %s [ -r RECORD [ TIME ] ]\n", pname)
        ceprintf(" where RECORD is the name of the input record\n")
        ceprintf(" Each TIME is a time to be converted\n")
        cexit(1)
    end
    wfdbquit()
    cexit(0)
end

register_workload("wfdbtime") do
    with_workload_data() do dir
        workload_tool("wfdbtime", "-r", "100s", "0", "1", "360", "s360", "1:0", "e",
                      "[00:00:10]", "0:0.5")
        workload_tool("wfdbtime", "-r", "fmt16", "[12:35:00]", "[12:35:00 31/12/1999]",
                      "-r", "mfreq", "s7")
        workload_tool("wfdbtime", "-r", "nosuch", "10")
        workload_tool("wfdbtime", "-r")
        workload_tool("wfdbtime")
    end
    with_workload_data(files=NODEFAULTS_FILES) do dir
        workload_tool("wfdbtime", "-r", "nf", "10")
        workload_tool("wfdbtime", "--legacy", "-r", "nf", "10", "0:1")
    end
end
