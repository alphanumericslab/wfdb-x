# xform: sampling frequency, amplitude, and format conversion for WFDB
# records.
#
# Dither uses an exact emulation of glibc's `rand()` (after `srand(0)`), so
# that the output is the same on all platforms. Conversions of out-of-range
# doubles to int give `INT_MIN` (as on x86), and int additions and
# subtractions wrap around.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of app/xform.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency, gain, ADC
# resolution or units: the input record must give its sampling frequency, and
# an output frequency of 0 is refused; rescaling an uncalibrated signal to a
# given gain, and rescaling by ADC resolution when a resolution is unspecified,
# are refused; an ADC resolution is offered only if it comes from the input (or
# the previous output signal) and suits the output format; unspecified units
# are shown as "nd" (the original assumed 250 Hz, 200 adu/mV, a resolution
# based on the format, and millivolts); when an output signal file would be one
# of the input files, the message says so; --legacy, as the first argument,
# restores the original behavior. Each change is marked "WFDB-x:" in the code;
# docs/DIVERGENCES.md gives the reasons.
#
# Original C program: app/xform.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1983-2010 George B. Moody; revised 2017-2020 by
#   Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

const _XFORM_HELP = (
    "usage: %s -i IREC [OPTIONS ...]\n",
    "where IREC is the name of the record to be converted, and OPTIONS may",
    " include any of:",
    " -a ANNOTATOR [ANNOTATOR ...]  copy annotations for the specified ANNOTATOR",
    "              from IREC;  two or more ANNOTATORs may follow -a",
    " -c          clip output (default: wrap around if out-of-range)",
    " -d          add dither to the input if changing sampling frequency or gain",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          open the input record in `high resolution' mode",
    " -M          process multifrequency record without changing frequencies",
    " -n NREC     create a header file, using record name NREC and signal",
    "              descriptions from IREC",
    " -N NREC     as for -n, but copy signal descriptions from OREC",
    " -o OREC     produce output signal file(s) as specified by the header file",
    "              for record OREC",
    " -s SIGNAL [SIGNAL ...]  write only the specified signal(s)",
    " -S SCRIPT   take answers to prompts from SCRIPT (a text file)",
    " -t TIME     stop at specified time",
    " -u          adjust annotation times if needed to make them unique",
    "Unless you use `-o' to specify an *existing* header that describes the",
    "desired signal files, you will be asked for output specifications.  Use",
    "`-n' to name the record to be created.  Use `-s' to select a subset of the",
    "input signals, or to re-order them in the output file;  arguments that",
    "follow `-s' are *input* signal numbers (0,1,2,...) or names.")

const _XFORM_FORMATS_HELP = (
    "    8   8-bit first differences",
    "   16   16-bit two's complement amplitudes (LSB first)",
    "   61   16-bit two's complement amplitudes (MSB first)",
    "   80   8-bit offset binary amplitudes",
    "  160   16-bit offset binary amplitudes",
    "  212   2 12-bit amplitudes bit-packed in 3 bytes",
    "  310   3 10-bit amplitudes bit-packed in 15 LS bits of each of 2 words",
    "  311   3 10-bit amplitudes bit-packed in 30 LS bits of 4 bytes",
    "   24   24-bit two's complement amplitudes (LSB first)",
    "   32   32-bit two's complement amplitudes (LSB first)",
    "  508  8-bit amplitudes with FLAC compression",
    "  516  16-bit amplitudes with FLAC compression",
    "  524  24-bit amplitudes with FLAC compression")

"Size of the C program's buffer for short answers to prompts."
const _XFORM_ANSWER_LEN = 32
"Size of the C program's `btstring` (with its terminating NUL)."
const _XFORM_BTSTRING_LEN = 30
"Initial value of the previous annotation's `chan` (below any `chan`)."
const _XFORM_NO_CHAN = Int32(-129)

"`%s` of a missing units string (WFDB-x: \"nd\"; the C program showed \"mV\")."
const _XFORM_DEFAULT_UNITS = "nd"
const _XFORM_LEGACY_UNITS = "mV"    # WFDB-x: legacy mode (original behavior)

function _xform_help(pname)
    ceprintf(_XFORM_HELP[1], pname)
    for i in 2:length(_XFORM_HELP)
        ceprintf("%s\n", _XFORM_HELP[i])
    end
end

# The dither generator: triangular PDF in (-1,1).
@inline function _xform_dither(rng::GlibcRand)
    a = Float64(glibc_rand!(rng))
    b = Float64(glibc_rand!(rng))
    (a + b) / RAND_MAX - 1.0
end

# The input of the answers to the prompts.
struct _XformPrompt
    ttyin::WfdbFile
    pname::String
    script::Union{Nothing,Vector{UInt8}}    # its name (nothing: the terminal)
end

# C `fgets` on the prompt input, with xform's handling of end of file.
function _xform_sfgets(p::_XformPrompt, length::Integer)
    buffer = UInt8[]
    if !fgets!(p.ttyin, buffer, length)
        if p.script !== nothing
            ceprintf("\n%s: unexpected end of file in %s\n", p.pname, p.script)
            cexit(1)
        end
        push!(buffer, UInt8('\n'))
    end
    # (The C program treats the buffer as a C string.)
    k = findfirst(iszero, buffer)
    k === nothing || resize!(buffer, k - 1)
    buffer
end

