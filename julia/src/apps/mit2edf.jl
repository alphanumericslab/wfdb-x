# mit2edf: convert MIT format header and signal files to EDF (European Data
# Format) file.
#
# As in the C program, the current date and time are used as the start of a
# record that has none. Where the C program has undefined behavior, this
# translation uses: 0 for time and date fields that cannot be parsed; the
# first 50 characters of a long record name for the default output file
# name; and it does not write header fields past the end of the header (if
# they are longer than their space), divide by zero (when no frame fits in a
# block, or in verbose mode when a block is longer than a minute), or name a
# month outside 1-12 (DEC is used, as by the other wfdb-x implementations).
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of convert/mit2edf.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency, gain or ADC
# resolution: the record must give the sampling frequency, and the gain and ADC
# resolution of every signal (the original assumed 250 Hz and 200 adu/mV, and
# guessed the resolution from the storage format); unspecified units are
# written as "nd" (the original wrote "mV"); --legacy, as the first argument,
# restores the original behavior. Each change is marked "wfdb-x:" in the code;
# docs/DIVERGENCES.md gives the reasons.
#
# Original C program: convert/mit2edf.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2002-2014 George B. Moody; revised 2020 by Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

"Maximum data block length, in bytes."
const EDFMAXBLOCK = Int64(61440)
"Length of the fixed part of an EDF header, and of each signal's part."
const _EDF_HEADER_UNIT = 256
"Nominal duration of a data block, in seconds."
const _MIT2EDF_BLOCK_SECONDS = 10
"Factor by which overlong data blocks are shortened."
const _MIT2EDF_BLOCK_REDUCTION = 10
"Year and month of the beginning of the EDF epoch (used without a date)."
const _EDF_EPOCH_YEAR = Int32(1985)
"Maximum length of the patient identification (record name)."
const _MIT2EDF_MAXRECLEN = 80
"Range of characters allowed in an EDF header (printable ASCII)."
const _EDF_MINCHAR = 32
const _EDF_MAXCHAR = 126

