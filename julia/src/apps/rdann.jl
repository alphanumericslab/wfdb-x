# rdann: print an annotation file in ASCII form.
#
# Caution: if the output format of rdann is modified, wrann will require
# modification as well!
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of app/rdann.c from the WFDB Software Package
# 10.7.0, by T. Baker and George B. Moody. The translation follows the logic
# and behavior of the original program, but it is new code, not the original C
# code.
#
# Changes from the original: no built-in sampling frequency: the new option -F
# FREQ gives it when the record has no header or its header gives none, and is
# then required (the original assumed 250 Hz); --legacy, as the first argument,
# restores the original behavior. Each change is marked "WFDB-x:" in the code;
# docs/DIVERGENCES.md gives the reasons.
#
# Original C program: app/rdann.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1981-2010 George B. Moody; revised 2017-2018 by
#   Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

const _RDANN_HELP = (
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -c CHAN             print annotations with specified CHAN only",
    " -e                  * show annotation times as elapsed times",
    " -f TIME             start at specified TIME",
    " -F FREQ             sampling frequency, if the record header does not",
    "                      specify one",
    " -h                  print this usage summary",
    " -n NUM              print annotations with specified NUM only",
    " -p TYPE [TYPE ...]  print annotations of specified TYPEs only",
    " -s SUBTYPE          print annotations with specified SUBTYPE only",
    " -t TIME             stop at specified TIME",
    " -v                  print column headings",
    " -x                  * use alternate time format (seconds, minutes, hours)",
    "* Only one of -e and -x can be used.")
# WFDB-x: the help text of the original program, printed in legacy mode
const _RDANN_LEGACY_HELP = _help_without(_RDANN_HELP, 6:7)

# Helpers shared by the annotation tools (rdann, wrann, sortann, ann2rr,
# rr2ann): the usage summary, and the first and second bytes (0 if absent)
# and the tail of an argument.
function _annapp_help(pname, help)
    ceprintf(help[1], pname)
    for k in 2:length(help)
        ceprintf("%s\n", help[k])
    end
end

# The first and second bytes of a C string (0 if absent), and the string
# after its first byte.  Time strings from timstr/mstimstr are Strings.
_annapp_c0(a::AbstractVector{UInt8}) = isempty(a) ? 0x00 : a[1]
_annapp_c0(a::String) = _annapp_c0(codeunits(a))
_annapp_c1(a::AbstractVector{UInt8}) = length(a) < 2 ? 0x00 : a[2]
_annapp_c1(a::String) = _annapp_c1(codeunits(a))
_annapp_tail(a::AbstractVector{UInt8}) = length(a) < 2 ? UInt8[] : a[2:end]
_annapp_tail(a::String) = _annapp_tail(codeunits(a))

# WFDB-x: the -F option of rdann, ann2rr, sortann and m2a (the sampling
# frequency to use if the record header does not specify one; the C tools
# assumed 250 Hz). argv[i] is the argument after -F (i >= argc if none).
function _annapp_ffreq(pname::String, argv::Vector{Vector{UInt8}}, i::Int, argc::Int)
    f = Ref{Float64}(0.0)
    if i >= argc || csscanf(argv[i], "%lf", f) != 1 || f[] <= 0.0
        ceprintf("%s: sampling frequency (> 0) must follow -F\n", pname)
        cexit(1)
    end
    f[]
end

# WFDB-x: the error of the annotation tools when the sampling frequency is
# needed but not specified.
function _annapp_nofreq(pname::String, record)
    ceprintf("%s: sampling frequency of record %s is not specified (use -F)\n", pname, record)
    cexit(1)
end

# The sampling frequency of the record of rdann, ann2rr and sortann (set
# with setsampfreq if it comes from -F). WFDB-x: no default sampling
# frequency (the C programs assumed 250 Hz if the record had no header, as
# legacy mode does); -F (ffreq > 0) specifies one. Without one, it is an
# error if the tool needs it (`needed`).
function _annapp_sampfreq(pname::String, record, ffreq::Float64, legacy::Bool, needed::Bool)
    sps = sampfreq(record)
    if legacy           # WFDB-x: legacy mode (original behavior)
        if sps < 0.0
            sps = WFDB_DEFFREQ
            setsampfreq(sps)
        end
    else
        if sps <= 0.0 && ffreq > 0.0
            sps = ffreq
            setsampfreq(sps)
        end
        sps <= 0.0 && needed && _annapp_nofreq(pname, record)
    end
    sps
end

