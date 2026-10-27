# wav2mit: convert a .wav format file to WFDB format.
#
# Most .wav files are already written in a WFDB-compatible format. This
# program simply creates a .hea (WFDB header) file that describes the .wav
# file; other WFDB applications can then read the .wav file directly. To
# perform the reverse conversion, use mit2wav. (See the C source for a
# description of the .wav format.)
#
# Where the C program has undefined behavior (without -r, the record name it
# generates contains one uninitialized byte; a format chunk with no signals
# divides by zero), the input file name without `.wav` is used as the record
# name, and 0 as the number of samples (see docs/KNOWN_C_BEHAVIORS.md).
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of convert/wav2mit.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in gain or units: the new options -G GAIN
# (required) and -U UNITS (required unless the gain is 0) give them (the
# original wrote 12.5 adu/mV for 8-bit and 6400 adu/mV for 16-bit files, in
# millivolts); --legacy, as the first argument, restores the original behavior.
# Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the
# reasons.
#
# Original C program: convert/wav2mit.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2003-2004 George B. Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

"Length of the header of a .wav file (RIFF, format and data chunk headers)."
const _WAV_HEADER_BYTES = 44
"Length of a PCM format chunk."
const _WAV_FMT_CHUNK_LEN = 16
"Format tag of PCM data."
const _WAV_FORMAT_PCM = 1
"Bytes added to the RIFF chunk length to give the file length."
const _WAV_RIFF_EXTRA = 8
# wfdb-x: the gains (adu/mV) that the C program gave to 8-bit and 16-bit
# .wav samples (legacy mode).
const _WAV2MIT_LEGACY_GAIN8 = 12.5
const _WAV2MIT_LEGACY_GAIN16 = 6400.0
"ADC zero of 8-bit (offset binary) .wav samples."
const _WAV2MIT_ZERO8 = Int32(128)

const _WAV2MIT_HELP = (
    "usage: %s -i FILE.wav -r RECORD [ OPTIONS ... ]\n",
    "where FILE.wav is the name of the wav-format input signal file,",
    "and OPTIONS may include:",
    " -G GAIN    gain in adu per physical unit (required; 0: uncalibrated)",
    " -h         print this usage summary",
    " -r RECORD  create RECORD.hea (default: FILE.hea)",
    " -U UNITS   physical units (required unless the gain is 0)")
# wfdb-x: the help text of the original program, printed in legacy mode
const _WAV2MIT_LEGACY_HELP = _help_without(_WAV2MIT_HELP, [4, 7])

# Does the C string s end with ".wav" (and have at least 5 characters)?
_wav_name_ok(s::AbstractVector{UInt8}) = length(s) >= 5 && view(s, length(s)-3:length(s)) == b".wav"

# Read a 16-bit little-endian integer (EOF at the end of the file).
function _wav2mit_in16(f::WfdbFile)
    a = getc(f)
    a == EOF && return Int16(EOF)
    b = getc(f)
    b == EOF && return Int16(EOF)
    ((a & 0xff) | ((b << 8) & 0xff00)) % Int16
end

# Read a 32-bit little-endian integer (EOF at the end of the file).
function _wav2mit_in32(f::WfdbFile)
    r = Int64(0)
    for k in 0:3
        c = getc(f)
        c == EOF && return Int64(EOF)
        r |= Int64(c & 0xff) << (8k)
    end
    r
end

# Read 4 bytes and compare them with tag.
function _wav2mit_tag(f::WfdbFile, tag)
    buf = zeros(UInt8, 4)
    fread!(f, buf, 1, 4) == 4 && buf == tag
end

