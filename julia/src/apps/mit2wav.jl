# mit2wav: convert WFDB format signal files to .wav format (port of
# convert/mit2wav.c).
#
# The output file has exactly three chunks (a header chunk, a format chunk,
# and a data chunk); see the C source for a description. The C program
# writes the header and format chunks to a temporary file, and prepends it
# to the signal file written by putvec using the mv, cat, and rm commands;
# this port prepends them directly, with the same result. Where the C
# program has undefined behavior (signals with more than 16 bits of ADC
# resolution, for which it shifts by a negative amount), samples are shifted
# to the right and the gain multiplier is 0.
#
# Copyright (C) 2003-2010 George B. Moody (original C program,
# convert/mit2wav.c; revised 2018 by Benjamin Moody).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
# 12 bits and millivolts), because a silently assumed value corrupts every
# result derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).

"Resolution of the samples of the .wav files written by mit2wav (bits)."
const _MIT2WAV_RES = Int32(16)
"Bytes per sample of the .wav files written by mit2wav."
const _MIT2WAV_SAMPLE_BYTES = Int32(2)
"Bytes of the RIFF chunk that follow its length, besides the samples."
const _MIT2WAV_RIFF_EXTRA = 36

const _MIT2WAV_HELP = (
    "usage: %s -o FILE.wav -r RECORD [ OPTIONS ... ]\n",
    "where FILE.wav is the name of the wav-format output signal file,",
    "RECORD is the record name, and OPTIONS may include:",
    " -h         print this usage summary",
    " -n NEWREC  create a header file for the output signal file, so it",
    "             may be read as record NEWREC")

# Append x in little-endian byte order (16 or 32 bits) to b.
_mit2wav_out16(b::Vector{UInt8}, x::Integer) = (push!(b, x % UInt8, (x >> 8) % UInt8); b)
_mit2wav_out32(b::Vector{UInt8}, x::Integer) =
    (push!(b, x % UInt8, (x >> 8) % UInt8, (x >> 16) % UInt8, (x >> 24) % UInt8); b)

