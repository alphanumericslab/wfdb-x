# snip: copy an excerpt of a database record.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of app/snip.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency: the input record
# must give it, for the header of the excerpt (the original assumed 250 Hz); a
# master header that cannot be written is reported (wfdbx_fclose_output);
# --legacy, as the first argument, restores the original behavior. Each change
# is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
#
# Original C program: app/snip.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1989-2013 George B. Moody; revised 2011-2021 by
#   Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

const _SNIP_HELP = (
    "usage: %s -i IREC -n NREC [OPTIONS ...]\n",
    "where IREC is the name of the record to be converted, NREC is the name to",
    "be given to the record to be generated, and OPTIONS may include any of:",
    " -a ANNOTATOR [ANNOTATOR ...]  copy annotations for the specified ANNOTATOR",
    "              from IREC;  two or more ANNOTATORs may follow -a",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -l DURATION snip only DURATION (hh:mm:ss or sNNNN; overrides -t)",
    " -m          preserve segments of multsegment input, if possible",
    " -O FORMAT   save output in the specified FORMAT (default: use best fit",
    "              to ADC resolution)",
    " -s          suppress output of info strings in header",
    " -t TIME     stop at specified time",
    "To change the sampling frequency, zero level, or gain, to select a",
    "subset of signals, or to re-order signals, use `xform'.")

function _snip_help(pname)
    ceprintf(_SNIP_HELP[1], pname)
    for i in 2:length(_SNIP_HELP)
        ceprintf("%s\n", _SNIP_HELP[i])
    end
end

# The C program's global variables.
mutable struct _SnipState
    pname::String
    fmt::Int32      # use specified output format if fmt > 0
    mflag::Bool     # try to preserve segments if set
    sflag::Bool     # suppress copying info if set
end

function _snip_copy_ann(sn::_SnipState, nrec::Vector{UInt8}, irec::Vector{UInt8}, from::Int64,
                        to::Int64, annotators::Vector{Vector{UInt8}})
    nann = length(annotators)
    annot = Annotation()
    ai = [Anninfo(a, WFDB_READ) for a in annotators]
    ao = [Anninfo(a, WFDB_WRITE) for a in annotators]

    # Open the input annotators.
    if annopen(irec, ai, nann) < 0
        ceprintf("%s: error opening input annotators\n", sn.pname)
        cexit(2)
    end

    # Open the output annotators.
    if annopen(cformat("+%s", nrec), ao, nann) < 0
        ceprintf("%s: error opening output annotators\n", sn.pname)
        cexit(2)
    end

    # Copy the selected segment.
    for i in 0:nann-1
        while getann(i, annot) == 0
            if annot.time >= from && (to == 0 || annot.time < to)
                annot.time -= from
                putann(i, annot) < 0 && break
            end
        end
    end
    wfdbquit()
end

# The output format that best fits the ADC resolution of the signals: their
# common format if they have one.
function _snip_best_format(si::Vector{Siginfo})
    maxres = si[1].adcres
    fmt = si[1].fmt
    for k in 2:length(si)
        si[k].adcres > maxres && (maxres = si[k].adcres)
        si[k].fmt != fmt && (fmt = Int32(0))
    end
    fmt != 0 && return fmt
    maxres > 24 ? Int32(32) :
    maxres > 16 ? Int32(24) :
    maxres > 12 ? Int32(16) :
    maxres > 10 ? Int32(212) :
    maxres > 8 ? Int32(310) : Int32(80)
end

