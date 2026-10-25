# sortann: rearrange annotations in canonical order (port of
# app/sortann.c).
#
# This program rewrites annotation files with the annotations in time
# order. Any simultaneous annotations are written in num and chan order. If
# the input contains two or more annotations with the same time, num, and
# chan fields, only the last one is copied (and none, if that one has
# anntyp = NOTQRS) -- but only when the duplicates are found while
# repairing out-of-order input, as in the C version.
#
# The sorted (output) annotation file is always written to the current
# directory. If the input annotations are already in the correct order, no
# output is written unless the -o option is used.
#
# wfdb-x: an out-of-order annotation at time 0 (num 0, chan 0) is no longer
# lost (nor are those inserted after it), as it was by the original program
# (decided by Reza Sameni, Oct 2026); --legacy keeps the original behavior.
#
# Copyright (C) 1997-2010 George B. Moody (original C program, app/sortann.c;
# revised 2017-2018 by Benjamin Moody).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV, 12
# bits and millivolts), because a silently assumed value corrupts every
# result derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).

const _SORTANN_HELP = (
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -f TIME    start at specified TIME",
    " -F FREQ    sampling frequency, if the record header does not specify one",
    " -h         print this usage summary",
    " -o OUTANN  write output as annotator OUTANN (required with -f or -t)",
    " -t TIME    stop at specified TIME",
    "The sorted output replaces the input if -o is omitted, the input is in",
    "the current directory, and the input is not already sorted.")
# wfdb-x: the help text of the original program, printed in legacy mode
const _SORTANN_LEGACY_HELP = _help_without(_SORTANN_HELP, 4)

# The annotation list (_SortList, _sortann_insert!) is defined in annot.jl
# (wfdb-x: oannclose uses it too).