function mit2wav_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "mit2wav"
    nrec = nothing
    ofname = nothing
    record = nothing
    bitspersample = Int32(0)

    # Interpret the command line.
    i = 1
    while i < argc
        a = argv[i]
        if !isempty(a) && a[1] == UInt8('-')
            c = length(a) >= 2 ? a[2] : 0x00
            if c == UInt8('h')          # help requested
                _convert_help(pname, _MIT2WAV_HELP)
                cexit(1)
            elseif c == UInt8('n')      # new record name follows
                i += 1
                if i >= argc
                    ceprintf("%s: new record name must follow -n\n", pname)
                    cexit(1)
                end
                nrec = cstr(argv[i])
            elseif c == UInt8('o')      # output file name follows
                i += 1
                if i >= argc
                    ceprintf("%s: name of wav-format output file must follow -o\n", pname)
                    cexit(1)
                end
                ofname = cstr(argv[i])
                if !_wav_name_ok(ofname)
                    ceprintf("%s: name of output file must end in '.wav'\n", pname)
                    cexit(1)
                end
            elseif c == UInt8('r')
                i += 1
                if i >= argc
                    ceprintf("%s: record name must follow -r\n", pname)
                    cexit(1)
                end
                record = cstr(argv[i])
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
    if ofname === nothing || record === nothing
        _convert_help(pname, _MIT2WAV_HELP)
        cexit(1)
    end
    if nrec !== nothing && nrec == record
        ceprintf("%s: names of input and output records must not be identical\n", pname)
        cexit(1)
    end

    # Open the input record and allocate memory for per-signal objects.
    nsig = isigopen(record, nothing, 0)
    nsig <= 0 && cexit(2)
    s = [Siginfo() for _ in 1:nsig]
    nsig = isigopen(record, s, nsig)
    nsig <= 0 && cexit(3)
    # wfdb-x: no default frequency (except in legacy mode)
    if !legacy && sampfreq(nothing) <= 0.0
        ceprintf("%s: sampling frequency of record %s is not specified\n", pname, record)
        cexit(3)
    end
    n = Int(nsig)
    offset = zeros(Int32, n)
    shift = zeros(Int32, n)
    x = zeros(Int32, n)
    y = zeros(Int32, n)

    # Check that the new record name is legal before proceeding. Note that
    # this step creates a header file, which is overwritten after the
    # processing is completed.
    nrec !== nothing && newheader(nrec) < 0 && cexit(3)

    # Set the output signal parameters.
    for i in 1:n
        si = s[i]
        si.adcres > bitspersample && (bitspersample = si.adcres)
        offset[i] = si.adczero
        si.adczero = 0
        shift[i] = _MIT2WAV_RES - si.adcres
        si.adcres = _MIT2WAV_RES
        mag = shift[i] >= 0 ? (Int32(1) << shift[i]) : Int32(0)
        si.gain *= mag
        si.baseline -= offset[i]
        si.baseline *= mag
        si.fname = ofname
        si.group = 0
        si.fmt = 16
        si.spf = 1
    end

    # Get information needed for the header and format chunks.
    nsamp = strtim("e")
    sps = Float64(strtim("1"))
    framelen = nsig * _MIT2WAV_SAMPLE_BYTES

    # Give up if the output cannot be written.
    osigfopen(s, nsig) < nsig && cexit(4)

    for i in 0:nsig-1
        wfdbsetstart(i, _WAV_HEADER_BYTES)
    end

    # Make the header and format chunks, and the first 8 bytes of the data
    # chunk (written to a temporary file in the C version).
    hdr = Vector{UInt8}(b"RIFF")
    # nsamp*framelen sample bytes, and 36 more bytes of embedded header
    _mit2wav_out32(hdr, nsamp * framelen + _MIT2WAV_RIFF_EXTRA)
    append!(hdr, b"WAVEfmt ")
    _mit2wav_out32(hdr, _WAV_FMT_CHUNK_LEN)      # number of bytes to follow in format chunk
    _mit2wav_out16(hdr, _WAV_FORMAT_PCM)         # format tag
    _mit2wav_out16(hdr, nsig)
    _mit2wav_out32(hdr, d2l(sps))
    _mit2wav_out32(hdr, d2l(sps * framelen))
    _mit2wav_out16(hdr, framelen)
    _mit2wav_out16(hdr, bitspersample)
    append!(hdr, b"data")
    _mit2wav_out32(hdr, nsamp * framelen)

    # Copy the input to the output. Reformatting is handled by putvec().
    while getvec(x) == nsig
        for i in 1:n
            d = x[i] - offset[i]
            y[i] = shift[i] >= 0 ? d << shift[i] : d >> -shift[i]
        end
        putvec(y) != nsig && break
    end

    # Write the new header file if requested.
    setsampfreq(sampfreq(nothing))
    nrec !== nothing && newheader(nrec)

    # Clean up.
    wfdbquit()

    # Prepend the header and format chunks to the new signal file.
    data = UInt8[]
    f = cfopen(ofname, "rb")
    if f !== nothing
        data = read_to_end(f)
        fclose(f)
    end
    f = cfopen(ofname, "wb")
    if f !== nothing
        fwrite(f, hdr)
        fwrite(f, data)
        fclose(f)
    end
    cexit(0)
end

register_workload("mit2wav") do
    with_workload_data() do dir
        for r in ("100s", "fmt16", "fmt80", "mfreq", "fmt8", "fmt24")
            workload_tool("mit2wav", "-r", r, "-o", "out.wav", "-n", "outw")
        end
        workload_tool("mit2wav", "-r", "100s", "-o", "out.wav")
        workload_tool("mit2wav", "-r", "100s", "-o", "out.wav", "-n", "100s")
        workload_tool("mit2wav", "-r", "100s", "-o", "out.dat")
        workload_tool("mit2wav", "-r", "nosuch", "-o", "out.wav")
        workload_tool("mit2wav", "-r", "100s", "-o", "out.wav", "-n", "bad*name")
        workload_tool("mit2wav", "-h")
        workload_tool("mit2wav", "-x")
        workload_tool("mit2wav", "x")
    end
    with_workload_data(files=NODEFAULTS_FILES) do dir
        workload_tool("mit2wav", "-r", "nf", "-o", "x.wav")
        workload_tool("mit2wav", "--legacy", "-r", "nf", "-o", "x.wav")
    end
end