# Calculate the greatest common divisor of x and y.  This function uses
# Euclid's algorithm, modified so that an exact answer is not required if
# the (possibly non-integral) arguments do not have a common divisor that
# can be represented exactly.
function _xform_gcd(x::Float64, y::Float64)
    tol = x > y ? 0.001 * y : 0.001 * x
    while true
        if x > y && x - y > tol
            x -= y
        elseif y > x && y - x > tol
            y -= x
        else
            return x
        end
    end
end

# Round as xform does.
@inline _xform_round(vd::Float64) = vd >= 0 ? d2i(vd + 0.5) : d2i(vd - 0.5)

# Report (and clip, or widen the range for) an out-of-range sample of
# signal i (1-based); returns the sample to write.
@inline function _xform_check!(vo::Int32, i::Int, vmax::Vector{Int32}, vmin::Vector{Int32},
                               clip::Bool)
    if vo > vmax[i]
        ceprintf("v[%d] = %d (out of range)\n", Int32(i - 1), vo)
        clip ? (vo = vmax[i]) : (vmax[i] = vo)
    elseif vo < vmin[i]
        ceprintf("v[%d] = %d (out of range)\n", Int32(i - 1), vo)
        clip ? (vo = vmin[i]) : (vmin[i] = vo)
    end
    vo
end

# Progress indicator: a dot per minute of input, a newline per hour.
mutable struct _XformProgress
    nsm::Int64          # samples since the last dot
    spm::Int64          # samples per minute
    nminutes::Int32     # dots on the current line
end

"Minutes (dots) per line of the progress indicator."
const _XFORM_DOTS_PER_LINE = 60

@inline function _xform_tick!(p::_XformProgress)
    p.nsm += 1
    if p.nsm >= p.spm
        p.nsm = 0
        ceprintf(".")
        p.nminutes += Int32(1)
        if p.nminutes >= _XFORM_DOTS_PER_LINE
            p.nminutes = 0
            ceprintf("\n")
        end
    end
end

# C `nsamp == -1L || nsamp-- > 0L` (nsamp == -1: no limit).
@inline function _xform_more!(nsamp::Base.RefValue{Int64})
    nsamp[] == -1 && return true
    r = nsamp[] > 0
    nsamp[] -= 1
    r
end

# The largest ADC resolution offered for a storage format (xform offers a
# resolution only within 8 and this; WFDB-x: the C program otherwise offered
# one based on the format, 12 bits for 16-bit formats).
function _xform_maxres(fmt::Integer)
    (fmt == 80 || fmt == 508) ? Int32(8) :
    fmt == 212 ? Int32(12) :
    fmt == 310 ? Int32(10) :
    (fmt == 24 || fmt == 524) ? Int32(24) :
    fmt == 32 ? Int32(32) : Int32(16)
end

# A default ADC resolution for a storage format, as the C program (and
# legacy mode) chooses one: adcres if it suits the format, otherwise one
# based on the format (WFDB_DEFRES for 16-bit formats).
function _xform_legacy_adcres(fmt::Integer, adcres::Int32)
    if fmt == 80 || fmt == 508
        Int32(8)
    elseif fmt == 212
        (adcres < 8 || adcres > 12) ? Int32(12) : adcres
    elseif fmt == 310
        (adcres < 8 || adcres > 10) ? Int32(10) : adcres
    elseif fmt == 24 || fmt == 524
        (adcres < 8 || adcres > 24) ? Int32(24) : adcres
    elseif fmt == 32
        (adcres < 8 || adcres > 32) ? Int32(32) : adcres
    else            # 16, 61, 160, 516, and others
        (adcres < 8 || adcres > 16) ? WFDB_DEFRES : adcres
    end
end

# C `1L << n` on x86-64 (the shift count is taken modulo 64).
@inline _xform_shl1(n::Integer) = Int64(1) << (n & 63)

