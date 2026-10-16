# wfdb2mat: convert (all or part of) a WFDB signal file to Matlab .mat
# format (port of convert/wfdb2mat.c).
#
# If the input record name is REC, the output files are RECm.mat (a version
# 5 MAT-file containing a single matrix named 'val' of raw samples, one
# column per sample) and RECm.hea. See the C source for details.
#
# Copyright (C) 2009-2013 George B. Moody (original C program,
# convert/wfdb2mat.c; revised 2014-2021 by Benjamin Moody).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does
# not give are never assumed (the original package assumed 250 Hz, 200
# adu/mV, 12 bits and millivolts), because a silently assumed value
# corrupts every result derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).

# Output .mat data storage types (values of the sub4 tag), defined by the
# .mat format specification.
const MAT8 = 2      # 8 bits per sample unsigned
const MAT16 = 3     # 16 bits per sample signed
const MAT32 = 5     # 32 bits per sample signed

# Other .mat format constants.
const _WFDB2MAT_MASTERTYPE = 14      # data type of the master tag: matrix
const _WFDB2MAT_SUB1TYPE = 6         # array flags: UINT32
const _WFDB2MAT_SUB2TYPE = 5         # dimensions: INT32
const _WFDB2MAT_SUB3TYPE = 1         # array name: INT8
const _WFDB2MAT_SUB1CLASS = 6        # MATLAB value class (double array)
const _WFDB2MAT_FIELDVERSION = 256   # 0x0100: a .mat file
const _WFDB2MAT_SUBELEMENT_SIZE = 8  # size of the array flags and dimensions
"Length of the .mat prolog: 128-byte text header, 8-byte master tag, and
56 bytes of subelements (48 bytes + 8-byte name)."
const _WFDB2MAT_PROLOG_LEN = 192
"Length of the descriptive text header of a .mat file."
const _WFDB2MAT_TEXT_LEN = 128
"Bytes of the master element besides the data (without padding)."
const _WFDB2MAT_MASTER_EXTRA = 56
"Alignment of .mat data elements, in bytes."
const _WFDB2MAT_ALIGN = 8
"Maximum size of the matrix (2^31 bytes)."
const _WFDB2MAT_MAX_BYTES = UInt64(2147483648)
"ADC zero of 8-bit (unsigned) .mat samples, as interpreted by Matlab."
const _WFDB2MAT_OFFSET8 = Int32(128)

const _WFDB2MAT_HELP = (
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -l INTERVAL truncate output after the specified time interval (hh:mm:ss)",
    " -s SIGNAL   [SIGNAL ...]  convert only the specified signal(s)",
    " -S SIGNAL   search for a valid sample of the specified SIGNAL at or after",
    "\t\tthe time specified with -f, and begin converting then",
    " -t TIME     stop at specified time",
    "Outputs are written to the current directory as RECORD.mat and RECORDm.hea.")

# Store the low 32 bits of x (little-endian) at p[at+1:at+4] (at is a C
# offset).
function _wfdb2mat_put32!(p::Vector{UInt8}, at::Integer, x::Integer)
    for k in 0:3
        p[at+k+1] = (x >> (8k)) % UInt8
    end
end

# The output record name: the input record name without its directory
# part (and without a trailing '/'), with '.' replaced by '_', and 'm'
# appended.
function _wfdb2mat_orec(r::Vector{UInt8})
    sfname = 0
    q = length(r) - 1                   # C index of the final character
    q >= 0 && r[q+1] == UInt8('/') && (sfname = 1)  # short form name ('rec/')
    while true
        q -= 1
        q <= 0 && break
        if r[q+1] == UInt8('/')         # omit path components from orec
            q += 1
            break
        end
    end
    q = max(q, 0)
    orec = r[q+1:end-sfname]
    # If the input record is an EDF file, it will have a '.' in its name.
    # The output record will not be an EDF file, so it may not have a '.'
    # in its name. Replace any '.' with '_' here.
    replace!(orec, UInt8('.') => UInt8('_'))
    push!(orec, UInt8('m'))