function rdann_main(args::Vector{String})
    # WFDB-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "rdann"
    record = nothing
    ainame = nothing
    cflag = nflag = sflag = false
    chanmatch = nummatch = submatch = Int8(0)
    eflag = vflag = xflag = false
    anum = ato = bnum = bto = Int64(0)
    from = to = 0                   # argument indices, then times
    to_t = Int64(0)
    ffreq = 0.0
    flag = fill(false, _NCODES)     # flag[code+1]: print annotations of this type
    annot = Annotation()

    # Accept old syntax.
    if argc >= 3 && _annapp_c0(argv[1]) != UInt8('-')
        ainame = argv[1]
        record = argv[2]
        i = 3
        if argc > 3
            from = 3
            i = 4
        end
        if argc > 4
            to = 4
            i = 5
        end
        if argc <= 5
            flag[1] = true
        else
            while i < argc && _annapp_c0(argv[i]) != UInt8('-')
                j = strann(argv[i])
                isann(j) != 0 && (flag[j+1] = true)
                i += 1
            end
        end
    else
        i = 1
        flag[1] = true
    end

    # Interpret command-line options.
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
            elseif c == UInt8('c')      # chan value follows
                i += 1
                if i >= argc
                    ceprintf("%s: chan value (between -128 and 127) must follow -c\n", pname)
                    cexit(1)
                end
                chanmatch = atoi(argv[i]) % Int8
                cflag = true
            elseif c == UInt8('e')      # show elapsed time
                eflag = true
                xflag = false
            elseif c == UInt8('f')      # starting time follows
                i += 1
                if i >= argc
                    ceprintf("%s: starting time must follow -f\n", pname)
                    cexit(1)
                end
                from = i                # to be converted to sample intervals below
            elseif c == UInt8('F') && !legacy   # sampling frequency follows (WFDB-x)
                i += 1
                ffreq = _annapp_ffreq(pname, argv, i, argc)
            elseif c == UInt8('h')      # print usage summary and quit
                _annapp_help(pname, legacy ? _RDANN_LEGACY_HELP : _RDANN_HELP)
                cexit(0)
            elseif c == UInt8('n')      # num value follows
                i += 1
                if i >= argc
                    ceprintf("%s: num value (between -128 and 127) must follow -n\n", pname)
                    cexit(1)
                end
                nummatch = atoi(argv[i]) % Int8
                nflag = true
            elseif c == UInt8('p')      # annotation mnemonic(s) follow
                i += 1
                j = i < argc ? strann(argv[i]) : Int32(0)
                if i >= argc || isann(j) == 0
                    ceprintf("%s: annotation mnemonic(s) must follow -p\n", pname)
                    cexit(1)
                end
                flag[j+1] = true
                # Pick up any other mnemonics (arguments beginning with `-'
                # are assumed to be options, not mnemonics).
                i += 1
                while i < argc && _annapp_c0(argv[i]) != UInt8('-')
                    j = strann(argv[i])
                    isann(j) != 0 && (flag[j+1] = true)
                    i += 1
                end
                (i == argc || _annapp_c0(argv[i]) == UInt8('-')) && (i -= 1)
                flag[1] = false
            elseif c == UInt8('r')      # input record name follows
                i += 1
                if i >= argc
                    ceprintf("%s: input record name must follow -r\n", pname)
                    cexit(1)
                end
                record = argv[i]
            elseif c == UInt8('s')      # subtyp value follows
                i += 1
                if i >= argc
                    ceprintf("%s: subtyp value (between -128 and 127) must follow -s\n", pname)
                    cexit(1)
                end
                submatch = atoi(argv[i]) % Int8
                sflag = true
            elseif c == UInt8('t')      # ending time follows
                i += 1
                if i >= argc
                    ceprintf("%s: end time must follow -t\n", pname)
                    cexit(1)
                end
                to = i
            elseif c == UInt8('v')      # show column headings
                vflag = true
            elseif c == UInt8('x')      # use alternate time format
                xflag = true
                eflag = false
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
        _annapp_help(pname, legacy ? _RDANN_LEGACY_HELP : _RDANN_HELP)
        cexit(1)
    end

    # WFDB-x: no default sampling frequency (the C program assumed 250 Hz if
    # the record had no header); -F specifies one.
    sps = _annapp_sampfreq(pname, record, ffreq, legacy, true)

    ai = [Anninfo(ainame, WFDB_READ)]
    annopen(record, ai, 1) < 0 && cexit(2)      # open annotation file

    tps = getiaorigfreq(0)
    tps < sps && (tps = sps)

    # Numbers of decimal places of the times in seconds, minutes and hours.
    sprec = 3
    n = 1000.0
    while n < tps
        sprec += 1
        n *= 10.0
    end
    tpm = 60.0 * tps
    mprec = 5
    n = 100000.0
    while n < tpm
        mprec += 1
        n *= 10.0
    end
    tph = 60.0 * tpm
    hprec = 7
    n = 10000000.0
    while n < tph
        hprec += 1
        n *= 10.0
    end

    if from != 0
        fs = argv[from]
        c = _annapp_c0(fs)
        if c == UInt8('a')
            afrom = max(atol(_annapp_tail(fs)), 0)
            while anum < afrom && getann(0, annot) == 0
                anum += 1
                isqrs(annot.anntyp) != 0 && (bnum += 1)
            end
            anum < afrom && cexit(2)
        elseif c == UInt8('b') || c == UInt8('#')
            bfrom = max(atol(_annapp_tail(fs)), 0)
            while bnum < bfrom && getann(0, annot) == 0
                anum += 1
                isqrs(annot.anntyp) != 0 && (bnum += 1)
            end
            bnum < bfrom && cexit(2)
        else
            iannsettime(strtim(fs)) < 0 && cexit(2)
        end
    end
    if to != 0
        ts = argv[to]
        c = _annapp_c0(ts)
        if c == UInt8('a')
            ato = max(atol(_annapp_tail(ts)), 0)
            bto = 0
        elseif c == UInt8('b')
            bto = max(atol(_annapp_tail(ts)), 0)
            ato = 0
        elseif c == UInt8('#')
            bto = max(atol(_annapp_tail(ts)), 1) + bnum
            ato = 0
        else
            ato = bto = 0
            to_t = strtim(ts)
            to_t < 0 && (to_t = -to_t)
        end
    end

    if vflag                            # print column headings
        if eflag
            cprintf("Elapsed time  Sample #  ")
        elseif xflag
            cprintf("  Seconds   Minutes     Hours  ")
        else
            m = mstimstr(-1)
            if UInt8('/') in codeunits(m)
                cprintf("      Time       Date     Sample #  ")
            elseif _annapp_c0(m) == UInt8('[')
                cprintf("      Time     Sample #  ")
            else
                cprintf("      Time   Sample #  ")
            end
        end
        cprintf("Type  Sub Chan  Num\tAux\n")
    end

    setifreq(tps)
    setiafreq(0, tps)
    while getann(0, annot) == 0
        if tps == sps
            sample_num = annot.time
        else
            x = Float64(annot.time) * sps / tps + 0.5
            sample_num = d2l(x)
            Float64(sample_num) > x && (sample_num -= 1)
        end
        (to_t != 0 && sample_num > to_t) && break
        a = Int32(annot.anntyp)
        if (flag[1] || (isann(a) != 0 && flag[a+1])) &&
           (!cflag || Int32(annot.chan) == Int32(chanmatch)) &&
           (!nflag || annot.num == nummatch) && (!sflag || annot.subtyp == submatch)
            if eflag
                cprintf("%s  %7lld", mstimstr(annot.time), sample_num)
            elseif xflag
                cprintf("%*.*f %*.*f %*.*f", sprec + 6, sprec, annot.time / tps,
                        mprec + 4, mprec, annot.time / tpm, hprec + 2, hprec, annot.time / tph)
            else
                cprintf("%s  %7lld", mstimstr(-annot.time), sample_num)
            end
            cprintf("%6s%5d%5d%5d", annstr(a), Int32(annot.subtyp), Int32(annot.chan),
                    Int32(annot.num))
            aux = annot.aux
            aux === nothing || cprintf("\t%s", _aux_text(aux))
            cprintf("\n")
        end
        if ato != 0
            anum += 1
            anum >= ato && break
        end
        if bto != 0 && isqrs(a) != 0
            bnum += 1
            bnum >= bto && break
        end
    end
    cexit(0)