function xform_main(args::Vector{String})
    # WFDB-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "xform"
    script = nothing
    rng = GlibcRand(1)
    irec = orec = nrec = nothing
    startp = Vector{UInt8}(b"0:0")
    ofreq = 0.0
    clip = dflag = hflag = mflag = sflag = uflag = false
    use_irec_desc = true
    fflag = gflag = reopen = false
    nosig = Int32(0)
    siglist = Int32[]
    from = it = ot = to = Int64(0)
    nsamp = Ref(Int64(-1))
    ainames = Vector{UInt8}[]
    dfin = Siginfo[]
    dfout = Siginfo[]

    # Interpret the command-line arguments.
    i = 1
    while i < argc
        a = argv[i]
        if get(a, 1, 0x00) == UInt8('-')
            c = get(a, 2, 0x00)
            if c == UInt8('a')          # annotator(s)
                # Count the number of annotators.  Accept the next argument
                # unconditionally as an annotator name; accept additional
                # arguments until we find one beginning with `-', or the end
                # of the argument list.
                j = 0
                while (i += 1) < argc && (j == 0 || get(argv[i], 1, 0x00) != UInt8('-'))
                    j += 1
                end
                if j == 0
                    ceprintf("%s: annotator(s) must follow -a\n", pname)
                    cexit(1)
                end
                i -= j
                j = 0
                while i < argc && (j == 0 || get(argv[i], 1, 0x00) != UInt8('-'))
                    push!(ainames, argv[i])
                    i += 1
                    j += 1
                end
                i -= 1
            elseif c == UInt8('c')      # clip (limit) output (default: discard high bits)
                clip = true
            elseif c == UInt8('d')
                dflag = true
                glibc_srand!(rng, 0)    # seed for dither RNG
            elseif c == UInt8('f')      # starting time
                i += 1
                if i >= argc
                    ceprintf("%s: time must follow -f\n", pname)
                    cexit(1)
                end
                from = i
            elseif c == UInt8('h')      # help requested
                _xform_help(pname)
                cexit(0)
            elseif c == UInt8('H')      # open the input record in `high resolution' mode
                hflag = true
            elseif c == UInt8('i')      # input record name follows
                i += 1
                if i >= argc
                    ceprintf("%s: input record name must follow -i\n", pname)
                    cexit(1)
                end
                irec = argv[i]
            elseif c == UInt8('M')      # multifrequency mode (no frequency changes)
                mflag = true
            elseif c == UInt8('n')      # new record name follows
                i += 1
                if i >= argc
                    ceprintf("%s: new record name must follow -n\n", pname)
                    cexit(1)
                end
                nrec = argv[i]
            elseif c == UInt8('N')      # new record name follows;  use signal descriptions
                                        # from output record header file in new header file
                use_irec_desc = false
                i += 1
                if i >= argc
                    ceprintf("%s: new record name must follow -N\n", pname)
                    cexit(1)
                end
                nrec = argv[i]
            elseif c == UInt8('o')      # output record name follows
                i += 1
                if i >= argc
                    ceprintf("%s: output record name must follow -o\n", pname)
                    cexit(1)
                end
                orec = argv[i]
            elseif c == UInt8('s')      # signal list follows
                sflag = true
                # count the number of output signals
                j = 0
                while (i += 1) < argc && get(argv[i], 1, 0x00) != UInt8('-')
                    j += 1
                end
                if j == 0
                    ceprintf("%s: signal list must follow -s\n", pname)
                    cexit(1)
                end
                # fill the signal list (with argument indices for now)
                i -= j
                while i < argc && get(argv[i], 1, 0x00) != UInt8('-')
                    push!(siglist, Int32(i))
                    nosig += Int32(1)
                    i += 1
                end
                i -= 1
            elseif c == UInt8('S')      # script name follows
                i += 1
                if i >= argc
                    ceprintf("%s: script name must follow -S\n", pname)
                    cexit(1)
                end
                script = argv[i]
            elseif c == UInt8('t')      # end time
                i += 1
                if i >= argc
                    ceprintf("%s: time must follow -t\n", pname)
                    cexit(1)
                end
                to = i
            elseif c == UInt8('u')      # make annotation times unique
                uflag = true
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

    # Check that an input record was specified.
    if irec === nothing
        _xform_help(pname)
        cexit(1)
    end

    # Check that nrec and orec differ if both were specified.
    if nrec !== nothing && orec !== nothing && cstr(nrec) == cstr(orec)
        ceprintf("%s: arguments of -n (or -N) and -o cannot be identical\n", pname)
        cexit(1)
    end

    # Determine the number of input signals.  If isigopen returns a negative
    # value, quit (isigopen will have emitted an error message).
    nisig = isigopen(irec, nothing, 0)
    nisig < 0 && cexit(2)

    # If the input record contains no signals, we won't write any -- but we
    # might still read and write annotations.
    if nisig == 0
        nosig = Int32(0)
    else    # Otherwise, prepare to read and write signals.
        dfin = [Siginfo() for _ in 1:nisig]

        # Open the input signals.
        isigopen(irec, dfin, nisig) != nisig && cexit(2)

        # If a signal list was specified using -s, check that the specified
        # signal numbers or names are legal.
        if sflag
            k = 1
            while k <= nosig
                s = argv[siglist[k]]
                siglist[k] = findsig(s)
                if siglist[k] < 0
                    ceprintf("%s: warning: record %s doesn't have a signal '%s'\n",
                             pname, irec, s)
                    # Delete illegal signal numbers from the list.
                    deleteat!(siglist, k)
                    nosig -= Int32(1)
                else
                    k += 1
                end
            end
            # If the signal list contained no valid signal numbers, treat
            # this situation as if no signal list was specified.
            nosig == 0 && (sflag = false)
        end

        # If the signal list was not specified using -s, initialize it now.
        if !sflag
            nosig = nisig
            siglist = collect(Int32(0):nosig-Int32(1))
        end

        dfout = [Siginfo() for _ in 1:nosig]
    end
    nalloc = Int(max(nosig, 0))
    gain = zeros(Float64, nalloc)
    deltav = zeros(Int32, nalloc)
    msiglist = zeros(Int32, nalloc)
    v = zeros(Int32, nalloc)
    vmax = zeros(Int32, nalloc)
    vmin = zeros(Int32, nalloc)
    vv = zeros(Int32, nalloc)

    # Determine the input sampling frequency.
    if mflag
        setgvmode(WFDB_LOWRES)
    elseif hflag
        setgvmode(WFDB_HIGHRES)
    end
    ifreq = sampfreq(nothing)
    # WFDB-x: no default sampling frequency (the C program assumed 250 Hz if
    # the input header did not specify one, as legacy mode does).
    if ifreq <= 0.0 && !legacy
        ceprintf("%s: sampling frequency of record %s is not specified\n", pname, irec)
        wfdbquit()
        cexit(2)
    end
    spf = getspf()

    if mflag
        iframelen = oframelen = Int32(0)
        for s in dfin
            iframelen += s.spf
        end
        for k in 1:nalloc
            oframelen += dfin[siglist[k]+1].spf
        end
    else
        iframelen, oframelen = nisig, nosig
    end
    vin = zeros(Int32, max(iframelen, 1))
    vout = zeros(Int32, max(oframelen, 1))

    if orec !== nothing         # an output record was specified
        # If a new record name was specified, check that it can be created.
        nrec !== nothing && newheader(nrec) < 0 && cexit(2)

        # Determine the output sampling frequency.
        ofreq = sampfreq(orec)
        if ofreq == 0.0 && !legacy  # WFDB-x: no default sampling frequency
            ceprintf("%s: sampling frequency of record %s is not specified\n", pname, orec)
            wfdbquit()
            cexit(2)
        end
        setsampfreq(ifreq / spf)

        if ifreq != ofreq && mflag
            ceprintf("%s: -M option may not be used if sampling frequency is to be changed\n",
                     pname)
            wfdbquit()
            cexit(1)
        end
    else    # If no output record was specified, get signal specs interactively.
        format = Int32(0)
        ttyin = cfopen(script === nothing ? "/dev/tty" : script, "r")
        prompt = _XformPrompt(ttyin === nothing ? wfdb_stdin() : ttyin, pname, script)
        iref = Ref{Int32}(0)
        dref = Ref{Float64}(0.0)
        if nrec === nothing
            record = UInt8[]
            while true
                ceprintf("Choose a name for the output record (up to %d characters): ",
                         Int32(WFDB_MAXRNL))
                record = _xform_sfgets(prompt, WFDB_MAXRNL + 2)
                isempty(record) || pop!(record)     # (the newline)
                (!isempty(record) && newheader(record) >= 0) && break
            end
            nrec = record
        end
        if !sflag
            while true
                nosig = nisig
                ceprintf("Number of signals to be written (1-%d) [%d]: ", nisig, nosig)
                iref[] = nosig
                csscanf(_xform_sfgets(prompt, _XFORM_ANSWER_LEN), "%d", iref)
                nosig = iref[]
                if nosig == 0
                    ceprintf("No signals will be written.  Are you sure? [n]: ")
                    answer = _xform_sfgets(prompt, _XFORM_ANSWER_LEN)
                    c0 = get(answer, 1, 0x00)
                    (c0 != UInt8('y') && c0 != UInt8('Y')) && (nosig = Int32(-1))
                end
                (nosig < 0 || nosig > nisig) || break
            end
        end
        if mflag
            ofreq = ifreq
            ceprintf("Sampling frequency (%g frames/sec) will be unchanged\n", ofreq)
        else
            while true
                ofreq = ifreq
                ceprintf("Output sampling frequency (Hz per signal, > 0) [%g]: ", ofreq)
                dref[] = ofreq
                csscanf(_xform_sfgets(prompt, _XFORM_ANSWER_LEN), "%lf", dref)
                ofreq = dref[]
                ofreq < 0 || break
            end
        end
        if ofreq == 0 && legacy
            ofreq = WFDB_DEFFREQ    # WFDB-x: as in the C program
        elseif ofreq == 0           # WFDB-x: the C program assumed 250 Hz
            ceprintf("%s: the output sampling frequency must be > 0\n", pname)
            wfdbquit()
            cexit(1)
        end
        if nosig > 0
            ceprintf("Specify the name of the directory in which the output\n")
            ceprintf(" signals should be written, or press <return> to write\n")
            ceprintf(" them in the current directory: ")
            directory = _xform_sfgets(prompt, _XFORM_ANSWER_LEN - 1)
            if get(directory, 1, 0x00) == UInt8('\n')
                empty!(directory)
            elseif !isempty(directory)
                directory[end] = UInt8('/')
            end
            ceprintf("Any of these output formats may be used:\n")
            for s in _XFORM_FORMATS_HELP
                ceprintf("%s\n", s)
            end
            while true
                format = dfin[1].fmt
                ceprintf("Choose an output format from the list above [%d]: ", format)
                iref[] = format
                csscanf(_xform_sfgets(prompt, _XFORM_ANSWER_LEN), "%d", iref)
                format = iref[]
                # (skip WFDB_FMT_LIST[1], which is 0)
                format in @view(WFDB_FMT_LIST[2:WFDB_NFMTS]) && break
            end
            save_answer = UInt8[]
            if nosig > 1
                ceprintf("Save all signals in one file? [y]: ")
                save_answer = _xform_sfgets(prompt, _XFORM_ANSWER_LEN)
            end
            # Use the input signal specifications as defaults for output.
            for k in 1:nosig
                dfout[k] = copy(dfin[siglist[k]+1])
            end
            c0 = get(save_answer, 1, 0x00)
            if nosig <= 1 || (c0 != UInt8('n') && c0 != UInt8('N'))
                filename = cformat("%s%s.dat", directory, nrec)
                for k in 1:nosig
                    dfout[k].fname = filename
                    dfout[k].group = 0
                end
            else
                for k in 1:nosig
                    dfout[k].fname = cformat("%s%s.d%d", directory, nrec, Int32(k - 1))
                    dfout[k].group = k - 1
                end
            end
        end
        for k in 1:max(nosig, 0)
            d = dfout[k]
            # Make sure output signals are written in the chosen format.
            d.fmt = format
            mflag || (d.spf = 1)
            d.bsize = 0     # no block size is defined
            if !use_irec_desc
                ceprintf("Signal %d description (up to %d characters): ", Int32(k - 1),
                         Int32(WFDB_MAXDSL))
                description = _xform_sfgets(prompt, WFDB_MAXDSL + 2)
                isempty(description) || pop!(description)   # (the newline)
                d.desc = description
                ceprintf("Signal %d units (up to %d characters): ", Int32(k - 1),
                         Int32(WFDB_MAXUSL))
                units = _xform_sfgets(prompt, WFDB_MAXUSL + 2)
                for p in eachindex(units)
                    if units[p] == UInt8(' ') || units[p] == UInt8('\t')
                        units[p] = UInt8('_')
                    elseif units[p] == UInt8('\n')
                        resize!(units, p - 1)
                        break
                    end
                end
                d.units = isempty(units) ? nothing : units
            end
            u = d.units
            if u === nothing
                ceprintf(" Signal %d gain (adu/%s) [%g]: ", Int32(k - 1),
                               legacy ? _XFORM_LEGACY_UNITS : _XFORM_DEFAULT_UNITS, d.gain)
            else
                ceprintf(" Signal %d gain (adu/%s) [%g]: ", Int32(k - 1), u, d.gain)
            end
            dref[] = d.gain
            csscanf(_xform_sfgets(prompt, _XFORM_ANSWER_LEN), "%lf", dref)
            d.gain = dref[]
            # WFDB-x: a resolution is offered only if it comes from the input
            # (or the previous output signal) and suits the output format; the
            # C program otherwise offered one based on the format (12 bits for
            # 16-bit formats). Without one, the user must give it. Legacy
            # mode: as in the C program.
            while legacy
                k > 1 && (d.adcres = dfout[k-1].adcres)
                d.adcres = _xform_legacy_adcres(d.fmt, d.adcres)
                ceprintf(" Signal %d ADC resolution in bits (8-32) [%d]: ", Int32(k - 1),
                         d.adcres)
                iref[] = d.adcres
                csscanf(_xform_sfgets(prompt, _XFORM_ANSWER_LEN), "%d", iref)
                d.adcres = iref[]
                (d.adcres < 8 || d.adcres > 32) || break
            end
            while !legacy
                k > 1 && (d.adcres = dfout[k-1].adcres)
                if 8 <= d.adcres <= _xform_maxres(d.fmt)
                    ceprintf(" Signal %d ADC resolution in bits (8-32) [%d]: ", Int32(k - 1),
                             d.adcres)
                else
                    ceprintf(" Signal %d ADC resolution in bits (8-32): ", Int32(k - 1))
                    d.adcres = 0
                end
                iref[] = d.adcres
                csscanf(_xform_sfgets(prompt, _XFORM_ANSWER_LEN), "%d", iref)
                d.adcres = iref[]
                if d.adcres == 0
                    ceprintf("%s: the ADC resolution of signal %d must be specified\n", pname,
                             Int32(k - 1))
                    wfdbquit()
                    cexit(1)
                end
                (d.adcres < 8 || d.adcres > 32) || break
            end
            ceprintf(" Signal %d ADC zero level (adu) [%d]: ", Int32(k - 1), d.adczero)
            iref[] = d.adczero
            csscanf(_xform_sfgets(prompt, _XFORM_ANSWER_LEN), "%d", iref)
            d.adczero = iref[]
        end
    end

    # Check the starting and ending times.
    from != 0 && (startp = argv[from])
    from = strtim(startp)
    from < 0 && (from = -from)
    btstring = Vector{UInt8}(mstimstr(-from))
    # (C: strcpy into a 30-byte buffer)
    length(btstring) >= _XFORM_BTSTRING_LEN && resize!(btstring, _XFORM_BTSTRING_LEN - 1)
    if to != 0
        to = strtim(argv[to])
        to < 0 && (to = -to)
        if to > 0
            nsamp[] = to - from
            if nsamp[] <= 0
                ceprintf("%s: 'to' time must be later than 'from' time\n", pname)
                cexit(1)
            end
        end
    end
    progress = _XformProgress(0, strtim("1:0"), 0)

    if mflag
        # In multifrequency mode, the preceding calculations are performed in
        # low-resolution mode (so that 'from' and 'to' are rounded to the
        # nearest frame number, and 'nsamp' is the number of frames to copy.)
        # For annotation processing, switch to high-resolution mode, convert
        # 'from' and 'to' into high-resolution sample numbers, and set the
        # output annotation resolution accordingly.
        setgvmode(WFDB_HIGHRES)
        spf = getspf()
        from *= spf
        to *= spf
        setafreq(ofreq * spf)
    else
        # For a single-frequency record, the time resolution for output
        # annotations is equal to the output frame frequency (ofreq), so we
        # do not need an explicit time resolution.  If a default time
        # resolution is set by isigopen, remove it.
        setafreq(0.0)
    end

    # Process the annotation file(s), if any.
    nann = length(ainames)
    if nann > 0
        annot = Annotation()
        ai = [Anninfo(n, WFDB_READ) for n in ainames]

        # Check that the input annotation files are readable.
        (annopen(irec, ai, nann) < 0 || iannsettime(from) < -1) && cexit(2)

        # Associate the output annotation files with the new record, if a new
        # record name was specified.  Otherwise, associate them with the
        # existing output record.
        p0 = nrec !== nothing ? nrec : orec

        # Check that the output annotation files are writeable, without
        # closing the input annotation files.
        for x in ai
            x.stat = WFDB_WRITE
        end
        annopen(cformat("+%s", p0), ai, nann) < 0 && cexit(2)

        # Write the annotation files.
        for k in 0:nann-1
            tt = Int64(0)
            cc = _XFORM_NO_CHAN
            while getann(k, annot) == 0 && (to == 0 || annot.time <= to)
                if annot.time == 0 && annot.subtyp == 0 && annot.chan == 0 && annot.num == 0 &&
                   (annot.anntyp == NOTQRS || annot.anntyp == NOTE)
                    continue
                end
                annot.time = d2l((annot.time - from) * ofreq / ifreq)
                # If the -u option was specified, make sure that the
                # corrected annotation time is positive and that it is later
                # than the previous annotation time (exception: if it matches
                # the previous annotation time, but the chan field is greater
                # than that of the previous annotation, no time adjustment is
                # performed).
                if uflag && (annot.time < tt || (annot.time == tt && annot.chan <= cc))
                    tt += 1
                    annot.time = tt
                else
                    tt = annot.time
                end
                cc = Int32(annot.chan)
                putann(k, annot)
            end
        end

        # Close the annotation files.
        for k in nann-1:-1:0
            iannclose(k)
            oannclose(k)
        end
    end

    # Quit if no signals are to be written.
    nosig == 0 && cexit(0)

    # Check that the input signals are readable.
    ceprintf("Checking input signals ...")
    isigsettime(from) < 0 && cexit(2)
    ceprintf(" done\n")

    # If an output record was specified using `-o', check that the output
    # signals are writable.  Suppress warning messages about possible
    # sampling frequency differences.
    wfdbquiet()
    if orec !== nothing && osigopen(orec, dfout, nosig) != nosig
        # WFDB-x: say why if an output file is one of the input files (the
        # library's message, quieted above, is the last error)
        e = wfdberror()
        es = String(copy(e))
        if !legacy && startswith(es, "osigopen: output file ") && length(e) > 22 + 23 &&
           endswith(es, " is also an input file\n")
            ceprintf("%s: can't write output signals (%s)\n", pname, e[1:end-1])
        else
            ceprintf("%s: can't write output signals\n", pname)
        end
        cexit(2)
    end
    wfdbverbose()

    # Make sure that signal file format is not 0 (putvec cannot write to a
    # null record).
    for k in 1:nosig
        if dfout[k].fmt == 0
            ceprintf("%s: signal %d format cannot be 0 (changing to format 16)\n", pname,
                     Int32(k - 1))
            dfout[k].fmt = 16
            reopen = true   # record must be (re)opened using osigfopen to make
                            # the change effective
        end
    end

    # Without -M, the output frames hold one sample of each signal (as for
    # output signals specified interactively), so signals of the -o record
    # with more than one sample per frame are (re)opened with one. (C reads
    # past the end of its output array; see "Undefined behaviors" in
    # docs/KNOWN_C_BEHAVIORS.md.)
    if !mflag
        for k in 1:nosig
            if dfout[k].spf > 1
                dfout[k].spf = 1
                reopen = true
            end
        end
    end

    # If the `-n' option was specified, copy the signal descriptions from the
    # input record header file into the WFDB_Siginfo structures for the
    # output record (for eventual storage in the new output header file).  To
    # make the changes effective, the output signals must be (re)opened using
    # osigfopen.
    if nrec !== nothing && use_irec_desc
        for k in 1:nosig
            dfout[k].desc = dfin[siglist[k]+1].desc
        end
        reopen = true
    end

    # Determine relative gains and offsets of the signals.  If any output
    # gain must be adjusted, the output signals must be reopened (to ensure
    # that the correct gains are written to the output header).
    for k in 1:nosig
        di = dfin[siglist[k]+1]
        d = dfout[k]
        # A signal may be rescaled by xform depending on the gains and ADC
        # resolutions specified.  The rules for doing so are as follows:
        # 1.  If the output gain has not been specified, the signal is scaled
        #     only if the input and output ADC resolutions differ.  In this
        #     case, the scale factor (gain[]) is determined so that the
        #     appropriate number of bits will be dropped from or added to
        #     each signal.  (WFDB-x: if either resolution is unspecified,
        #     this is an error.)
        # 2.  If the output gain has been specified, the signal is scaled by
        #     the ratio of the output and input gains.  (WFDB-x: if the input
        #     signal is uncalibrated, this is an error; the C program assumed
        #     an input gain of WFDB_DEFGAIN.)
        # These rules differ from those used by earlier versions of xform,
        # although the default behavior remains the same in most cases.
        if d.gain == 0.0            # output gain not specified
            # WFDB-x: rescaling by ADC resolution needs both resolutions (the
            # C program guessed an unspecified input resolution from the
            # format, assuming WFDB_DEFRES for 16-bit formats, as legacy mode
            # does).
            if legacy
                # input ADC resolution not specified: assume a suitable default
                di.adcres == 0 && (di.adcres = _xform_legacy_adcres(di.fmt, Int32(0)))
            elseif di.adcres == 0 || d.adcres == 0
                ceprintf("%s: ADC resolution of signal %d of record %s is not specified\n",
                         pname, di.adcres == 0 ? siglist[k] : Int32(k - 1),
                         di.adcres == 0 ? irec : (orec !== nothing ? orec : nrec))
                wfdbquit()
                cexit(2)
            end
            gain[k] = Float64(_xform_shl1(d.adcres)) / Float64(_xform_shl1(di.adcres))
        elseif di.gain == 0.0 && legacy     # (WFDB-x: as in the C program)
            gain[k] = d.gain / WFDB_DEFGAIN
        elseif di.gain == 0.0       # output gain specified, but input gain not specified
            ceprintf("%s: signal %d of record %s is uncalibrated; it cannot be rescaled to the specified gain\n",
                     pname, siglist[k], irec)
            wfdbquit()
            cexit(2)
        else                        # input and output gains specified
            gain[k] = d.gain / di.gain
        end

        gain[k] != 1.0 && (gflag = true)
        deltav[k] = d2i(d.adczero - gain[k] * di.adczero)
        if d.gain != di.gain * gain[k] || d.baseline != di.baseline * gain[k]
            d.gain = di.gain * gain[k]
            d.baseline = d2i(di.baseline * gain[k])
            reopen = true
        end
        # Note that dfout[i].gain is 0 (indicating that the signal is
        # uncalibrated) if dfin[j].gain is 0.  This is a *feature*, not a
        # bug:  we don't want to create output signals that appear to have
        # been calibrated if the inputs weren't calibrated.
    end

    # Reopen output signals if necessary.
    reopen && osigfopen(dfout, nosig) != nosig && cexit(2)

    # Determine the legal range of sample values for each output signal.
    # (C: unsigned long arithmetic, converted to int.)
    for k in 1:nosig
        half = UInt64(1) << ((dfout[k].adcres - 1) & 63)
        z = Int64(dfout[k].adczero) % UInt64
        vmax[k] = (z + half - 1) % Int32
        vmin[k] = (z - half) % Int32
    end

    # If resampling is required, initialize the interpolation/decimation
    # parameters.
    m = n = mn = Int32(0)
    if ifreq != ofreq
        f = _xform_gcd(ifreq, ofreq)
        fflag = true
        m = d2i(ifreq / f)
        n = d2i(ofreq / f)
        mn = m * n
        getvec(vin)
        for k in 1:nosig
            x = vin[siglist[k]+1]
            vv[k] = x != WFDB_INVALID_SAMPLE ? d2i(x * gain[k] + deltav[k]) : WFDB_INVALID_SAMPLE
        end
    end

    # If in multifrequency mode, set msiglist offsets.
    if mflag
        for k in 1:nosig
            for j in 1:siglist[k]
                msiglist[k] += dfin[j].spf
            end
        end
    end

    # Process the signals.
    if !fflag       # no frequency changes; gain changes if gflag
        while (mflag ? getframe(vin) : getvec(vin)) >= nisig && _xform_more!(nsamp)
            _xform_tick!(progress)
            if !mflag   # standard mode
                for k in 1:nosig
                    vt = vin[siglist[k]+1]
                    if vt == WFDB_INVALID_SAMPLE
                        vout[k] = vt
                    else
                        if gflag
                            vd = vt * gain[k] + deltav[k]
                            dflag && (vd += _xform_dither(rng))
                            vo = _xform_round(vd)
                        else
                            vo = vt + deltav[k]
                        end
                        vout[k] = _xform_check!(vo, k, vmax, vmin, clip)
                    end
                end
            else        # multifrequency mode
                j = 1
                for k in 1:nosig
                    for q in 0:dfout[k].spf-1
                        vt = vin[msiglist[k]+q+1]
                        if vt == WFDB_INVALID_SAMPLE
                            vout[j] = vt
                        else
                            if gflag
                                vd = vt * gain[k] + deltav[k]
                                dflag && (vd += _xform_dither(rng))
                                vo = _xform_round(vd)
                            else
                                vo = vt + deltav[k]
                            end
                            vout[j] = _xform_check!(vo, k, vmax, vmin, clip)
                        end
                        j += 1
                    end
                end
            end
            putvec(vout) < 0 && break
        end
    else            # change frequency (and gain, if gflag)
        while getvec(vin) >= nisig && _xform_more!(nsamp)
            _xform_tick!(progress)
            for k in 1:nosig
                vt = vin[siglist[k]+1]
                v[k] = if vt == WFDB_INVALID_SAMPLE
                    vt
                elseif gflag
                    vd = vt * gain[k] + deltav[k]
                    dflag && (vd += _xform_dither(rng))
                    _xform_round(vd)
                else
                    vt + deltav[k]
                end
            end
            while ot <= it
                r = ot % n
                x = r == 0 ? 1.0 : Float64(r) / n
                for k in 1:nosig
                    if v[k] == WFDB_INVALID_SAMPLE || vv[k] == WFDB_INVALID_SAMPLE
                        vout[k] = WFDB_INVALID_SAMPLE
                    else
                        vd = vv[k] + x * (v[k] - vv[k])
                        dflag && (vd += _xform_dither(rng))
                        vout[k] = _xform_check!(_xform_round(vd), k, vmax, vmin, clip)
                    end
                end
                if putvec(vout) < 0
                    nsamp[] = 0
                    break
                end
                ot += m
            end
            copyto!(vv, 1, v, 1, nosig)
            if it > mn
                it -= mn
                ot -= mn
            end
            it += n
        end
    end
    progress.nminutes > 0 && ceprintf("\n")

    # Generate a new header file, if so requested.
    if nrec !== nothing
        setsampfreq(ofreq)
        if get(btstring, 1, 0x00) == UInt8('[')
            setbasetime(btstring[2:end-1])     # (discard final ']')
        end
        newheader(nrec)

        # Copy info strings from the input header file into the new one.
        # Suppress error messages from the WFDB library.
        wfdbquiet()
        info = getinfo(irec)
        while info !== nothing
            putinfo(info)
            info = getinfo(nothing)
        end

        # Append additional info summarizing what xform has done.
        putinfo(cformat("Produced by %s from record %s, beginning at %s", pname, irec, startp))
        for k in 1:nosig
            if siglist[k] != k - 1
                xinfo = cformat("record %s, signal %d <- record %s, signal %d",
                                nrec, Int32(k - 1), irec, siglist[k])
                gain[k] != 1.0 && sprintf!(xinfo, " * %g", gain[k])
                if deltav[k] != 0
                    sprintf!(xinfo, " %c %d", deltav[k] > 0 ? '+' : '-',
                             deltav[k] > 0 ? deltav[k] : -deltav[k])
                end
                putinfo(xinfo)
            end
        end
        wfdbverbose()
    end
    wfdbquit()
    cexit(0)