end

function wfdb2mat_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "wfdb2mat"
    record = nothing
    search = nothing
    highres = false
    isiglist = 0
    nosig = 0
    stat = Int32(0)
    from = to = maxl = Int64(0)     # argument indices, then times

    i = 1
    while i < argc
        a = argv[i]
        if !isempty(a) && a[1] == UInt8('-')
            c = length(a) >= 2 ? a[2] : 0x00
            if c == UInt8('f')          # starting time
                i += 1
                if i >= argc
                    ceprintf("%s: time must follow -f\n", pname)
                    cexit(1)
                end
                from = Int64(i)
            elseif c == UInt8('h')      # help requested
                _convert_help(pname, _WFDB2MAT_HELP)
                cexit(0)
            elseif c == UInt8('H')      # select high-resolution mode
                highres = true
            elseif c == UInt8('l')      # maximum length of output follows
                i += 1
                if i >= argc
                    ceprintf("%s: max output length must follow -l\n", pname)
                    cexit(1)
                end
                maxl = Int64(i)
            elseif c == UInt8('r')      # record name
                i += 1
                if i >= argc
                    ceprintf("%s: record name must follow -r\n", pname)
                    cexit(1)
                end
                record = cstr(argv[i])
            elseif c == UInt8('s')      # signal list follows
                isiglist = i + 1        # index of first argument containing a signal #
                while i + 1 < argc && !(!isempty(argv[i+1]) && argv[i+1][1] == UInt8('-'))
                    i += 1
                    nosig += 1          # number of elements in signal list
                end
                if nosig == 0
                    ceprintf("%s: signal list must follow -s\n", pname)
                    cexit(1)
                end
            elseif c == UInt8('S')      # search for valid sample of specified signal
                i += 1
                if i >= argc
                    ceprintf("%s: signal name or number must follow -S\n", pname)
                    cexit(1)
                end
                search = cstr(argv[i])
            elseif c == UInt8('t')      # end time
                i += 1
                if i >= argc
                    ceprintf("%s: time must follow -t\n", pname)
                    cexit(1)
                end
                to = Int64(i)
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
    if record === nothing
        _convert_help(pname, _WFDB2MAT_HELP)
        cexit(1)
    end
    nisig = isigopen(record, nothing, 0)
    nisig <= 0 && cexit(2)
    si = [Siginfo() for _ in 1:nisig]
    vi = zeros(Int32, nisig)
    nisig = isigopen(record, si, nisig)
    nisig <= 0 && cexit(2)
    # wfdb-x: uncalibrated signals remain uncalibrated in the output (the C
    # program assumed 200 adu/mV), and the output header needs the sampling
    # frequency (the C program assumed 250 Hz). Legacy mode: as in the C
    # program.
    if legacy
        for k in 1:nisig
            si[k].gain == 0.0 && (si[k].gain = WFDB_DEFGAIN)
        end
    end
    highres && setgvmode(WFDB_HIGHRES)
    freq = sampfreq(nothing)
    if freq <= 0.0 && !legacy
        ceprintf("%s: sampling frequency of record %s is not specified\n", pname, record)
        cexit(2)
    end
    if from > 0
        from = strtim(argv[from])
        from < 0 && (from = -from)
    end
    isigsettime(from) < 0 && cexit(2)
    if to > 0
        to = strtim(argv[to])
        to < 0 && (to = -to)
    end
    if nosig != 0
        # convert samples only from specified signals
        sig = zeros(Int, nosig)
        for k in 1:nosig
            s = findsig(argv[isiglist+k-1])
            if s < 0
                ceprintf("%s: can't read signal '%s'\n", pname, argv[isiglist+k-1])
                cexit(2)
            end
            sig[k] = s + 1
        end
    else
        # convert samples from all signals
        nosig = Int(nisig)
        sig = collect(1:nosig)
    end
    vo = zeros(Int32, nosig)

    # Reset 'from' if a search was requested.
    if search !== nothing
        s = findsig(search)
        ok = s >= 0
        if ok
            from = tnextvec(s, from)
            ok = from >= 0
        end
        if !ok
            ceprintf("%s: can't read signal '%s'\n", pname, search)
            cexit(2)
        end
    end

    # Reset 'to' if a duration limit was specified.
    if maxl > 0
        maxl = strtim(argv[maxl])
        maxl < 0 && (maxl = -maxl)
    end
    if maxl != 0 && (to == 0 || to > from + maxl)
        to = from + maxl
    end

    t = strtim("e")                 # the end of the record
    if t == 0
        # record length unspecified; determine length by a binary search
        wfdbquiet()
        lower = Int64(0)
        upper = WFDB_TIME_MAX
        t = Int64(16 * 1024)        # (first guess, as in C)
        while lower < upper
            if isigsettime(t) >= 0 && getvec(vi) > 0
                lower = t + 1
            else
                upper = t
            end
            if upper == WFDB_TIME_MAX && t < WFDB_TIME_MAX ÷ 2
                t *= 2
            else
                t = lower + (upper - lower) ÷ 2
            end
        end
        wfdbverbose()
        isigsettime(from) < 0 && cexit(2)
    end
    (to == 0 || to > t) && (to = t)

    # Quit if there will be no output.
    if to <= from
        wfdbquit()
        ceprintf("%s: no output\n", pname)
        ceprintf(" Use the -f and -t options to specify time limits\n(or type '%s -h' for help)\n",
                 pname)
        cexit(1)
    end

    # Generate the names for the output .mat file and the output record.
    orec = _wfdb2mat_orec(record)
    matname = vcat(orec, b".mat")

    # Determine if we can write 8-bit unsigned samples, or if 16 or 32 bits
    # are needed per sample.
    nbytesperelement = 1
    for k in sig
        s = si[k]
        if s.adcres > 0
            if s.adcres > 16
                nbytesperelement = 4
            elseif s.adcres > 8 && nbytesperelement < 2
                nbytesperelement = 2
            end
        else
            # adcres not specified; try to guess from format
            if s.fmt == 24 || s.fmt == 32
                nbytesperelement = 4
            elseif s.fmt != 80 && nbytesperelement < 2
                nbytesperelement = 2
            end
        end
    end
    sub4type, wfdbtype = nbytesperelement == 1 ? (MAT8, Int32(80)) :
                         nbytesperelement == 2 ? (MAT16, Int32(16)) : (MAT32, Int32(32))

    so = Siginfo[]
    for k in sig
        o = copy(si[k])
        o.fname = matname
        o.group = 0
        o.spf = 1
        o.fmt = wfdbtype
        o.adczero = 0
        o.baseline -= si[k].adczero
        # handle possibly missing units strings
        if o.units === nothing
            # wfdb-x: missing units are not assumed to be millivolts (except
            # in legacy mode: "in a .hea file, missing units can be assumed
            # to be millivolts")
            o.units = Vector{UInt8}(legacy ? b"mV" : b"nd")
        elseif isempty(o.units)
            # this can happen only in an EDF file; in this case, the signal
            # is dimensionless (nd => "no dimension")
            o.units = Vector{UInt8}(b"nd")
        end
        push!(so, o)
    end

    # Ensure the signal size does not exceed 2^31 byte limit
    max_length = _WFDB2MAT_MAX_BYTES ÷ UInt64(nbytesperelement) ÷ UInt64(nosig)
    if (to - from) % UInt64 > max_length
        ceprintf("%s: cannot write mat file - data size exceeds 2GB limit\n", pname)
        cexit(1)
    end

    # Bytes of actual data
    nbytesofdata = (Int64((nbytesperelement * nosig) % Int32) * (to - from)) % UInt64
    # This is the remaining no. bytes that don't fit into integer multiple
    # of 8. ie if 18 bytes, lremain=2, from 17 to 18.
    lremain = nbytesofdata % _WFDB2MAT_ALIGN

    # nbytesmaster = (8 + 8) + (8 + 8) + (8 + 8) + (8 + nbytesofdata)
    #  + padding. Must be integer multiple 8.
    if lremain == 0
        nbytesmaster = nbytesofdata + _WFDB2MAT_MASTER_EXTRA
    else
        nbytesmaster = nbytesofdata + _WFDB2MAT_MASTER_EXTRA + _WFDB2MAT_ALIGN - lremain
        for o in so
            o.bsize = _WFDB2MAT_ALIGN
        end
    end

    # Create an empty .mat file.
    if osigfopen(so, nosig) != nosig
        wfdbquit()                  # failed to open output, quit
        cexit(1)
    end

    # Fill in the .mat file's prolog and write it. (Elements of prolog not
    # set explicitly below are always zero.) Offsets are those of the C
    # source (0-based).
    prolog = zeros(UInt8, _WFDB2MAT_PROLOG_LEN)
    # Start with 128 byte header: descriptive text, then the version
    # (0x0100) and the characters IM to indicate little endian.
    copyto!(prolog, 1, b"MATLAB 5.0", 1, 10)
    prolog[125] = _WFDB2MAT_FIELDVERSION % UInt8
    prolog[126] = (_WFDB2MAT_FIELDVERSION >> 8) % UInt8
    prolog[127] = UInt8('I')
    prolog[128] = UInt8('M')

    # 8 byte MASTER TAG, followed by the actual data. First 4 is data type,
    # next 4 is number of bytes of entire field
    #  = (8 + 8) + (8 + 8) + (8 + 8) + (8 + Nvalues*bytespervalue)
    #  = 56 + Nvalues*bytespervalue
    m = _WFDB2MAT_TEXT_LEN
    prolog[m+1] = _WFDB2MAT_MASTERTYPE
    _wfdb2mat_put32!(prolog, m + 4, nbytesmaster)

    # Matrix data has 4 subelements (5 if imag): Array flags, dimensions
    # array, array name, real part. Each subelement has its own subtag, and
    # subdata.

    # Subelement 1: Array flags (type, size, MATLAB value class: NOT the
    # same as sub4type).
    prolog[m+9] = _WFDB2MAT_SUB1TYPE
    prolog[m+13] = _WFDB2MAT_SUBELEMENT_SIZE
    prolog[m+17] = _WFDB2MAT_SUB1CLASS

    # Subelement 2: Rows (number of signals) and Cols (number of samples)
    prolog[m+25] = _WFDB2MAT_SUB2TYPE
    prolog[m+29] = _WFDB2MAT_SUBELEMENT_SIZE
    _wfdb2mat_put32!(prolog, m + 32, nosig)
    _wfdb2mat_put32!(prolog, m + 36, to - from)

    # Subelement 3: Array Name
    prolog[m+41] = _WFDB2MAT_SUB3TYPE
    prolog[m+45] = 3
    copyto!(prolog, m + 49, b"val", 1, 3)

    # Subelement 4: Data itself
    prolog[m+57] = sub4type
    _wfdb2mat_put32!(prolog, m + 60, nbytesofdata)

    wfdbputprolog(prolog, _WFDB2MAT_PROLOG_LEN, 0)

    # Copy the selected data into the .mat file.
    t = from
    while t < to && stat >= 0
        stat = getvec(vi)
        for k in 1:nosig
            vo[k] = vi[sig[k]] - si[sig[k]].adczero
        end
        putvec(vo) != nosig && break
        t += 1
    end

    # If the input ended prematurely, pad the matrix with invalid samples.
    if t != to
        ceprintf("%s (warning): final %lld columns are invalid\n", pname, to - t)
        fill!(vo, WFDB_INVALID_SAMPLE)
        while t < to
            t += 1
            putvec(vo)
        end
    end

    # Create the new header file.
    setsampfreq(freq)
    p = codeunits(mstimstr(-from))
    !isempty(p) && p[1] == UInt8('[') && setbasetime(p[2:end])
    newheader(orec)

    # Copy info from the old record, if any
    while (info = getinfo(nothing)) !== nothing
        putinfo(info)
    end

    # Append additional info summarizing what wfdb2mat has done.
    putinfo(cformat("Creator: %s", pname))
    p = cformat("Source: record %s", record)
    q = lstrip(==(' '), mstimstr(0))
    if from != 0 || startswith(q, '[')
        append!(p, b"  Start: ")
        append!(p, codeunits(q))
    end
    putinfo(p)

    # Determine offset between sample values and the raw byte/word values
    # as interpreted by Matlab/Octave.
    offset = wfdbtype == 80 ? _WFDB2MAT_OFFSET8 : Int32(0)

    # Summarize the contents of the .mat file.
    ns = Int32(nosig)
    s1 = ns == 1 ? "" : "s"
    s2 = to == from + 1 ? "" : "s"
    cprintf("%s\n", p)
    cprintf("val has %d row%s (signal%s) and %lld column%s (sample%s/signal)\n",
            ns, s1, s1, to - from, s2, s2)
    cprintf("Duration: %s\n", timstr(to - from))
    cprintf("Sampling frequency: %.12g Hz  Sampling interval: %.10g sec\n", freq, 1.0 / freq)
    cprintf("Row\tSignal\tGain\tBase\tUnits\n")
    for (k, o) in enumerate(so)
        cprintf("%d\t%s\t%.12g\t%d\t%s\n", Int32(k), o.desc, o.gain, o.baseline + offset, o.units)
    end
    cprintf("\nTo convert from raw units to the physical units shown\nabove, call the 'rdmat.m' function from the wfdb-matlab\ntoolbox: https://physionet.org/physiotools/matlab/wfdb-app-matlab/\n")
    wfdbquit()
    cexit(0)