function _snip_copy_sig(sn::_SnipState, nrec::Vector{UInt8}, irec::Vector{UInt8}, from::Int64,
                        to::Int64, recurse::Bool)
    tstring = nothing

    wfdbquit()
    nsig = isigopen(irec, nothing, 0)
    if nsig < 0
        ceprintf("%s: error opening header for %s\n", sn.pname, irec)
        cexit(2)
    end

    v = zeros(Int32, max(nsig, 1))
    si = [Siginfo() for _ in 1:nsig]

    # Open the input signals.
    if isigopen(irec, si, nsig) != nsig
        ceprintf("%s: error opening signals for %s\n", sn.pname, irec)
        cexit(2)
    end

    p = codeunits(mstimstr(-from))
    if get(p, 1, 0x00) == UInt8('[')
        ts = Vector{UInt8}(p[2:end])
        k = findfirst(==(UInt8(']')), ts)
        k === nothing || resize!(ts, k - 1)
        k = findfirst(==(UInt8(' ')), ts)
        if k !== nothing && findnext(==(UInt8('/')), ts, k) === nothing
            resize!(ts, k - 1)
        end
        tstring = ts
    end

    segref = Ref{Union{Nothing,Vector{Seginfo}}}(nothing)
    maxseg = recurse ? getseginfo(segref) : Int32(0)
    if maxseg > 0           # irec has multiple segments
        seginfo = segref[]::Vector{Seginfo}
        sfreq = sampfreq(nothing)

        ohfname = cformat("%s.hea", nrec)
        ohfile = cfopen(ohfname, "wb")
        if ohfile === nothing
            ceprintf("%s: can't create master header\n", sn.pname)
            cexit(2)
        end

        varlayout = seginfo[1].nsamp == 0
        if varlayout        # irec has variable layout
            for s in si
                s.fname = Vector{UInt8}(b"~")
                s.fmt = 0
                s.nsamp = 0
                s.cksum = 0
            end
            tstring === nothing || setbasetime(tstring)
            if 0 > setheader(cformat("%s_layout", nrec), si, nsig)
                ceprintf("%s: can't create layout header\n", sn.pname)
                cexit(2)
            end
            if !sn.sflag
                wfdbquiet()     # Suppress errors from the WFDB library.
                info = getinfo(irec)
                while info !== nothing
                    putinfo(info)
                    info = getinfo(nothing)
                end
                wfdbverbose()
                sn.sflag = true
            end
        end

        # Figure out which input segments contain data to be copied
        first_seg, last_seg = 1, Int(maxseg)
        for k in 1:maxseg
            t = seginfo[k].samp0
            tf = seginfo[k].samp0 + seginfo[k].nsamp
            (t <= from && from < tf) && (first_seg = k)
            if t <= to && to <= tf
                last_seg = k
                break
            end
        end
        nseg = Int32(last_seg - first_seg + 1)
        varlayout && (nseg += Int32(1))

        tf = seginfo[last_seg].samp0 + seginfo[last_seg].nsamp
        to > tf && (to = tf)

        # Start writing the master output header.
        cfprintf(ohfile, "%s/%d %d %.12g %ld", nrec, nseg, nsig, sfreq, to - from)
        tstring === nothing || cfprintf(ohfile, " %s", tstring)
        cfprintf(ohfile, "\r\n")
        varlayout && cfprintf(ohfile, "%s_layout 0\r\n", nrec)

        i = Int32(0)
        for j in first_seg:last_seg
            t = seginfo[j].samp0
            tf = seginfo[j].samp0 + seginfo[j].nsamp
            to < tf && (tf = to)    # this is the last segment with data to copy
            if from > t
                start, len = from - t, tf - from
            else
                start, len = Int64(0), tf - t
            end
            if cstr(seginfo[j].recname) == b"~"
                orseg = Vector{UInt8}(b"~")
            else
                i += Int32(1)
                orseg = cformat("%s_%04d", nrec, i)
                _snip_copy_sig(sn, orseg, seginfo[j].recname, start, start + len, false)
            end
            cfprintf(ohfile, "%s %ld\r\n", orseg, len)
        end
        wfdbx_fclose_output(ohfile, sn.pname, ohfname)     # WFDB-x
        return
    end

    # no -O option: choose format based on ADC resolution
    sn.fmt <= 0 && (sn.fmt = _snip_best_format(si))

    # Open the output signals.
    ofname = cformat("%s.dat", nrec)
    for s in si
        s.fname = ofname
        s.group = 0
        s.fmt = sn.fmt
        s.spf = 1
    end
    osigfopen(si, nsig) != nsig && cexit(2)

    # Copy the selected segment.
    isigsettime(from) < 0 && cexit(2)
    wfdbquiet()
    nsamp = to == 0 ? Int64(-1) : to - from
    while nsamp == -1 || (nsamp -= 1) + 1 > 0     # (C: nsamp-- > 0)
        stat = getvec(v)
        if stat > 0 || nsamp == 0
            putvec(v)
        else
            break
        end
    end

    # Clean up.
    wfdbverbose()
    setsampfreq(sampfreq(nothing))
    tstring === nothing || setbasetime(tstring)
    newheader(nrec)
    nothing
end

function _snip_copy_info(sn::_SnipState, irec::Vector{UInt8}, startp)
    wfdbquiet()     # Suppress error messages from the WFDB library.
    info = getinfo(irec)
    while info !== nothing
        putinfo(info)
        info = getinfo(nothing)
    end
    # Append additional info summarizing what snip has done.
    putinfo(cformat("Produced by %s from record %s, beginning at %s", sn.pname, irec, startp))
    wfdbverbose()
end

