# ann2rr: extract a list of intervals from an annotation file.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of app/ann2rr.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency: the new option -F
# FREQ gives it when the record has no header or its header gives none, and is
# then required for time arguments and for intervals and times in units of time
# (the original assumed 250 Hz); --legacy, as the first argument, restores the
# original behavior. Each change is marked "wfdb-x:" in the code;
# docs/DIVERGENCES.md gives the reasons.
#
# Original C program: app/ann2rr.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1995-2009 George B. Moody; revised 2018-2020 by
#   Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

const _ANN2RR_HELP = (
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -A      print all intervals between annotations (default: print only RR",
    "          intervals; overrides -c, -p)",
    " -c      print intervals between consecutive valid annotations only",
    " -f TIME start at specified TIME",
    " -F FREQ sampling frequency, if the record header does not specify one",
    " -h      print this usage summary",
    " -i FMT  print intervals using format FMT (see below for values of FMT)",
    " -p TYPE [TYPE ...]  print intervals ending with annotations of specified",
    "                      TYPEs only (use mnemonics such as N or V for TYPE)",
    " -P TYPE [TYPE ...]  print intervals beginning with specified types only",
    " -t TIME stop at specified TIME",
    " -v FMT  print times of ends of intervals using format FMT (see below)",
    " -V FMT  print times of beginnings of intervals using format FMT (see below)",
    " -w      print annotations that end intervals",
    " -W      print annotations that begin intervals",
    "By default, the output contains the RR intervals only, unless one or more",
    "of -v, -V, -w, or -W are used.  Intervals and times are printed in units of",
    "sample intervals, unless a format is specified using -i, -v, or -V.",
    "Formats can be 'h' (hours), 'm' (minutes), 's' (seconds), 't' (hh:mm:ss);",
    "when used with -v or -V, format 'T' yields dates and times if available,",
    "or the format can be omitted to obtain times in sample intervals.  Formats",
    "'h', 'm', and 's' may be followed by a number between 0 and 15, specifying",
    "the number of decimal places (default: 3).  For example, to obtain intervals",
    "in seconds with 8 decimal places, use '-i s8'.")
# wfdb-x: the help text of the original program, printed in legacy mode
const _ANN2RR_LEGACY_HELP = _help_without(_ANN2RR_HELP, 7)

const _ANN2RR_PAGE = 23         # lines of help per screen
const _ANN2RR_MAXDIGITS = 15    # largest number of decimal places
const _ANN2RR_DEFDIGITS = 3     # default number of decimal places
const _ANN2RR_RRBUF = 20        # size of the buffer of a formatted interval

function _ann2rr_help(pname, legacy::Bool)
    help = legacy ? _ANN2RR_LEGACY_HELP : _ANN2RR_HELP
    ceprintf(help[1], pname)
    for k in 2:length(help)
        ceprintf("%s\n", help[k])
        if (k - 1) % _ANN2RR_PAGE == 0
            ceprintf("--More--")
            b = UInt8[]
            input = wfdb_stdin()
            fgets!(input, b, 5)
            fclose(input)
            ceprintf("\e[A\e[2K")      # erase "--More--"; assumes ANSI terminal
        end
    end
end

# wfdb-x: is output format c (for -i, -v, or -V) a unit of time, which
# needs the sampling frequency?
_ann2rr_time_format(c::UInt8) =
    c == UInt8('h') || c == UInt8('m') || c == UInt8('s') || c == UInt8('t') || c == UInt8('T')

# The flag tables are indexed by annotation type (types outside the tables
# are not flagged).
_ann2rr_flagged(table::Vector{Bool}, a::Integer) = 0 <= a <= ACMAX && table[a+1]

# Print a time in the format fmt ('h', 'm', 's', 't', 'T' or other: sample
# intervals), with the printf format fstr for 'h', 'm', 's'.
function _ann2rr_time(fmt::UInt8, fstr::Vector{UInt8}, t::Int64, sps, spm, sph, zero_t::Bool)
    if fmt == UInt8('h')
        cprintf(fstr, t / sph)
    elseif fmt == UInt8('m')
        cprintf(fstr, t / spm)
    elseif fmt == UInt8('s')
        cprintf(fstr, t / sps)
    elseif fmt == UInt8('t')
        if zero_t && t == 0
            cprintf("    0:00.000")
        else
            cprintf("%s", mstimstr(t))
        end
    elseif fmt == UInt8('T')
        cprintf("%s", mstimstr(-t))
    else
        cprintf("%lld", t)
    end
end

# Print an interval rr / div as snprintf does into a 20-byte buffer, and read
# it back.
function _ann2rr_rrout(rrfstr::Vector{UInt8}, rr::Int64, div::Float64)
    s = cformat(rrfstr, rr / div)
    length(s) > _ANN2RR_RRBUF - 1 && resize!(s, _ANN2RR_RRBUF - 1)
    cprintf("%s", s)
    frr = Ref(0.0)
    csscanf(s, "%lf", frr)
    frr[]
end

function ann2rr_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "ann2rr"
    record = nothing
    ainame = nothing
    aflag_all = a0flag = a1flag = cflag = false
    previous_annot_valid = false
    rrdigits = Ref{Int32}(_ANN2RR_DEFDIGITS)
    t0digits = Ref{Int32}(_ANN2RR_DEFDIGITS)
    t1digits = Ref{Int32}(_ANN2RR_DEFDIGITS)
    rrformat = t0format = t1format = 0x00
    t0flag = t1flag = false
    a0f = fill(false, _NCODES)
    a1f = fill(false, _NCODES)
    annot = Annotation()
    from_i = to_i = 0
    ffreq = 0.0

    # Interpret command-line options.
    a0f[1] = true
    a1f[1] = true
    i = 1
    while i < argc
        a = argv[i]
        if _annapp_c0(a) == UInt8('-')
            c = _annapp_c1(a)
            if c == UInt8('a')          # annotator follows
                i += 1
                if i >= argc
                    ceprintf("%s: annotator must follow -a\n", pname)
                    cexit(1)
                end
                ainame = argv[i]
            elseif c == UInt8('A')      # print intervals between annotations of all types
                aflag_all = true
            elseif c == UInt8('c')      # intervals between consecutive valid annotations only
                cflag = true
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
                _ann2rr_help(pname, legacy)
                cexit(0)
            elseif c == UInt8('i')      # specify interval output format
                i += 1
                if i >= argc || _annapp_c0(argv[i]) == UInt8('-')
                    ceprintf("%s: interval output format must follow -i\n", pname)
                    cexit(1)
                end
                rrformat = _annapp_c0(argv[i])
                csscanf(_annapp_tail(argv[i]), "%d", rrdigits)
            elseif c == UInt8('p') || c == UInt8('P')   # annotation mnemonic(s) follow
                tbl, other = c == UInt8('p') ? (a1f, UInt8('P')) : (a0f, UInt8('p'))
                i += 1
                j = i < argc ? strann(argv[i]) : Int32(0)
                if i >= argc || isann(j) == 0
                    ceprintf("%s: annotation mnemonic(s) must follow -%c\n", pname, other)
                    cexit(1)
                end
                tbl[j+1] = true
                # Pick up any other mnemonics (arguments beginning with `-'
                # are assumed to be options, not mnemonics).
                i += 1
                while i < argc && _annapp_c0(argv[i]) != UInt8('-')
                    j = strann(argv[i])
                    isann(j) != 0 && (tbl[j+1] = true)
                    i += 1
                end
                (i == argc || _annapp_c0(argv[i]) == UInt8('-')) && (i -= 1)
                tbl[1] = false
            elseif c == UInt8('r')      # input record name follows
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
            elseif c == UInt8('v')      # output times of ends of intervals
                t1flag = true
                i += 1
                if i >= argc || _annapp_c0(argv[i]) == UInt8('-')
                    i -= 1
                else
                    t1format = _annapp_c0(argv[i])
                    csscanf(_annapp_tail(argv[i]), "%d", t1digits)
                end
            elseif c == UInt8('V')      # output times of beginnings of intervals
                t0flag = true
                i += 1
                if i >= argc || _annapp_c0(argv[i]) == UInt8('-')
                    i -= 1
                else
                    t0format = _annapp_c0(argv[i])
                    csscanf(_annapp_tail(argv[i]), "%d", t0digits)
                end
            elseif c == UInt8('w')      # output annotation types following intervals
                a1flag = true
            elseif c == UInt8('W')      # output annotation types preceding intervals
                a0flag = true
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
    if record === nothing || ainame === nothing
        _ann2rr_help(pname, legacy)
        cexit(1)
    end

    # wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    # the record had no header); -F specifies one. It is needed for times
    # and intervals in units of time.
    needed = (from_i != 0 && wfdbx_time_needs_freq(argv[from_i]) != 0) ||
             (to_i != 0 && wfdbx_time_needs_freq(argv[to_i]) != 0) ||
             _ann2rr_time_format(rrformat) ||
             (t0flag && _ann2rr_time_format(t0format)) ||
             (t1flag && _ann2rr_time_format(t1format))
    sps = _annapp_sampfreq(pname, record, ffreq, legacy, needed)
    spm = 60.0 * sps
    sph = 60.0 * spm

    ai = [Anninfo(ainame, WFDB_READ)]
    annopen(record, ai, 1) < 0 && cexit(2)      # open annotation file

    for d in (rrdigits, t0digits, t1digits)
        (d[] < 0 || d[] > _ANN2RR_MAXDIGITS) && (d[] = _ANN2RR_DEFDIGITS)
    end
    rrfstr = cformat("%%.%dlf", rrdigits[])
    t0fstr = cformat("%%.%dlf", t0digits[])
    t1fstr = cformat("%%.%dlf", t1digits[])

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
    (to > 0 && to < from) && ((from, to) = (to, from))
    (from > 0 && iannsettime(from) < 0) && cexit(2)

    a0 = NOTQRS
    t0 = from

    while getann(0, annot) == 0 && (to == 0 || annot.time <= to)
        a1 = Int32(annot.anntyp)
        t1 = annot.time

        # Does t1 mark a valid interval end point?
        if aflag_all || (a1f[1] && isqrs(a1) != 0) || _ann2rr_flagged(a1f, a1)
            # Does t0 mark a valid interval starting point?
            if !cflag || previous_annot_valid
                # If requested, print time at beginning of interval.
                if t0flag
                    _ann2rr_time(t0format, t0fstr, t0, sps, spm, sph, true)
                    cprintf("\t")
                end

                # If requested, print annotation at beginning of interval.
                if a0flag
                    if a0 == NOTQRS
                        cprintf("[0]\t")
                    else
                        cprintf("%s\t", annstr(a0))
                    end
                end

                # Print the interval, and update t0 and a0.
                rr = t1 - t0
                if rrformat == UInt8('h')
                    t1 = d2l(t0 + _ann2rr_rrout(rrfstr, rr, sph) * sph + 0.5)
                elseif rrformat == UInt8('m')
                    t1 = d2l(t0 + _ann2rr_rrout(rrfstr, rr, spm) * spm + 0.5)
                elseif rrformat == UInt8('s')
                    t1 = d2l(t0 + _ann2rr_rrout(rrfstr, rr, sps) * sps + 0.5)
                elseif rrformat == UInt8('t')
                    cprintf("%s", mstimstr(t1))
                else
                    cprintf("%lld", rr)
                end

                # If requested, print annotation at end of interval.
                a1flag && cprintf("\t%s", annstr(a1))

                # If requested, print time at end of interval.
                if t1flag
                    cprintf("\t")
                    _ann2rr_time(t1format, t1fstr, t1, sps, spm, sph, false)
                end

                cprintf("\n")
            end
        end
        # Does t1 mark a valid interval starting point?
        if aflag_all || (a0f[1] && isqrs(a1) != 0) || _ann2rr_flagged(a0f, a1)
            a0 = a1
            t0 = t1
            previous_annot_valid = true
        elseif cflag
            previous_annot_valid = false
        end
    end
    cexit(0)
end

register_workload("ann2rr") do
    with_workload_data() do dir
        workload_tool("ann2rr", "-r", "100s", "-a", "atr")
        workload_tool("ann2rr", "-r", "fmt16", "-a", "tst", "-A", "-V", "-v", "-w", "-W")
        for opts in ("-i s", "-i s8", "-i m", "-i h5", "-i t", "-V T -v T", "-V t -v t",
                     "-V s4 -v m", "-V h -v h", "-c -p N", "-P V", "-A -c", "-f 0:10 -t 0:20",
                     "-t 0:20 -f 0:30", "-W -w -i s3 -V -v s3", "-i x", "-v -V")
            workload_tool("ann2rr", "-r", "100s", "-a", "atr", split(opts)...)
        end
        workload_tool("ann2rr", "-r", "100s", "-a", "atr", "-p", "Z")
        workload_tool("ann2rr", "-r", "100s", "-a", "nosuch")
        workload_tool("ann2rr", "-r", "100s", "-a", "atr", "-i")
        workload_tool("ann2rr", "-h"; stdin="\n")
    end
    with_workload_data(files=NODEFAULTS_FILES) do dir
        cp("100s.atr", "nh.atr")
        for opts in ("-t s3000", "-i s", "-F 360 -i s -t s3000", "-V s", "-F 0")
            workload_tool("ann2rr", "-r", "nh", "-a", "atr", split(opts)...)
        end
        # wfdb-x: legacy mode (original behavior)
        for opts in ("-i s -V t", "-F 360", "-f 0:10 -t 0:20 -v T")
            workload_tool("ann2rr", "--legacy", "-r", "nh", "-a", "atr", split(opts)...)
        end
        workload_tool("ann2rr", "--legacy", "-h"; stdin="\n")
    end
end