end

register_workload("wfdb2mat") do
    nolen = "nolen 2 360\r\n100s.dat 212 200 11 1024 995 0 0 a\r\n100s.dat 212 200 11 1024 1011 0 0 b\r\n"
    with_workload_data(; files=Dict{String,Any}("nolen.hea" => nolen)) do dir
        for r in ("100s", "fmt16", "fmt80", "fmt24", "fmt32", "mfreq", "fmt212b", "fmt16.edf", "skew",
                  "vlay", "flac16", "nolen")
            workload_tool("wfdb2mat", "-r", r, "-t", "s300")
        end
        workload_tool("wfdb2mat", "-r", "100s", "-f", "10", "-l", "0:3", "-s", "1")
        workload_tool("wfdb2mat", "-r", "100s", "-s", "V5", "MLII", "-t", "s21")
        workload_tool("wfdb2mat", "-r", "100s", "-s", "V6")
        workload_tool("wfdb2mat", "-r", "fmt16", "-S", "2", "-t", "s50")
        workload_tool("wfdb2mat", "-r", "mfreq", "-H")
        workload_tool("wfdb2mat", "-r", "100s", "-f", "70")
        workload_tool("wfdb2mat", "-r", "100s", "-f", "59", "-t", "100")
        workload_tool("wfdb2mat", "-r", "nosuch")
        workload_tool("wfdb2mat", "-r", "100s", "-x")
        workload_tool("wfdb2mat", "x")
        workload_tool("wfdb2mat", "-h")
        workload_tool("wfdb2mat")
    end
    with_workload_data(files=NODEFAULTS_FILES) do dir
        workload_tool("wfdb2mat", "-r", "nf")
        workload_tool("wfdb2mat", "-r", "uc", "-t", "s10")
        workload_tool("wfdb2mat", "-r", "nr", "-t", "s10")
        for rec in ("nf", "uc", "nr")       # wfdb-x: legacy mode (original behavior)
            workload_tool("wfdb2mat", "--legacy", "-r", rec, "-t", "s10")
        end
    end
end