end

register_workload("xform") do
    scripts = Dict{String,Any}(
        "xw1.txt" => "xw1\n2\n500\n\n16\ny\n\n\n\n\n\n\n",
        "xw2.txt" => "xw2\n2\n\n\n212\nn\nd0\nmV x\n100\n11\n0\nd1\n\n0\n\n0\n",
        "xw3.txt" => "xw3\n0\ny\n\n",
        "xw4.txt" => "xw4\n")
    with_workload_data(files=scripts) do dir
        workload_tool("xform", "-i", "100s", "-o", "fmt16", "-n", "xf1", "-t", "2")
        workload_tool("xform", "-i", "100s", "-o", "fmt212", "-n", "xf2", "-t", "2", "-c",
                      "-s", "1", "x", "0", "-a", "atr", "-u")
        workload_tool("xform", "-i", "fmt16", "-o", "100s", "-n", "xf3", "-t", "2", "-d")
        workload_tool("xform", "-i", "fmt16", "-o", "100s", "-N", "xf4", "-t", "1", "-c")
        workload_tool("xform", "-i", "100s", "-o", "fmt16", "-n", "xf5", "-f", "10", "-t", "20",
                      "-a", "atr")
        workload_tool("xform", "-i", "mfreq", "-o", "mfreq", "-n", "xf6", "-M")
        workload_tool("xform", "-i", "mfreq", "-o", "fmt16", "-n", "xf7", "-M")
        workload_tool("xform", "-i", "mfreq", "-o", "fmt16", "-n", "xf8", "-H", "-t", "1")
        workload_tool("xform", "-i", "100s", "-S", "xw1.txt", "-t", "2")
        workload_tool("xform", "-i", "100s", "-S", "xw1.txt", "-t", "2", "-d")
        workload_tool("xform", "-i", "100s", "-S", "xw2.txt", "-t", "2", "-N", "xw2")
        workload_tool("xform", "-i", "100s", "-S", "xw3.txt", "-a", "atr", "-t", "2")
        workload_tool("xform", "-i", "100s", "-S", "xw4.txt", "-t", "2")
        workload_tool("xform", "-i", "100s", "-S", "nosuch", "-t", "2")
        workload_tool("xform", "-i", "100s", "-o", "fmt16", "-t", "1")
        workload_tool("xform", "-i", "100s", "-o", "100s", "-n", "100s")
        workload_tool("xform", "-i", "nosuch", "-o", "fmt16")
        workload_tool("xform", "-i", "100s", "-o", "nosuch", "-n", "xf9")
        workload_tool("xform", "-i", "flac16", "-o", "fmt16", "-n", "xf10", "-t", "s100")
        workload_tool("xform", "-o", "fmt16")
        workload_tool("xform", "-h")
        workload_tool("xform", "-x")
        workload_tool("xform", "x")
        workload_tool("xform", "-a")
        workload_tool("xform", "-s")
    end
    with_workload_data(files=merge(NODEFAULTS_FILES, Dict{String,Any}(
            "xw5.txt" => "xw5\n2\n0\n",
            "xsa.txt" => "xf\n\n\n\n508\n\n" * "\n"^12,
            "ug.hea" => "ug 2 360\nug.dat 16 0 16 0 0 0 0 a\nug.dat 16 0 16 0 0 0 0 b\n"))) do dir
        workload_tool("xform", "-i", "nr", "-o", "ug", "-n", "xr", "-t", "s10")
        workload_tool("xform", "-i", "fmt16", "-S", "xsa.txt", "-t", "s5000")
        workload_tool("xform", "-i", "nf", "-n", "xn")
        workload_tool("xform", "-i", "100s", "-o", "nf", "-n", "xo")
        workload_tool("xform", "-i", "uc", "-o", "100s", "-n", "xu", "-t", "s10")
        workload_tool("xform", "-i", "100s", "-S", "xw5.txt", "-t", "2")
        # WFDB-x: legacy mode (original behavior)
        workload_tool("xform", "--legacy", "-i", "nr", "-o", "ug", "-n", "xr", "-t", "s10")
        workload_tool("xform", "--legacy", "-i", "fmt16", "-S", "xsa.txt", "-t", "s5000")
        workload_tool("xform", "--legacy", "-i", "nf", "-n", "xn", "-t", "s10")
        workload_tool("xform", "--legacy", "-i", "uc", "-o", "100s", "-n", "xu", "-t", "s10")
        workload_tool("xform", "--legacy", "-i", "100s", "-S", "xw5.txt", "-t", "2")
    end
end