function wav2mit_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "wav2mit"
    ifname = nothing
    record = nothing
    uunits = nothing                # wfdb-x: -U
    ggain = Ref{Float64}(0.0)       # wfdb-x: -G
    gset = false

    # Interpret the command line.
    i = 1
    while i < argc
        a = argv[i]
        if !isempty(a) && a[1] == UInt8('-')
            c = length(a) >= 2 ? a[2] : 0x00
            if c == UInt8('G') && !legacy   # gain in adu per physical unit (wfdb-x)
                i += 1
                if i >= argc || csscanf(argv[i], "%lf", ggain) != 1 || ggain[] < 0.0
                    ceprintf("%s: gain (>= 0) must follow -G\n", pname)
                    cexit(1)
                end
                gset = true
            elseif c == UInt8('h')      # help requested
                _convert_help(pname, legacy ? _WAV2MIT_LEGACY_HELP : _WAV2MIT_HELP)
                cexit(1)
            elseif c == UInt8('i')      # input file name follows
                i += 1
                if i >= argc
                    ceprintf("%s: name of wav-format input file must follow -i\n", pname)
                    cexit(1)
                end
                ifname = cstr(argv[i])
                if !_wav_name_ok(ifname)
                    ceprintf("%s: name of input file must end in '.wav'\n", pname)
                    cexit(1)
                end
            elseif c == UInt8('r')
                i += 1
                if i >= argc
                    ceprintf("%s: record name must follow -r\n", pname)
                    cexit(1)
                end
                record = cstr(argv[i])
            elseif c == UInt8('U') && !legacy   # physical units (wfdb-x)
                i += 1
                if i >= argc
                    ceprintf("%s: units must follow -U\n", pname)
                    cexit(1)
                end
                uunits = cstr(argv[i])
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

    # Check that required arguments are present and valid.
    if ifname === nothing
        _convert_help(pname, legacy ? _WAV2MIT_LEGACY_HELP : _WAV2MIT_HELP)
        cexit(1)
    end
    # wfdb-x: the gain and units must be given explicitly; the C program
    # wrote 12.5 adu/mV for 8-bit and 6400 adu/mV for 16-bit files, with no
    # units (millivolts). (The sampling frequency and the resolution are
    # those given in the file.) Legacy mode: as in the C program.
    if !gset && !legacy
        ceprintf("%s: the gain must be specified (-G)\n", pname)
        cexit(1)
    end
    if ggain[] != 0.0 && uunits === nothing && !legacy
        ceprintf("%s: the units must be specified (-U)\n", pname)
        cexit(1)
    end

    # If the record name was not specified, generate it from ifname.
    record === nothing && (record = ifname[1:end-4])

    # Open the input file.
    ifile = cfopen(ifname, "rb")
    if ifile === nothing
        ceprintf("%s: can't open %s\n", pname, ifname)
        cexit(2)
    end

    # Determine the size of the input file.
    fseek(ifile, 0, SEEK_END)
    flen = ftell(ifile)
    fseek(ifile, 0, SEEK_SET)

    # Read and check the header chunk.
    if !_wav2mit_tag(ifile, b"RIFF")
        ceprintf("%s: %s is not a .wav-format file\n", pname, ifname)
        cexit(3)
    end
    len = _wav2mit_in32(ifile) + _WAV_RIFF_EXTRA
    if len != flen
        ceprintf("%s: header chunk of %s has incorrect length (%ld, should be %ld)\n",
                 pname, ifname, len, flen)
        cexit(3)
    end
    if !_wav2mit_tag(ifile, b"WAVE")
        ceprintf("%s: %s is not a .wav-format file\n", pname, ifname)
        cexit(3)
    end

    # Read and check the format chunk.
    if !_wav2mit_tag(ifile, b"fmt ")
        ceprintf("%s: format chunk missing or corrupt in %s\n", pname, ifname)
        cexit(3)
    end
    len = _wav2mit_in32(ifile)
    tag = Int32(_wav2mit_in16(ifile))
    if len != _WAV_FMT_CHUNK_LEN || tag != _WAV_FORMAT_PCM
        ceprintf("%s: unsupported format %d in %s\n", pname, tag, ifname)
        cexit(3)
    end
    nsig = Int32(_wav2mit_in16(ifile))
    sps = Float64(_wav2mit_in32(ifile))
    _wav2mit_in32(ifile)            # bytes per second
    framelen = Int32(_wav2mit_in16(ifile))
    bitspersample = Int32(_wav2mit_in16(ifile))
    if bitspersample <= 8
        wres = Int32(8)
        legacy && (ggain[] = _WAV2MIT_LEGACY_GAIN8)     # wfdb-x: the C program's gain
    elseif bitspersample <= 16
        wres = Int32(16)
        legacy && (ggain[] = _WAV2MIT_LEGACY_GAIN16)    # wfdb-x: the C program's gain
    else
        ceprintf("%s: unsupported resolution (%d bits/sample) in %s\n", pname, bitspersample, ifname)
        cexit(3)
    end
    if framelen != (nsig * wres) ÷ Int32(8)
        ceprintf("%s: format chunk of %s has incorrect frame length\n", pname, ifname)
        cexit(3)
    end

    # Read and check the beginning of the data chunk.
    if !_wav2mit_tag(ifile, b"data")
        ceprintf("%s: data chunk missing or corrupt in %s\n", pname, ifname)
        cexit(3)
    end
    len = _wav2mit_in32(ifile)
    wnsamp = framelen != 0 ? len ÷ framelen : Int64(0)

    if nsig < 0                     # (malloc fails in the C version)
        ceprintf("%s: insufficient memory\n", pname)
        cexit(2)
    end
    s = [Siginfo() for _ in 1:nsig]
    for i in 1:nsig
        si = s[i]
        si.fname = ifname
        si.units = uunits === nothing ? nothing : copy(uunits)
        si.gain = ggain[]
        si.initval = 0
        si.group = 0
        si.fmt = wres == 16 ? 16 : 80
        si.spf = 1
        si.bsize = 0
        si.adcres = wres
        si.adczero = wres == 16 ? Int32(0) : _WAV2MIT_ZERO8
        si.baseline = si.adczero
        si.nsamp = wnsamp
        si.cksum = 0
        wfdbsetstart(i - 1, _WAV_HEADER_BYTES)
    end
    setsampfreq(sps)

    if setheader(record, s, nsig) != 0
        fclose(ifile)
        cexit(4)
    end

    # Clean up.
    wfdbquit()
    fclose(ifile)
    cexit(0)
