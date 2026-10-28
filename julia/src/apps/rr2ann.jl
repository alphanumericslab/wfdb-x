# rr2ann: create an annotation file from an RR interval list.
#
# The input contains RR intervals (or times of occurrence, with -T) in text
# format, one per line. The first token on each line is taken to be an RR
# interval; any additional tokens on the same line are ignored. The output
# is an annotation file in which all beats are marked NORMAL (or have the
# types given in the second column of the input, with -w).
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of app/rr2ann.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency: -F FREQ is
# required when the record has no header or its header gives none (the original
# assumed 250 Hz); --legacy, as the first argument, restores the original
# behavior. Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md
# gives the reasons.
#
# Original C program: app/rr2ann.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2000 George B. Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

const _RR2ANN_MAXLINELEN = 1024     # longer input lines will be silently split

const _RR2ANN_HELP = (
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...] <TEXT-FILE\n",
    "where RECORD and ANNOTATOR specify the output, and OPTIONS may include:",
    " -F FREQ     use FREQ as the sampling frequency (effective only if the               header file does not exist or does not specify it)",
    " -h          print this usage summary",
    " -T          TEXT-FILE contains times of occurrence, not RR intervals",
    " -x N        multiply input by N to obtain RR in sample intervals",
    "               (default: N = 1)",
    " -w          copy annotation types from second column of input",
    "TEXT-FILE should contain a column of RR intervals (or times of occurrence,",
    "if the -T option is specified), in units of sample intervals (unless the",
    "-x option is used to specify a conversion factor).   The first token on",
    "each line is taken as an RR interval, and (if the -w option is specified)",
    "the second token is taken as an annotation mnemonic (N, V, etc.);  anything",
    "else on the same line is ignored, as are empty lines, spaces and tabs at",
    "the beginning of a line non-numeric tokens and anything following them on",
    "the same line, negative intervals, and zero intervals.  The output consists",
    "of a binary annotation file (RECORD.ANNOTATOR), and (if it does not exist",
    "already) a text header file (RECORD.hea).")
# WFDB-x: the help text of the original program, printed in legacy mode
const _RR2ANN_LEGACY_HELP = (_RR2ANN_HELP[1:2]...,
    " -F FREQ     use FREQ as the sampling frequency (effective only if no               header file exists;  default: 250)",
    _RR2ANN_HELP[4:end]...)

function rr2ann_main(args::Vector{String})
    # WFDB-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "rr2ann"
    annot = Annotation()
    sps = 0.0
    rr = Ref(0.0)
    t = 0.0
    xfactor = 1.0
    record = nothing
    ainame = nothing
    tflag = wflag = false

    # Interpret command-line options.
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
            elseif c == UInt8('F')      # sampling frequency in Hz
                i += 1
                i < argc && (sps = atof(argv[i]))
                if i >= argc || sps <= 0.0
                    ceprintf("%s: sampling frequency (> 0) must follow -F\n", pname)
                    cexit(1)
                end
            elseif c == UInt8('h')      # print usage summary and quit
                _annapp_help(pname, legacy ? _RR2ANN_LEGACY_HELP : _RR2ANN_HELP)
                cexit(0)
            elseif c == UInt8('r')      # record name follows
                i += 1
                if i >= argc
                    ceprintf("%s: record name must follow -r\n", pname)
                    cexit(1)
                end
                record = argv[i]
            elseif c == UInt8('T')      # data are times of occurrence, not RR intervals
                tflag = true
            elseif c == UInt8('x')      # multiplier to convert input to sample intervals
                i += 1
                i < argc && (xfactor = atof(argv[i]))
                if i >= argc || xfactor <= 0.0
                    ceprintf("%s: an input multiplier (> 0) must follow -x\n", pname)
                    cexit(1)
                end
            elseif c == UInt8('w')      # copy annotation types from second column of input
                wflag = true
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
        _annapp_help(pname, legacy ? _RR2ANN_LEGACY_HELP : _RR2ANN_HELP)
        cexit(1)
    end

    # sampfreq is likely to fail, since the header probably doesn't exist.
    # Suppress its error message.
    wfdbquiet()
    # WFDB-x: no default sampling frequency (the C program assumed 250 Hz);
    # -F specifies one if the record header does not.
    f = sampfreq(record)
    if f <= 0.0
        wfdbverbose()               # re-enable error reporting
        if sps == 0.0 && legacy
            sps = WFDB_DEFFREQ      # WFDB-x: legacy mode (original behavior)
        elseif sps == 0.0
            ceprintf("%s: sampling frequency of record %s is not specified (use -F)\n",
                     pname, record)
            cexit(1)
        end
        setsampfreq(sps)
        # no header: create one (the C program: in any case)
        (f < 0.0 || legacy) && newheader(record) < 0 && cexit(2)
    else
        wfdbverbose()               # re-enable error reporting
        if sps != 0.0
            ceprintf("%s (warning): -F option ignored (using %g for sampling frequency)\n",
                     pname, sampfreq(nothing))
        end
    end

    ai = [Anninfo(ainame, WFDB_WRITE)]
    annopen(record, ai, 1) < 0 && cexit(3)      # open annotation file
    annot.anntyp = NORMAL % Int8

    # Read input, write an annotation for each line beginning with a positive
    # number.
    input = wfdb_stdin()
    line = UInt8[]
    astring = UInt8[]
    while fgets!(input, line, _RR2ANN_MAXLINELEN)
        l = cstr(line)
        if !wflag                   # write all annotations as NORMAL
            csscanf(l, "%lf", rr) == 0 && continue
        else                        # copy annotation type from input
            csscanf(l, "%lf%s", rr, astring) < 2 && continue
            annot.anntyp = strann(astring) % Int8
            annot.anntyp == NOTQRS && continue
        end
        if rr[] <= 0.0
            continue
        elseif tflag
            t = rr[] * xfactor
        else
            t += rr[] * xfactor
        end
        annot.time = d2l(t + 0.5)
        putann(0, annot)
    end

    # Flush buffered output.
    wfdbquit()
    cexit(0)
end

register_workload("rr2ann") do
    with_workload_data() do dir
        workload_tool("rr2ann", "-r", "100s", "-a", "rr", "-F", "128"; stdin=read(joinpath(dir, "rr.txt")))
        workload_tool("rr2ann", "-r", "newrec", "-a", "rr", "-x", "0.5"; stdin=read(joinpath(dir, "rr.txt")))
        workload_tool("rr2ann", "-r", "newrec", "-a", "rr", "-T"; stdin="100\n50\n300\n200\n")
        workload_tool("rr2ann", "-r", "newrec", "-a", "rr", "-w"; stdin=read(joinpath(dir, "rrw.txt")))
        workload_tool("rr2ann", "-r", "newrec", "-a", "rr", "-F", "0")
        workload_tool("rr2ann", "-h")
        workload_tool("rr2ann", "-r", "newrec2", "-a", "rr"; stdin="100\n")
    end
    with_workload_data(files=NODEFAULTS_FILES) do dir
        workload_tool("rr2ann", "-r", "nf", "-a", "rr", "-F", "360"; stdin=read(joinpath(dir, "rr.txt")))
        # WFDB-x: legacy mode (original behavior)
        workload_tool("rr2ann", "--legacy", "-r", "nl", "-a", "rr"; stdin="100\n200\n")
        workload_tool("rr2ann", "--legacy", "-h")
    end
end