function snip_main(args::Vector{String})
    # WFDB-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    sn = _SnipState("snip", 0, false, false)
    pname = sn.pname
    nrec = irec = startp = endp = len = nothing
    ann_first = nann = 0

    i = 1
    while i < argc
        a = argv[i]
        if get(a, 1, 0x00) == UInt8('-')
            c = get(a, 2, 0x00)
            if c == UInt8('a')          # annotator(s) follow
                i += 1
                if i >= argc
                    ceprintf("%s: annotator(s) must follow -a\n", pname)
                    cexit(1)
                end
                # Accept the next argument unconditionally as an annotator
                # name; accept additional arguments until we find one
                # beginning with `-', or the end of the argument list.  As in
                # C, the count of annotators is not reset if -a is given more
                # than once, and the names are those that follow the last -a
                # (see "Undefined behaviors" in docs/KNOWN_C_BEHAVIORS.md).
                ann_first = i
                nann += 1
                i += 1
                while i < argc && get(argv[i], 1, 0x00) != UInt8('-')
                    nann += 1
                    i += 1
                end
                i < argc && (i -= 1)
            elseif c == UInt8('f')      # starting time
                i += 1
                if i >= argc
                    ceprintf("%s: time must follow -f\n", pname)
                    cexit(1)
                end
                startp = argv[i]
            elseif c == UInt8('h')      # help requested
                _snip_help(pname)
                cexit(0)
            elseif c == UInt8('i') || c == UInt8('r')   # input record name (-r: same as -i)
                i += 1
                if i >= argc
                    ceprintf("%s: input record name must follow -i\n", pname)
                    cexit(1)
                end
                irec = argv[i]
            elseif c == UInt8('l')      # length of snip
                i += 1
                if i >= argc
                    ceprintf("%s: duration must follow -l\n", pname)
                    cexit(1)
                end
                len = argv[i]
            elseif c == UInt8('m')      # preserve segments of multisegment input, if possible
                sn.mflag = true
            elseif c == UInt8('n')      # new record name
                i += 1
                if i >= argc
                    ceprintf("%s: new record name must follow -n\n", pname)
                    cexit(1)
                end
                nrec = argv[i]
            elseif c == UInt8('O')      # output format
                i += 1
                if i >= argc
                    ceprintf("%s: output format must follow -O\n", pname)
                    cexit(1)
                end
                sn.fmt = strtol(argv[i], 10)[1] % Int32
            elseif c == UInt8('s')      # suppress copying of info
                sn.sflag = true
            elseif c == UInt8('t')      # end time
                i += 1
                if i >= argc
                    ceprintf("%s: time must follow -t\n", pname)
                    cexit(1)
                end
                endp = argv[i]
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
    if irec === nothing || nrec === nothing
        _snip_help(pname)
        cexit(1)
    end
    startp === nothing && (startp = Vector{UInt8}(b"0"))
    endp === nothing && (endp = Vector{UInt8}(b"e"))

    # Verify that the output record can be written.
    if newheader(nrec) < 0
        ceprintf("%s: can't create output header\n", pname)
        cexit(2)
    end

    # Determine the number of signals.
    nsig = isigopen(irec, nothing, 0)
    if nsig < 0
        ceprintf("%s: error reading input header\n", pname)
        cexit(2)
    end
    # WFDB-x: the output header needs the sampling frequency (the C program
    # assumed 250 Hz if the input header did not specify one, as legacy mode
    # does).
    if !legacy && sampfreq(nothing) <= 0.0
        ceprintf("%s: sampling frequency of record %s is not specified\n", pname, irec)
        wfdbquit()
        cexit(2)
    end

    # Evaluate the time limits.
    from = strtim(startp)
    from < 0 && (from = -from)
    if len !== nothing
        to = from + strtim(len)
    else
        to = strtim(endp)
        to < 0 && (to = -to)
    end
    endt = strtim("e")
    if (endt > 0 && endt < from) || (to > 0 && to < from)
        ceprintf("%s: improper interval selected\n", pname)
        wfdbquit()
        cexit(1)
    end

    # Copy the annotations, if any.
    # (names beyond the last argument, which C reads past the end of argv,
    # are ignored)
    annotators = nann > 0 ? argv[ann_first:min(ann_first + nann - 1, argc - 1)] :
                 Vector{UInt8}[]
    isempty(annotators) || _snip_copy_ann(sn, nrec, irec, from, to, annotators)

    # Copy the signals, if any.
    nsig > 0 && _snip_copy_sig(sn, nrec, irec, from, to, sn.mflag)

    # Copy info strings from the input header file into the new one, unless
    # suppressed with -s.
    sn.sflag || _snip_copy_info(sn, irec, startp)

    wfdbquit()
    cexit(0)
end

register_workload("snip") do
    with_workload_data() do dir
        workload_tool("snip", "-i", "100s", "-n", "o1", "-f", "1", "-t", "3", "-a", "atr")
        workload_tool("snip", "-i", "100s", "-n", "o2", "-f", "s10", "-l", "s100", "-O", "16", "-s")
        workload_tool("snip", "-i", "multi", "-n", "o3", "-m", "-f", "s5", "-t", "s50")
        workload_tool("snip", "-i", "vlay", "-n", "o4", "-m", "-f", "s5", "-t", "s50")
        workload_tool("snip", "-i", "fmt16", "-n", "o5", "-f", "[12:35:00]", "-t", "e")
        workload_tool("snip", "-i", "fmt212", "-n", "o6", "-t", "s20")
        workload_tool("snip", "-i", "100s", "-n", "o7", "-f", "10", "-t", "5")
        workload_tool("snip", "-i", "100s", "-n", "o8", "-a", "nosuch")
        workload_tool("snip", "-i", "nosuch", "-n", "o9")
        workload_tool("snip", "-i", "100s")
        workload_tool("snip", "-h")
        workload_tool("snip", "-x")
        workload_tool("snip", "x")
        workload_tool("snip", "-i")
    end
    with_workload_data(files=NODEFAULTS_FILES) do dir
        workload_tool("snip", "-i", "nf", "-n", "snp")
        workload_tool("snip", "--legacy", "-i", "nf", "-n", "snl", "-f", "1", "-t", "2")
    end
end