end

register_workload("wav2mit") do
    with_workload_data(; files=Dict{String,Any}("fake.wav" => "RIFF1234WAVE")) do dir
        workload_tool("wav2mit", "-i", "t16.wav", "-r", "w16", "-G", "6400", "-U", "mV")
        workload_tool("wav2mit", "-i", "t8.wav", "-G", "0")
        workload_tool("wav2mit", "-i", "t16.wav", "-r", "w16")
        workload_tool("wav2mit", "-i", "t16.wav", "-r", "w16", "-G", "6400")
        workload_tool("wav2mit", "-i", "t16.wav", "-r", "w16", "-G", "-1")
        workload_tool("wav2mit", "-i", "100s.dat", "-r", "w8")
        workload_tool("wav2mit", "-i", "nosuch.wav", "-r", "w8", "-G", "0")
        workload_tool("wav2mit", "-i", "fake.wav", "-r", "w8", "-G", "0")
        workload_tool("wav2mit", "-h")
        # wfdb-x: legacy mode (original behavior)
        workload_tool("wav2mit", "--legacy", "-i", "t16.wav", "-r", "w16")
        workload_tool("wav2mit", "--legacy", "-i", "t8.wav")
        workload_tool("wav2mit", "--legacy", "-i", "t8.wav", "-G", "1")
        workload_tool("wav2mit", "--legacy", "-h")
        workload_tool("wav2mit", "-i", "t16.wav", "-x")
        workload_tool("wav2mit", "x")
        workload_tool("wav2mit")
    end
end