function sortann_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "sortann"
    ainame0 = nothing
    ainame1 = nothing
    record = nothing
    from_i = to_i = 0
    ffreq = 0.0
    annot = Annotation()

    # Interpret command-line options.
    i = 1
    while i < argc
        a = argv[i]
        if _annapp_c0(a) == UInt8('-')
            c = _annapp_c1(a)
            if c == UInt8('a')          # (input) annotator follows
                i += 1
                if i >= argc
                    ceprintf("%s: annotator must follow -a\n", pname)
                    cexit(1)
                end
                ainame0 = argv[i]
            elseif c == UInt8('f')      # starting time follows
                i += 1
                if i >= argc
                    ceprintf("%s: starting time must follow -f\n", pname)
                    cexit(1)
                end
                from_i = i              # to be converted to sample intervals below
            elseif c == UInt8('F') && !legacy   # sampling frequency follows (wfdb-x)
                i += 1
                ffreq = _annapp_ffreq(pname, argv, i, argc)
            elseif c == UInt8('h')      # print usage summary and quit
                _annapp_help(pname, legacy ? _SORTANN_LEGACY_HELP : _SORTANN_HELP)
                cexit(0)
            elseif c == UInt8('o')      # output annotator follows
                i += 1
                if i >= argc
                    ceprintf("%s: annotator must follow -o\n", pname)
                    cexit(1)
                end
                ainame1 = argv[i]
            elseif c == UInt8('r')
                # input record name follows. If -r is followed by a non-empty
                # string (with no intervening space), use that string as the
                # WFDB path. (The WFDB library invokes sortann with '-r.'.)
                p = cstr(a[3:end])
                isempty(p) || setwfdb(p)
                i += 1
                if i >= argc
                    ceprintf("%s: input record name must follow -r\n", pname)
                    cexit(1)
                end
                record = argv[i]
            elseif c == UInt8('t')      # ending time follows
                i += 1
                if i >= argc
                    ceprintf("%s: end time must follow -t\n", pname)
                    cexit(1)
                end
                to_i = i
            else
                ceprintf("%s: unrecognized option %s\n", pname, a)
                cexit(1)
            end
        else
            ceprintf("%s: unrecognized argument %s\n", pname, a)
            cexit(1)
        end
        i += 1
    end

    if record === nothing || ainame0 === nothing
        _annapp_help(pname, legacy ? _SORTANN_LEGACY_HELP : _SORTANN_HELP)
        cexit(1)
    end
    if (from_i != 0 || to_i != 0) && ainame1 === nothing
        ceprintf("%s: -o required when using -f or -t options\n", pname)
        cexit(1)
    end
    if ainame1 !== nothing && cstr(ainame0) == cstr(ainame1)
        ceprintf("%s: must specify different annotator names after -a and -o\n", pname)
        cexit(1)
    end

    # By setting WFDBANNSORT, we ensure that wfdbquit won't invoke this
    # program recursively if something goes wrong.
    csetenv("WFDBANNSORT", "0", true)

    # wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    # the record had no header); -F specifies one. It is needed only to
    # convert the -f and -t times.
    needed = (from_i != 0 && wfdbx_time_needs_freq(argv[from_i]) != 0) ||
             (to_i != 0 && wfdbx_time_needs_freq(argv[to_i]) != 0)
    sps = _annapp_sampfreq(pname, record, ffreq, legacy, needed)

    ai = [Anninfo(ainame0, WFDB_READ)]
    annopen(record, ai, 1) < 0 && cexit(2)      # open input annotation file

    from = Int64(0)
    to = Int64(0)
    if from_i != 0
        from = strtim(argv[from_i])
        from < 0 && (from = -from)
    end
    if to_i != 0
        to = strtim(argv[to_i])
        to < 0 && (to = -to)
    end

    tps = getiaorigfreq(0)
    if tps > 0.0
        setafreq(tps)
        setiafreq(0, tps)
        if legacy || sps > 0.0
            from = d2l(from * tps / sps + 0.5)
            to = d2l(to * tps / sps + 0.5)
        elseif from != 0 || to != 0     # wfdb-x: no default sampling frequency
            _annapp_nofreq(pname, record)
        end
    end

    # Build a linked list of annotations in memory.
    list = _SortList(legacy)       # (wfdb-x: no annotation lost)
    while getann(0, annot) == 0
        (annot.time < from || (to > 0 && annot.time >= to)) && continue
        _sortann_insert!(list, annot)
    end
    iannclose(0)

    if list.in_order && ainame1 === nothing
        # If all of the annotations were in order, don't copy them unless
        # another annotator name was specified (using -o).
        ceprintf("%s: input is already ordered -- no output written\n", pname)
        cexit(0)
    end

    if from == 0 && to == 0 && ainame1 === nothing
        # in this case, we are processing the entire input file, and it's
        # acceptable to overwrite it
        ainame1 = ainame0
    end

    ai = [Anninfo(something(ainame1, UInt8[]), WFDB_WRITE)]
    annopen(record, ai, 1) < 0 && cexit(2)      # open output annotation file
    ap = list.next[1]
    while ap != -1
        a = list.ann[ap+1]
        a.anntyp != NOTQRS && putann(0, a)
        ap = list.next[ap+1]
    end
    wfdbquit()
    cexit(0)
end

register_workload("sortann") do
    with_workload_data() do dir
        workload_tool("sortann", "-r", "100s", "-a", "atr")
        workload_tool("sortann", "-r", "100s", "-a", "atr", "-o", "srt", "-f", "0:10", "-t", "0:20")
        workload_tool("sortann", "-r.", "fmt16", "-a", "mod", "-o", "srt")
        workload_tool("sortann", "-r", "100s", "-a", "ooo")
        workload_tool("sortann", "-r", "100s", "-a", "atr", "-f", "0:10")
        workload_tool("sortann", "-r", "100s", "-a", "atr", "-o", "atr")
        workload_tool("sortann", "-r", "100s", "-a", "nosuch")
        workload_tool("sortann", "-h")
    end
    with_workload_data(files=NODEFAULTS_FILES) do dir
        cp("100s.atr", "nh.atr")
        for opts in ("", "-t 5", "-F 360 -t 5", "-t s100", "-F")
            workload_tool("sortann", "-r", "nh", "-a", "atr", "-o", "srt", split(opts)...)
        end
        # wfdb-x: legacy mode (original behavior)
        for opts in ("-t 5", "-F 360", "-f 0:1 -t 0:20")
            workload_tool("sortann", "--legacy", "-r", "nh", "-a", "atr", "-o", "srt",
                          split(opts)...)
        end
        workload_tool("sortann", "--legacy", "-h")
    end
end