end

register_workload("rdann") do
    with_workload_data() do dir
        for opts in ([], ["-v"], ["-e", "-v"], ["-x", "-v"], ["-f", "0:5", "-t", "0:10"],
                     ["-f", "a3", "-t", "a10"], ["-f", "b2", "-t", "b5"], ["-f", "#4", "-t", "#3"])
            workload_tool("rdann", "-r", "100s", "-a", "atr", opts...)
            workload_tool("rdann", "-r", "fmt16", "-a", "tst", opts...)
        end
        workload_tool("rdann", "-r", "fmt16", "-a", "mod", "-p", "Q!")
        workload_tool("rdann", "-r", "fmt16", "-a", "tst", "-p", "N", "V", "-s", "0", "-c", "0",
                      "-n", "0")
        workload_tool("rdann", "-r", "fmt16", "-a", "tst", "-f", "[12:40:00]", "-t", "e")
        workload_tool("rdann", "-r", "100s", "-a", "aha")
        workload_tool("rdann", "-r", "fmt16", "-a", "edf")
        workload_tool("rdann", "atr", "100s", "0:10", "0:20", "N", "V")
        workload_tool("rdann", "-r", "100s", "-a", "nosuch")
        workload_tool("rdann", "-r", "nosuch", "-a", "atr")
        workload_tool("rdann", "-r", "100s", "-a", "atr", "-q")
        workload_tool("rdann", "-r", "100s", "-a", "atr", "-f", "a1000")
        workload_tool("rdann", "-h")
    end
    with_workload_data(files=NODEFAULTS_FILES) do dir
        cp("100s.atr", "nh.atr")
        workload_tool("rdann", "-r", "nh", "-a", "atr")
        workload_tool("rdann", "-r", "nh", "-a", "atr", "-F", "360", "-t", "s2000")
        workload_tool("rdann", "-r", "nh", "-a", "atr", "-F", "x")
        # WFDB-x: legacy mode (original behavior)
        workload_tool("rdann", "--legacy", "-r", "nh", "-a", "atr", "-e")
        workload_tool("rdann", "--legacy", "-r", "nf", "-a", "atr", "-x", "-t", "0:5")
        workload_tool("rdann", "--legacy", "-r", "nh", "-a", "atr", "-F", "360")
        workload_tool("rdann", "--legacy", "-h")
    end
end