const _MIT2EDF_MONTH = ("JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                        "JUL", "AUG", "SEP", "OCT", "NOV", "DEC")

const _MIT2EDF_HELP = (
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -h          print this usage summary",
    " -o EDFILE   write the specified European Data Format file (default:",
    "              RECORD.edf)",
    " -p          write the output as an EDF+ file",
    " -v          select verbose mode",
    "This program reads MIT-format signal and header files and writes an EDF",
    "file containing the same data.")

# The EDF header being built, with the current (C) position.
mutable struct _Mit2edfHeader
    h::Vector{UInt8}
    pos::Int
end

# strncpy(header + pos, s, len): copy at most len bytes of s, padding with
# NULs (within the header).
function _mit2edf_put!(hd::_Mit2edfHeader, s, len::Integer)
    b = cstr(bytes(s))
    for m in 0:len-1
        hd.pos + m >= length(hd.h) && break
        hd.h[hd.pos+m+1] = m < length(b) ? b[m+1] : 0x00
    end
end

# Copy all of s, then advance by the length of the field.
function _mit2edf_field!(hd::_Mit2edfHeader, s, fieldlen::Integer)
    _mit2edf_put!(hd, s, length(cstr(bytes(s))))
    hd.pos += fieldlen
end

# The ADC resolution of a storage format, as guessed by the C program (and
# legacy mode) if the header does not give it.
function _mit2edf_legacy_adcres(fmt::Int32)
    (fmt == 524 || fmt == 24) ? Int32(24) :
    fmt == 32 ? Int32(32) :
    (fmt == 508 || fmt == 80) ? Int32(8) :
    fmt == 212 ? Int32(12) :
    (fmt == 310 || fmt == 311) ? Int32(10) :
    (fmt == 516 || fmt == 16 || fmt == 61 || fmt == 160) ? Int32(16) :
    # resolution for unknown future formats
    (fmt >= 100 && fmt % 100 > 0 && fmt % 100 <= 32) ? fmt % Int32(100) : Int32(16)
end

function mit2edf_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "mit2edf"
    ofname = nothing
    record = nothing
    edfplusflag = false
    vflag = false
    blocks_per_minute = blocks_per_hour = Int64(0)

    # Interpret the command line.
    i = 1
    while i < argc
        a = argv[i]
        if !isempty(a) && a[1] == UInt8('-')
            c = length(a) >= 2 ? a[2] : 0x00
            if c == UInt8('h')          # show usage and quit
                _convert_help(pname, _MIT2EDF_HELP)
                cexit(0)
            elseif c == UInt8('o')      # output file name follows
                i += 1
                if i < argc
                    ofname = cstr(argv[i])
                else
                    ceprintf("%s: output file name must follow -o\n", pname)
                    cexit(1)
                end
            elseif c == UInt8('p')      # format output as EDF+
                edfplusflag = true
            elseif c == UInt8('r')      # record name follows
                i += 1
                if i < argc
                    record = copy(cstr(argv[i]))
                else
                    ceprintf("%s: record name must follow -r\n", pname)
                    cexit(1)
                end
            elseif c == UInt8('v')      # select verbose mode
                vflag = true
            end
        end
        i += 1
    end

    # Quit if no record was specified.
    if record === nothing
        _convert_help(pname, _MIT2EDF_HELP)
        cexit(1)
    end

    # Construct or validate the name of the output file.
    if ofname === nothing
        k = findlast(==(UInt8('/')), record)
        tail = k === nothing ? record : record[k+1:end]
        ofname = vcat(tail[1:min(length(tail), WFDB_MAXRNL)], b".edf")
    elseif edfplusflag
        p = ofname[max(length(ofname) - 3, 1):end]
        if p != b".edf" && p != b".EDF"
            ceprintf("%s: '%s' is not a valid EDF+ file name\n", pname, ofname)
            ceprintf(" EDF+ file names must end with '.edf' or '.EDF')\n")
            cexit(1)
        end
    end

    # Open the input record.
    nsig = isigopen(record, nothing, 0)
    nsig <= 0 && cexit(2)
    si = [Siginfo() for _ in 1:nsig]
    nsig = isigopen(record, si, nsig)
    nsig <= 0 && cexit(3)
    ns = Int(nsig)

    # wfdb-x: an EDF file needs the sampling frequency, and the gain and the
    # ADC resolution of each signal (the C program assumed 250 Hz and
    # 200 adu/mV if the header did not specify them, and guessed the
    # resolution from the storage format, as legacy mode does).
    if !legacy && sampfreq(nothing) <= 0.0
        ceprintf("%s: sampling frequency of record %s is not specified\n", pname, record)
        cexit(3)
    end
    for k in 1:ns
        legacy && break
        if si[k].gain == 0.0
            ceprintf("%s: signal %d of record %s is uncalibrated\n", pname, k - 1, record)
            cexit(3)
        end
        if si[k].adcres < 1         # the EDF digital range needs it
            ceprintf("%s: ADC resolution of signal %d of record %s is not specified\n",
                     pname, k - 1, record)
            cexit(3)
        end
    end

    # Open the output (EDF) file.
    ofile = cfopen(ofname, "wb")
    if ofile === nothing
        ceprintf("%s: can't create %s\n", pname, ofname)
        cexit(4)
    end

    # Get start date and time
    ts = timstr(0)
    start_date_recorded = true
    if !startswith(ts, '[')         # start date/time not recorded -- use current date
        setbasetime(nothing)
        ts = timstr(0)
        start_date_recorded = false
    end
    hour, minute, second = Ref{Int32}(0), Ref{Int32}(0), Ref{Int32}(0)
    day, month, year = Ref{Int32}(0), Ref{Int32}(0), Ref{Int32}(0)
    if csscanf(ts, "[%d:%d:%d %d/%d/%d", hour, minute, second, day, month, year) != 6
        # start time, but not date, recorded
        start_date_recorded = false
        day[] = month[] = Int32(1)
        year[] = _EDF_EPOCH_YEAR     # beginning of EDF epoch
    end

    # Calculate block duration. (In the EDF spec, blocks are called "records"
    # or "data records", but this would be confusing here since "record"
    # refers to the entire recording -- so here we say "blocks".)
    samples_per_frame = Int32(0)
    for s in si
        samples_per_frame += s.spf
    end
    frames_per_minute = strtim("1:0")
    frames_per_second = frames_per_minute / 60.0
    frames_per_block = d2l(_MIT2EDF_BLOCK_SECONDS * frames_per_second + 0.5)
    # EDF specifies 2 bytes per sample
    bytes_per_block = Int64(_EDF_SAMPLE_BYTES * samples_per_frame) * frames_per_block
    while bytes_per_block > EDFMAXBLOCK
        # blocks would be too long -- reduce their length by a factor of 10
        frames_per_block ÷= _MIT2EDF_BLOCK_REDUCTION
        bytes_per_block = Int64(samples_per_frame * _EDF_SAMPLE_BYTES) * frames_per_block
    end

    seconds_per_block = frames_per_block / frames_per_second

    if frames_per_block < 1 && bytes_per_block < EDFMAXBLOCK ÷ 60
        frames_per_block = strtim("1:0")    # the number of frames/minute
        bytes_per_block = Int64(_EDF_SAMPLE_BYTES * samples_per_frame) * frames_per_block
        seconds_per_block = 60.0
    end

    if bytes_per_block > EDFMAXBLOCK
        ceprintf("%s: can't convert record %s to EDF\n", pname, record)
        ceprintf(" EDF blocks cannot be larger than %d bytes, but each input frame requires\n",
                 EDFMAXBLOCK)
        ceprintf(" %d bytes.  Use 'snip' to select a subset of the input signals, or use\n 'xform' to reduce the sampling frequency.\n",
                 samples_per_frame * Int32(_EDF_SAMPLE_BYTES))
        cexit(5)
    end

    # Calculate the number of blocks to be written. strtim("e") is the frame
    # number of the last frame in the record, and that of the first frame is
    # 0, so the number of frames is strtim("e") + 1. The calculation rounds
    # up so that we don't lose any frames, even if the number of frames is
    # not an exact multiple of frames_per_block.
    nblocks = (frames_per_block != 0 ? strtim("e") ÷ frames_per_block : Int64(0)) + 1

    # Allocate and initialize arrays and buffers.
    dmax = zeros(Int32, ns)
    dmin = zeros(Int32, ns)
    pmax = zeros(Float64, ns)
    pmin = zeros(Float64, ns)
    hlen = (ns + 1) * _EDF_HEADER_UNIT
    hd = _Mit2edfHeader(fill(UInt8(' '), hlen), 0)
    v = zeros(Int32, max(Int(samples_per_frame), 0))
    block = zeros(UInt8, max(bytes_per_block, 0))
    blockp = zeros(Int64, ns)       # C offsets within block

    vflag && cprintf("Converting record %s to %s (%s mode)\n", record, ofname,
                     edfplusflag ? "EDF+" : "EDF")

    # Calculate physical and digital extrema.
    for i in 1:ns
        s = si[i]
        # (wfdb-x: the ADC resolution was checked above; the C program
        # guessed it from the storage format if the header did not give it,
        # as legacy mode does.)
        legacy && s.adcres < 1 && (s.adcres = _mit2edf_legacy_adcres(s.fmt))
        half = UInt32(1) << ((s.adcres - Int32(1)) & 31)
        dmax[i] = (reinterpret(UInt32, s.adczero) + half - UInt32(1)) % Int32
        dmin[i] = (reinterpret(UInt32, s.adczero) - half) % Int32
        pmax[i] = aduphys(i - 1, dmax[i])
        pmin[i] = aduphys(i - 1, dmin[i])
    end

    # Start filling in the header. The first line of comments above each
    # entry is as given in the EDF technical specification
    # (http://www.hsr.nl/edf/edf_spec.htm).

    # Version of this data format (0).
    _mit2edf_put!(hd, "0", 1)
    hd.pos += _EDF_VERSION_LEN

    # Local patient identification.
    length(record) > _MIT2EDF_MAXRECLEN && resize!(record, _MIT2EDF_MAXRECLEN - 1)
    _mit2edf_field!(hd, record, _EDF_ID_LEN)

    # Local recording identification.
    #
    # Bob Kemp recommends using this field to encode the start date including
    # an abbreviated month name in English and a full (4-digit) year, as is
    # done here if this information is available in the input record. EDF+
    # requires this.
    if start_date_recorded
        mname = _MIT2EDF_MONTH[1 <= month[] <= 12 ? month[] : 12]
        buf = cformat("Startdate %02d-%s-%d", day[], mname, year[])
    else
        buf = cformat("Startdate not recorded")
        edfplusflag && ceprintf("WARNING (%s): EDF+ requires start date (not specified)\n", pname)
    end
    _mit2edf_field!(hd, buf, _EDF_ID_LEN)

    # Start date of recording (dd.mm.yy).
    _mit2edf_put!(hd, cformat("%02d.%02d.%02d", day[], month[], year[] % Int32(100)), _EDF_SHORT_LEN)
    hd.pos += _EDF_SHORT_LEN

    # Start time of recording (hh.mm.ss).
    _mit2edf_put!(hd, cformat("%02d.%02d.%02d", hour[], minute[], second[]), _EDF_SHORT_LEN)
    hd.pos += _EDF_SHORT_LEN

    # Number of bytes in header.
    _mit2edf_field!(hd, cformat("%ld", (Int64(nsig) + 1) * _EDF_HEADER_UNIT), _EDF_SHORT_LEN)

    # Reserved.
    edfplusflag && _mit2edf_put!(hd, "EDF+C", 5)
    hd.pos += _EDF_RESERVED_LEN

    # Number of blocks (-1 if unknown).
    _mit2edf_field!(hd, cformat("%ld", nblocks), _EDF_SHORT_LEN)

    # Duration of a block, in seconds.
    buf = cformat("%g", seconds_per_block)
    length(buf) > _EDF_SHORT_LEN && resize!(buf, _EDF_SHORT_LEN)
    _mit2edf_field!(hd, buf, _EDF_SHORT_LEN)

    # Number of signals.
    _mit2edf_field!(hd, cformat("%d", nsig), _EDF_NSIG_LEN)

    # Label (e.g., EEG FpzCz or Body temp).
    for s in si
        s.desc === nothing && (s.desc = UInt8[])
        length(s.desc) > _EDF_LABEL_LEN && resize!(s.desc, _EDF_LABEL_LEN)
        _mit2edf_field!(hd, s.desc, _EDF_LABEL_LEN)
    end

    # Transducer type (e.g., AgAgCl electrode).
    for _ in 1:ns
        _mit2edf_field!(hd, "transducer type not recorded", _EDF_ID_LEN)
    end

    # Physical dimension (e.g., uV or degreeC).
    for s in si
        if s.units === nothing      # wfdb-x: unspecified units are "nd" (C, legacy: mV)
            s.units = Vector{UInt8}(legacy ? b"mV" : b"nd")
        elseif length(s.units) > _EDF_SHORT_LEN
            resize!(s.units, _EDF_SHORT_LEN)
        end
        _mit2edf_field!(hd, s.units, _EDF_SHORT_LEN)
    end

    # Physical minimum (e.g., -500 or 34).
    for x in pmin
        _mit2edf_field!(hd, cformat("%g", x), _EDF_SHORT_LEN)
    end

    # Physical maximum (e.g., 500 or 40).
    for x in pmax
        _mit2edf_field!(hd, cformat("%g", x), _EDF_SHORT_LEN)
    end

    # Digital minimum (e.g., -2048).
    for x in dmin
        _mit2edf_field!(hd, cformat("%d", x), _EDF_SHORT_LEN)
    end

    # Digital maximum (e.g., 2047).
    for x in dmax
        _mit2edf_field!(hd, cformat("%d", x), _EDF_SHORT_LEN)
    end

    # Prefiltering (e.g., HP:0.1Hz LP:75Hz).
    for _ in 1:ns
        _mit2edf_field!(hd, "prefiltering not recorded", _EDF_ID_LEN)
    end

    # Number of samples per block.
    for s in si
        _mit2edf_field!(hd, cformat("%ld", frames_per_block * s.spf), _EDF_SHORT_LEN)
    end

    # (The last 32*nsig bytes in the header are unused.)

    # Write the header to the output file.
    header = hd.h
    fwrite(ofile, header)

    # Check that all characters in the header are valid (printable ASCII
    # between 32 and 126 inclusive). Note that this test does not prevent
    # generation of files containing invalid characters; it merely warns the
    # user if this has happened.
    for (k, b) in enumerate(header)
        c = reinterpret(Int8, b)
        if c < _EDF_MINCHAR || c > _EDF_MAXCHAR
            ceprintf("WARNING (%s): output contains an invalid character, %d, at byte %d\n",
                     pname, Int32(c), Int32(k - 1))
        end
    end

    # In verbose mode, summarize what we've done so far.
    if vflag
        cprintf(" Header block size: %d bytes\n", (nsig + Int32(1)) * Int32(_EDF_HEADER_UNIT))
        cprintf(" Data block size: %g second%s (%ld frame%s or %ld bytes)\n",
                seconds_per_block, seconds_per_block == 1.0 ? "" : "s",
                frames_per_block, frames_per_block == 1 ? "" : "s", bytes_per_block)
        es = String(lstrip(==(' '), timstr(strtim("e"))))
        cprintf(" Recording length: %s (%ld data blocks, %ld frames, %ld bytes)\n",
                es, nblocks, nblocks * frames_per_block, nblocks * bytes_per_block)
        cprintf(" Total length of file to be written: %ld bytes\n",
                Int64((nsig + Int32(1)) * Int32(_EDF_HEADER_UNIT)) + nblocks * bytes_per_block)
        blocks_per_minute = d2l(60.0 / seconds_per_block)
        blocks_per_hour = blocks_per_minute * 60
    end

    # Write the data blocks.
    for n in Int64(1):nblocks
        ns > 0 && (blockp[1] = 0)
        for j in 2:ns
            blockp[j] = blockp[j-1] + (_EDF_SAMPLE_BYTES * frames_per_block) * si[j-1].spf
        end
        for _ in 1:frames_per_block
            if nsig != getframe(v)
                # end of input: pad last block with invalid samples
                fill!(v, WFDB_INVALID_SAMPLE)
            end
            vp = 0
            for j in 1:ns
                for _ in 1:si[j].spf
                    vp += 1
                    x = v[vp]
                    b = blockp[j]
                    b < length(block) && (block[b+1] = x % UInt8)
                    b + 1 < length(block) && (block[b+2] = (x >> 8) % UInt8)
                    blockp[j] += _EDF_SAMPLE_BYTES
                end
            end
        end
        fwrite(ofile, block)
        if vflag
            if blocks_per_minute != 0 && n % blocks_per_minute == 0
                cprintf(".")
                cflush()
            end
            blocks_per_hour != 0 && n % blocks_per_hour == 0 && cprintf("\n")
        end
    end
    fclose(ofile)
    cprintf("\n")

    if edfplusflag
        ceprintf("\nWARNING (%s): EDF+ requires the subject's gender, birthdate, and name, as\n well as additional information about the recording that is not usually\n available.  This information is not saved in the output file even if\n available.  EDF+ also requires the use of standard names for signals and\n for physical units;  these requirements are not enforced by this program.\n To make the output file fully EDF+ compliant, its header must be edited\n manually.\n",
                 pname)
        if !any(s -> s.desc == b"EDF-Annotations", si)
            ceprintf("\nWARNING:  The output file does not include EDF annotations, which are\n required for EDF+.\n")
        end
    end

    wfdbquit()
    cexit(0)
end

register_workload("mit2edf") do
    files = Dict{String,Any}("noadc.hea" => "noadc 2 100 300 10:00:00 1/13/2000\n" *
                                           "fmt16.dat 16 200 0 0 0 0 0 a\nfmt16.dat 16 200 0 0 0 0 0 b\n")
    with_workload_data(; files=files) do dir
        for r in ("fmt16", "fmt212", "fmt24", "skew", "fmt16.edf", "edfp.edf", "flac16", "mfreq",
                  "100s", "noadc")
            workload_tool("mit2edf", "-r", r)
        end
        workload_tool("mit2edf", "-r", "100s", "-v")
        workload_tool("mit2edf", "-r", "fmt16", "-o", "out.edf", "-v")
        workload_tool("mit2edf", "-r", "fmt16", "-o", "out.edf", "-p")
        workload_tool("mit2edf", "-r", "fmt16", "-o", "out.EDF", "-p", "-v")
        workload_tool("mit2edf", "-r", "fmt16", "-o", "out.dat", "-p")
        workload_tool("mit2edf", "-r", "nosuch")
        workload_tool("mit2edf", "-h")
        workload_tool("mit2edf", "-r", "fmt16", "-o")
        workload_tool("mit2edf", "-r")
        workload_tool("mit2edf")
    end
    with_workload_data(files=NODEFAULTS_FILES) do dir
        workload_tool("mit2edf", "-r", "nf")
        workload_tool("mit2edf", "-r", "uc")
        workload_tool("mit2edf", "-r", "nr")
        for rec in ("nf", "uc", "nr")       # wfdb-x: legacy mode (original behavior)
            workload_tool("mit2edf", "--legacy", "-r", rec)
        end
    end
end
