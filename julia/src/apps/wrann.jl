# wrann: translate an ASCII annotation file to binary format.
#
# The input is in the format produced by rdann. Where the C program has
# undefined behavior (a line with no space after column 9, or a mnemonic
# longer than 9 characters), this translation treats the remainder of the
# line as empty, and uses the full mnemonic (see docs/KNOWN_C_BEHAVIORS.md).
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of app/wrann.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior).
#
# Original C program: app/wrann.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1983-2010 George B. Moody; revised 2018 by Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

const _WRANN_LINELEN = 400      # size of the input line buffer
const _WRANN_TIMECOL = 9        # the sample number follows the first space from column 9
const _WRANN_AUXBUF = 256       # size of the aux string buffer

function _wrann_help(pname)
    ceprintf("usage: %s -r RECORD -a ANNOTATOR <TEXT-FILE\n", pname)
    ceprintf("TEXT-FILE should be in the format produced by `rdann'.\n")
end

function wrann_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    wfdbx_legacy_args(args)
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "wrann"
    record = nothing
    ainame = nothing
    sub = Ref{Int32}(0)
    ch = Ref{Int32}(0)
    nm = Ref{Int32}(0)
    tm = Ref{Int64}(0)
    annot = Annotation()
    # The mnemonic buffer (static in C: it keeps its contents when a line has
    # no mnemonic).
    mnem = UInt8[]

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
            elseif c == UInt8('h')      # print usage summary and quit
                _wrann_help(pname)
                cexit(0)
            elseif c == UInt8('r')      # input record name follows
                i += 1
                if i >= argc
                    ceprintf("%s: input record name must follow -r\n", pname)
                    cexit(1)
                end
                record = argv[i]
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
        _wrann_help(pname)
        cexit(1)
    end

    setafreq(sampfreq(record))
    ai = [Anninfo(ainame, WFDB_WRITE)]
    annopen(record, ai, 1) < 0 && cexit(2)      # open annotation file

    input = wfdb_stdin()
    buf = UInt8[]
    while fgets!(input, buf, _WRANN_LINELEN)
        line = cstr(buf)
        n = length(line)
        p = _WRANN_TIMECOL                      # (0-based)
        if _annapp_c0(line) == UInt8('[')
            while p < n && line[p+1] != UInt8(']')
                p += 1
            end
        end
        while p < n && line[p+1] != UInt8(' ')
            p += 1
        end
        rest = p < n ? line[p+2:n] : UInt8[]
        csscanf(rest, "%lld%s%d%d%d", tm, mnem, sub, ch, nm)
        annot.anntyp = strann(mnem) % Int8
        if _annapp_c0(line) == UInt8('[')
            annot.time = -strtim(line)
            annot.time < 0 && continue
        else
            annot.time = tm[]
        end
        annot.subtyp = sub[] % Int8
        annot.chan = ch[] % UInt8
        annot.num = nm[] % Int8
        # If mnem does not contain a recognizable mnemonic, write a NOTE
        # annotation and put mnem at the beginning of the aux field.
        if annot.anntyp == NOTQRS
            annot.anntyp = NOTE % Int8
            astr = copy(mnem)
        else
            empty!(mnem)
            astr = UInt8[]
        end
        tab = findfirst(==(UInt8('\t')), rest)
        ap = UInt8[]
        if tab !== nothing                      # auxinfo at end of line
            ap = rest[tab:end]
            cut = if length(astr) + length(ap) + 2 > _WRANN_AUXBUF
                _WRANN_AUXBUF - length(astr) - 3
            else
                -1                              # discard trailing newline
            end
            cut < 0 && (cut += length(ap))
            cut < 0 && (cut = 0)
            cut < length(ap) && resize!(ap, cut)
        end
        # Create an aux string if needed.
        if !isempty(astr) || tab !== nothing
            tail = length(ap) > 1 ? ap[2:end] : UInt8[]
            s = if !isempty(astr) && tab !== nothing
                [astr; UInt8(' '); tail]
            elseif !isempty(astr)
                astr
            else
                tail
            end
            annot.aux = UInt8[(length(s) & 0xff) % UInt8; s]
        else
            annot.aux = nothing
        end
        putann(0, annot)
    end
    wfdbquit()
    cexit(0)
end

register_workload("wrann") do
    with_workload_data() do dir
        workload_tool("wrann", "-r", "100s", "-a", "cpy"; stdin=read(joinpath(dir, "100s.atr.txt")))
        workload_tool("wrann", "-r", "fmt16", "-a", "cpy"; stdin=read(joinpath(dir, "tst.txt")))
        workload_tool("wrann", "-r", "100s", "-a", "el"; stdin=read(joinpath(dir, "elapsed.txt")))
        workload_tool("wrann", "-r", "100s", "-a", "ooo"; stdin=read(joinpath(dir, "ooo.txt")))
        workload_tool("wrann", "-r", "100s", "-a", "nomn";
                      stdin="    0:00.050       18     V    0    0    0\n    0:00.100       36\n" *
                            "    0:00.300      108  \n    0:00.400      144\tnote\n" *
                            "    0:00.500      180     Z    0    0    0\t" * "y" ^ 300 * "\n")
        workload_tool("wrann", "-r", "nohdr", "-a", "x"; stdin="    0:00.050       18     N\n")
        workload_tool("wrann", "-r", "100s", "-a", "bad*name")
        workload_tool("wrann", "-h")
        workload_tool("wrann", "-r", "100s")
    end
end
