# rdsamp: print an arbitrary number of samples from each signal.
#
# The output is identical to that of the C program. Samples are read in
# blocks with `getvecs` (equivalent to repeated `getvec` calls) except when
# the time column is printed with `timstr` or `mstimstr`, whose results
# could depend on library state changed while reading (e.g., at the start of
# a new segment); numbers are formatted without `printf` (with identical
# results) for speed.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of app/rdsamp.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency or gain: the
# sampling frequency is required for time arguments, time columns and XML
# output (-X), and the gain of each selected signal for physical units (-p, -P)
# (the original assumed 250 Hz and 200 adu/mV); unspecified units are shown as
# "nd" (the original showed "mV"); --legacy, as the first argument, restores
# the original behavior. Each change is marked "wfdb-x:" in the code;
# docs/DIVERGENCES.md gives the reasons.
#
# Original C program: app/rdsamp.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1983-2010 George B. Moody; revised 2017-2020 by
#   Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

# values for timeunits
const _RDSAMP_SECONDS = 1
const _RDSAMP_MINUTES = 2
const _RDSAMP_HOURS = 3
const _RDSAMP_TIMSTR = 4
const _RDSAMP_MSTIMSTR = 5
const _RDSAMP_SHORTTIMSTR = 6
const _RDSAMP_HHMMSS = 7
const _RDSAMP_SAMPLES = 8

"Frames read at a time."
const _RDSAMP_CHUNK = 4096
"Size at which the output buffer is written to the standard output."
const _RDSAMP_OUT_LIMIT = 1 << 16
"Length of the `tustr` buffer of the C program (with its terminating NUL)."
const _RDSAMP_TUSTR_LEN = 21
"Length of the `speriod` buffer of the C program (with its terminating NUL)."
const _RDSAMP_SPERIOD_LEN = 11
"Maximum widths of a column heading (normal and high-precision output)."
const _RDSAMP_HEADING_WIDTH = 7
const _RDSAMP_HEADING_WIDTH_HP = 15
"Maximum lengths of a units string in a column heading."
const _RDSAMP_UNITS_WIDTH = 5
const _RDSAMP_UNITS_WIDTH_HP = 13

const _RDSAMP_XMLPROLOG = b"""<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="wfdb.xsl"?>
<!DOCTYPE wfdbsampleset PUBLIC "-//PhysioNet//DTD WFDB 1.0//EN" "http://physionet.org/physiobank/database/XML/wfdb.dtd">
"""

const _RDSAMP_HELP = [
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -c          use CSV (comma-separated value) output format",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -l INTERVAL truncate output after the specified time interval (hh:mm:ss)",
    " -p          print times and samples in physical units (default: raw units)",
    " -P          same as -p, but with greater precision",
    "              -p and -P may be followed by a character to choose a time",
    "              format;  choices are:",
    "  -pd (or -Pd)  print time of day and date if known",
    "  -pe (or -Pe)  print elapsed time as <hours>:<minutes>:<seconds>",
    "  -ph (or -Ph)  print elapsed time in hours",
    "  -pm (or -Pm)  print elapsed time in minutes",
    "  -ps (or -Ps)  print elapsed time in seconds",
    "  -pS (or -PS)  print elapsed time in sample intervals",
    " -s SIGNAL [SIGNAL ...]  print only the specified signal(s)",
    " -S SIGNAL   search for a valid sample of the specified SIGNAL at or after",
    "\t\tthe time specified with -f, and begin printing then",
    " -t TIME     stop at specified time",
    " -v          print column headings",
    " -X          output in WFDB-XML format",
]

function _rdsamp_help(pname)
    ceprintf("usage: %s -r RECORD [OPTIONS ...]\n", pname)
    for s in _RDSAMP_HELP
        ceprintf("%s\n", s)
    end
end

# Escape quotes and backslashes for CSV column headings. (The C version of
# this function does not terminate for most strings that contain these
# characters; see docs/KNOWN_C_BEHAVIORS.md.)
function _rdsamp_escapify(s::Vector{UInt8})
    r = UInt8[]
    for c in cstr(s)
        (c == UInt8('\'') || c == UInt8('\\')) && push!(r, UInt8('\\'))
        push!(r, c)
    end
    r
end

"Largest precision handled by the fast fixed-point formatter."
const _RDSAMP_FAST_PREC_MAX = 9
const _RDSAMP_POW10 = UInt128[UInt128(10)^i for i in 0:_RDSAMP_FAST_PREC_MAX]

# glibc's `%<width>.<prec>f` of a finite `x` whose exact value can be scaled
# by 10^prec in 128-bit arithmetic (correctly rounded, halfway cases to
# even, as glibc rounds the exact binary value). Returns false (writing
# nothing) if `x` is out of the range of this fast path.
function _rdsamp_fixed_fast!(buf::Vector{UInt8}, x::Float64, width::Int, prec::Int)
    (isfinite(x) && prec <= _RDSAMP_FAST_PREC_MAX) || return false
    neg = signbit(x)
    m, e = _f64_parts(x)                # |x| = m * 2^e, m < 2^53
    p10 = @inbounds _RDSAMP_POW10[prec+1]
    if e >= 0
        e > 40 && return false          # (m * 2^e * 10^9 < 2^123 fits)
        q = (UInt128(m) << e) * p10
    else
        k = -e
        n = UInt128(m) * p10    # < 2^84
        if k >= 120
            q = UInt128(0)      # (far below 0.5)
        else
            q = n >> k
            rem = n & ((UInt128(1) << k) - 1)
            half = UInt128(1) << (k - 1)
            (rem > half || (rem == half && isodd(q))) && (q += 1)
        end
    end
    q > typemax(UInt64) && return false
    u = UInt64(q)
    # digits, least significant first
    tmp = _RDSAMP_DIGITS
    nd = 0
    while true
        nd += 1
        @inbounds tmp[nd] = UInt8('0') + (u % 10) % UInt8
        u ÷= 10
        if nd == prec
            nd += 1
            @inbounds tmp[nd] = UInt8('.')
        end
        (u == 0 && nd > prec + (prec > 0)) && break
    end
    if neg
        nd += 1
        @inbounds tmp[nd] = UInt8('-')
    end
    for _ in nd+1:width
        push!(buf, UInt8(' '))
    end
    for i in nd:-1:1
        push!(buf, @inbounds tmp[i])
    end
    true
end
const _RDSAMP_DIGITS = zeros(UInt8, 48)     # (room for any number of the fast paths)

# printf("<lead>%<width>.<prec>f", x) (lead may be 0); fmt is that format
# (without the lead), used if the fast path cannot be.
@inline function _rdsamp_fixed!(buf::Vector{UInt8}, lead::UInt8, x::Float64, width::Int,
                                prec::Int, fmt::String)
    lead != 0 && push!(buf, lead)
    _rdsamp_fixed_fast!(buf, x, width, prec) || sprintf!(buf, fmt, x)
    nothing
end

# printf("<lead>%<width>ld", v) (lead may be 0).
@inline function _rdsamp_integer!(buf::Vector{UInt8}, lead::UInt8, v::Int64, width::Int)
    tmp = _RDSAMP_DIGITS
    u = unsigned(v < 0 ? -v : v)    # (typemin(Int64) is its own unsigned magnitude)
    nd = 0
    while true
        nd += 1
        @inbounds tmp[nd] = UInt8('0') + (u % 10) % UInt8
        u ÷= 10
        u == 0 && break
    end
    if v < 0
        nd += 1
        @inbounds tmp[nd] = UInt8('-')
    end
    lead != 0 && push!(buf, lead)
    for _ in nd+1:width
        push!(buf, UInt8(' '))
    end
    for i in nd:-1:1
        push!(buf, @inbounds tmp[i])
    end
    nothing
end

function _rdsamp_flush!(out::Vector{UInt8})
    if !isempty(out)
        cout_write(out)
        empty!(out)
    end
    nothing
end

_rdsamp_skip_spaces(s::String) = String(lstrip(==(' '), s))

function rdsamp_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "rdsamp"
    record = 0
    search = 0
    cflag = false
    highres = false
    isiglist = 0
    nosig = 0
    pflag = 0
    timeunits = _RDSAMP_SECONDS
    vflag = false
    xflag = false
    from = Int64(0)
    maxl = Int64(0)
    to = Int64(0)

    i = 1
    while i < argc
        a = argv[i]
        if !isempty(a) && a[1] == UInt8('-')
            c1 = length(a) >= 2 ? a[2] : 0x00
            c2 = length(a) >= 3 ? a[3] : 0x00
            if c1 == UInt8('c')         # output in CSV format
                cflag = true
            elseif c1 == UInt8('f')     # starting time
                i += 1
                if i >= argc
                    ceprintf("%s: time must follow -f\n", pname)
                    cexit(1)
                end
                from = i
            elseif c1 == UInt8('h')     # help requested
                _rdsamp_help(pname)
                cexit(0)
            elseif c1 == UInt8('H')     # select high-resolution mode
                highres = true
            elseif c1 == UInt8('l')     # maximum length of output follows
                i += 1
                if i >= argc
                    ceprintf("%s: max output length must follow -l\n", pname)
                    cexit(1)
                end
                maxl = i
            elseif c1 == UInt8('P') || c1 == UInt8('p')
                # output in (high-precision) physical units
                c1 == UInt8('P') && (pflag += 1)
                pflag += 1
                timeunits = c2 == UInt8('d') ? _RDSAMP_TIMSTR :
                            c2 == UInt8('e') ? _RDSAMP_HHMMSS :
                            c2 == UInt8('h') ? _RDSAMP_HOURS :
                            c2 == UInt8('m') ? _RDSAMP_MINUTES :
                            c2 == UInt8('S') ? _RDSAMP_SAMPLES : _RDSAMP_SECONDS
            elseif c1 == UInt8('r')     # record name
                i += 1
                if i >= argc
                    ceprintf("%s: record name must follow -r\n", pname)
                    cexit(1)
                end
                record = i
            elseif c1 == UInt8('s')     # signal list follows
                isiglist = i + 1        # index of first argument containing a signal #
                while i + 1 < argc && !(!isempty(argv[i+1]) && argv[i+1][1] == UInt8('-'))
                    i += 1
                    nosig += 1          # number of elements in signal list
                end
                if nosig == 0
                    ceprintf("%s: signal list must follow -s\n", pname)
                    cexit(1)
                end
            elseif c1 == UInt8('S')     # search for valid sample of specified signal
                i += 1
                if i >= argc
                    ceprintf("%s: signal name or number must follow -S\n", pname)
                    cexit(1)
                end
                search = i
            elseif c1 == UInt8('t')     # end time
                i += 1
                if i >= argc
                    ceprintf("%s: time must follow -t\n", pname)
                    cexit(1)
                end
                to = i
            elseif c1 == UInt8('v')     # verbose output -- include column headings
                vflag = true
            elseif c1 == UInt8('X')     # output in WFDB-XML format
                xflag = cflag = vflag = true    # CSV inside an XML wrapper
            else
                ceprintf("%s: unrecognized option %s\n", pname, argv[i])
                cexit(1)
            end
        else
            ceprintf("%s: unrecognized argument %s\n", pname, argv[i])
            cexit(1)
        end
        i += 1
    end
    if record == 0
        _rdsamp_help(pname)
        cexit(1)
    end
    rec = argv[record]
    nsig = isigopen(rec, nothing, 0)
    nsig <= 0 && cexit(2)
    navail = Int(nsig)
    si = [Siginfo() for _ in 1:nsig]
    nsig = isigopen(rec, si, nsig)
    nsig <= 0 && cexit(2)
    if legacy                       # wfdb-x: the C program's default gain
        for k in 1:nsig
            si[k].gain == 0.0 && (si[k].gain = WFDB_DEFGAIN)
        end
    end
    highres && setgvmode(WFDB_HIGHRES)
    freq = sampfreq(nothing)
    # wfdb-x: no default sampling frequency (the C program assumed 250 Hz
    # if the header did not specify one, as legacy mode does).
    if !legacy && freq <= 0.0 &&
       ((from > 0 && wfdbx_time_needs_freq(argv[from]) != 0) ||
        (to > 0 && wfdbx_time_needs_freq(argv[to]) != 0) ||
        (maxl > 0 && wfdbx_time_needs_freq(argv[maxl]) != 0) ||
        xflag || (pflag != 0 && (timeunits != _RDSAMP_SAMPLES || vflag)))
        ceprintf("%s: sampling frequency of record %s is not specified\n", pname, rec)
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
    nvec = Int(nsig)    # number of samples returned by getvec
    if nosig > 0
        # print samples only from specified signals
        sig = Int[]
        for k in 0:nosig-1
            s = findsig(argv[isiglist+k])
            if s < 0
                ceprintf("%s: can't read signal '%s'\n", pname, argv[isiglist+k])
                cexit(2)
            end
            push!(sig, Int(s))
        end
    else
        # print samples from all signals
        sig = collect(0:nvec-1)
    end
    nsig = length(sig)

    # wfdb-x: no default gain (the C program assumed 200 adu/mV for
    # uncalibrated signals, as legacy mode does).
    if pflag != 0 && !legacy
        for k in 1:nsig
            if si[sig[k]+1].gain == 0.0
                ceprintf("%s: signal %d of record %s is uncalibrated\n", pname, sig[k], rec)
                cexit(2)
            end
        end
    end

    # Reset 'from' if a search was requested.
    if search > 0
        s = findsig(argv[search])
        ok = s >= 0
        if ok
            from = tnextvec(s, from)
            ok = from >= 0
        end
        if !ok
            ceprintf("%s: can't read signal '%s'\n", pname, argv[search])
            cexit(2)
        end
    end

    # Reset 'to' if a duration limit was specified.
    if maxl > 0
        maxl = strtim(argv[maxl])
        maxl < 0 && (maxl = -maxl)
    end
    (maxl != 0 && (to == 0 || to > from + maxl)) && (to = from + maxl)

    # Adjust timeunits if starting time or date is undefined.
    if timeunits == _RDSAMP_TIMSTR
        p = timstr(0)
        if !startswith(p, '[')
            timeunits = _RDSAMP_HHMMSS
        elseif ncodeunits(p) < 16
            timeunits = _RDSAMP_SHORTTIMSTR
        elseif freq > 1.0
            timeunits = _RDSAMP_MSTIMSTR
        end
    end
    if timeunits == _RDSAMP_HOURS
        freq *= 3600.0
    elseif timeunits == _RDSAMP_MINUTES
        freq *= 60.0
    end

    # Set formats for output.
    invalid = ""
    tufmt = UInt8[]
    if cflag
        # CSV output selected
        snfmt = ",'%s'"
        if pflag != 0
            # output in physical units
            if timeunits == _RDSAMP_SAMPLES
                tnfmt = "'sample interval'"
                tufmt = cformat("'%g sec'", 1.0 / freq)
                length(tufmt) >= _RDSAMP_TUSTR_LEN && resize!(tufmt, _RDSAMP_TUSTR_LEN - 1)
            elseif timeunits == _RDSAMP_SHORTTIMSTR
                tnfmt, tufmt = "'Time'", Vector{UInt8}(b"'hh:mm:ss.mmm'")
            elseif timeunits == _RDSAMP_TIMSTR
                tnfmt, tufmt = "'Time and date'", Vector{UInt8}(b"'hh:mm:ss dd/mm/yyyy'")
            elseif timeunits == _RDSAMP_MSTIMSTR
                tnfmt, tufmt = "'Time and date'", Vector{UInt8}(b"'hh:mm:ss.mmm dd/mm/yyyy'")
            elseif timeunits == _RDSAMP_HHMMSS
                tnfmt, tufmt = "'Elapsed time'", Vector{UInt8}(b"'hh:mm:ss.mmm'")
            elseif timeunits == _RDSAMP_HOURS
                tnfmt, tufmt = "'Elapsed time'", Vector{UInt8}(b"'hours'")
            elseif timeunits == _RDSAMP_MINUTES
                tnfmt, tufmt = "'Elapsed time'", Vector{UInt8}(b"'minutes'")
            else
                tnfmt, tufmt = "'Elapsed time'", Vector{UInt8}(b"'seconds'")
            end
            invalid = ",-"
        else
            # output in raw units
            tnfmt = "'sample #'"
        end
    else
        # output in tab-separated columns selected
        if pflag != 0
            # output in physical units
            if timeunits == _RDSAMP_SAMPLES
                tnfmt = "sample interval"
                speriod = cformat("(%g", 1.0 / freq)
                length(speriod) >= _RDSAMP_SPERIOD_LEN && resize!(speriod, _RDSAMP_SPERIOD_LEN - 1)
                tufmt = cformat("%10s sec)", speriod)
                length(tufmt) >= _RDSAMP_TUSTR_LEN && resize!(tufmt, _RDSAMP_TUSTR_LEN - 1)
            elseif timeunits == _RDSAMP_SHORTTIMSTR
                tnfmt, tufmt = "     Time", Vector{UInt8}(b"(hh:mm:ss.mmm)")
            elseif timeunits == _RDSAMP_TIMSTR
                tnfmt, tufmt = "   Time      Date    ", Vector{UInt8}(b"(hh:mm:ss dd/mm/yyyy)")
            elseif timeunits == _RDSAMP_MSTIMSTR
                tnfmt, tufmt = "      Time      Date    ", Vector{UInt8}(b"(hh:mm:ss.mmm dd/mm/yyyy)")
            elseif timeunits == _RDSAMP_HHMMSS
                tnfmt, tufmt = "   Elapsed time", Vector{UInt8}(b"   hh:mm:ss.mmm")
            elseif timeunits == _RDSAMP_HOURS
                tnfmt, tufmt = "   Elapsed time", Vector{UInt8}(b"        (hours)")
            elseif timeunits == _RDSAMP_MINUTES
                tnfmt, tufmt = "   Elapsed time", Vector{UInt8}(b"      (minutes)")
            else
                tnfmt, tufmt = "   Elapsed time", Vector{UInt8}(b"      (seconds)")
            end
            if pflag > 1
                # output in high-precision physical units
                snfmt = "\t%15s"
                invalid = "\t              -"
            else
                snfmt = "\t%7s"
                invalid = "\t      -"
            end
        else
            # output in raw units
            snfmt = "\t%7s"
            tnfmt = "       sample #"
        end
    end

    out = sizehint!(UInt8[], _RDSAMP_OUT_LIMIT + 1024)   # (+ room for a line)

    # Print WFDB-XML prolog if '-X' option selected.
    if xflag
        append!(out, _RDSAMP_XMLPROLOG)
        sprintf!(out, "<wfdbsampleset>\n<samplingfrequency>%g</samplingfrequency>\n<signals>%d</signals>\n<description>",
                 freq, Int32(nsig))
    end
    # Print column headers if '-v' option selected.
    if vflag
        append!(out, codeunits(tnfmt))
        for s in sig
            # Check if a default signal description was provided by looking
            # for the string ", signal " in the desc field. If so, replace it
            # with a shorter string.
            d = copy(_ostr(si[s+1].desc))
            _contains(d, b", signal ") && (d = cformat("sig %d", Int32(s)))
            if !cflag
                l = length(d)
                lim = pflag > 1 ? _RDSAMP_HEADING_WIDTH_HP : _RDSAMP_HEADING_WIDTH
                p = l > lim ? d[l-lim+1:l] : d
            else
                p = _rdsamp_escapify(d)
            end
            sprintf!(out, snfmt, p)
        end
        xflag && append!(out, b"</description>")
        push!(out, UInt8('\n'))
    end

    width = max(nvec, navail)
    # (the extra room lets getvecs read the last frame of a block in place)
    vbuf = zeros(Int32, _RDSAMP_CHUNK * width + width + 64)

    if pflag != 0
        # Print units as a second line of column headers if '-v' selected.
        if vflag
            xflag && append!(out, b"<units>")
            append!(out, tufmt)
            for s in sig
                un = si[s+1].units
                # wfdb-x: unspecified units are shown as "nd" (C, legacy mode: mV)
                u = un !== nothing ? copy(cstr(un)) : Vector{UInt8}(legacy ? b"mV" : b"nd")
                if !cflag
                    len = min(length(u), pflag > 1 ? _RDSAMP_UNITS_WIDTH_HP : _RDSAMP_UNITS_WIDTH)
                    ustring = UInt8['(']
                    append!(ustring, view(u, 1:len))
                    sprintf!(out, pflag > 1 ? "\t%14s)" : "\t%6s)", ustring)
                else
                    sprintf!(out, ",'%s'", _rdsamp_escapify(u))
                end
            end
            xflag && append!(out, b"</units>")
            push!(out, UInt8('\n'))
        end

        xflag && append!(out, b"<samplevectors>\n")
        # Frames are read in blocks unless timstr() or mstimstr() is used.
        block = timeunits in (_RDSAMP_SAMPLES, _RDSAMP_SECONDS, _RDSAMP_MINUTES, _RDSAMP_HOURS)
        vlead = cflag ? UInt8(',') : UInt8('\t')
        vprec = pflag > 1 ? 8 : 3
        vwidth = cflag ? 0 : pflag > 1 ? 15 : 7
        tprec = timeunits == _RDSAMP_MINUTES ? 5 : timeunits == _RDSAMP_HOURS ? 7 : 3
        twidth = cflag ? 0 : 15
        vfmt = cflag ? (pflag > 1 ? "%.8f" : "%.3f") : (pflag > 1 ? "%15.8f" : "%7.3f")
        tfmt = if !cflag
            timeunits == _RDSAMP_MINUTES ? "%15.5f" : timeunits == _RDSAMP_HOURS ? "%15.7f" : "%15.3f"
        else
            timeunits == _RDSAMP_MINUTES ? "%.5f" : timeunits == _RDSAMP_HOURS ? "%.7f" : "%.3f"
        end
        gains = Float64[si[s+1].gain for s in sig]
        bases = Float64[si[s+1].baseline for s in sig]
        invalidb = Vector{UInt8}(codeunits(invalid))
        while to == 0 || from < to
            k = block ? Int64(_RDSAMP_CHUNK) : Int64(1)
            (to != 0 && to - from < k) && (k = to - from)
            m = block ? getvecs(vbuf, k) : (getvec(vbuf) >= 0 ? Int64(1) : Int64(0))
            for f in 0:m-1
                vo = f * nvec
                if !cflag
                    if timeunits == _RDSAMP_TIMSTR
                        append!(out, codeunits(timstr(-from)))
                    elseif timeunits == _RDSAMP_SHORTTIMSTR || timeunits == _RDSAMP_MSTIMSTR
                        append!(out, codeunits(mstimstr(-from)))
                    elseif timeunits == _RDSAMP_HHMMSS
                        sprintf!(out, "%15s", from == 0 ? "0:00.000" : mstimstr(from))
                    elseif timeunits == _RDSAMP_SAMPLES
                        _rdsamp_integer!(out, 0x00, from, 15)
                    else
                        _rdsamp_fixed!(out, 0x00, from / freq, twidth, tprec, tfmt)
                    end
                else
                    if timeunits == _RDSAMP_TIMSTR
                        sprintf!(out, "'%s'", _rdsamp_skip_spaces(timstr(-from)))
                    elseif timeunits == _RDSAMP_SHORTTIMSTR || timeunits == _RDSAMP_MSTIMSTR
                        sprintf!(out, "'%s'", _rdsamp_skip_spaces(mstimstr(-from)))
                    elseif timeunits == _RDSAMP_HHMMSS
                        if from == 0
                            append!(out, b"'0:00.000'")
                        else
                            sprintf!(out, "'%s'", _rdsamp_skip_spaces(mstimstr(from)))
                        end
                    elseif timeunits == _RDSAMP_SAMPLES
                        _rdsamp_integer!(out, 0x00, from, 0)
                    else
                        _rdsamp_fixed!(out, 0x00, from / freq, twidth, tprec, tfmt)
                    end
                end

                from += 1
                for j in 1:nsig
                    v = vbuf[vo+sig[j]+1]
                    if v != WFDB_INVALID_SAMPLE
                        _rdsamp_fixed!(out, vlead, (v - bases[j]) / gains[j], vwidth, vprec, vfmt)
                    else
                        append!(out, invalidb)
                    end
                end
                push!(out, UInt8('\n'))
                length(out) >= _RDSAMP_OUT_LIMIT && _rdsamp_flush!(out)
            end
            m < k && break
        end
    else
        # output in raw units
        xflag && append!(out, b"<samplevectors>\n")
        vlead = cflag ? UInt8(',') : UInt8('\t')
        twidth, vwidth = cflag ? (0, 0) : (15, 7)
        while to == 0 || from < to
            k = Int64(_RDSAMP_CHUNK)
            (to != 0 && to - from < k) && (k = to - from)
            m = getvecs(vbuf, k)
            for f in 0:m-1
                vo = f * nvec
                _rdsamp_integer!(out, 0x00, from, twidth)
                from += 1
                for s in sig
                    _rdsamp_integer!(out, vlead, Int64(vbuf[vo+s+1]), vwidth)
                end
                push!(out, UInt8('\n'))
            end
            length(out) >= _RDSAMP_OUT_LIMIT && _rdsamp_flush!(out)
            m < k && break
        end
    end

    # print trailer if WFDB-XML output was selected
    xflag && append!(out, b"</samplevectors>\n</wfdbsampleset>\n")

    _rdsamp_flush!(out)
    wfdbquit()
    cexit(0)
end

register_workload("rdsamp") do
    with_workload_data() do dir
        for rec in ("100s", "fmt212", "fmt310", "fmt311", "fmt16", "fmt24", "fmt160", "flac16",
                    "100s.edf")
            workload_tool("rdsamp", "-r", rec, "-t", "0.1")
            workload_tool("rdsamp", "-r", rec, "-t", "0.1", "-p", "-v")
        end
        workload_tool("rdsamp", "-r", "100s", "-f", "1", "-t", "1.1", "-c", "-v")
        workload_tool("rdsamp", "-r", "100s", "-l", "0.1", "-P", "-v", "-s", "1", "0")
        workload_tool("rdsamp", "-r", "100s", "-t", "0.1", "-X")
        workload_tool("rdsamp", "-r", "100s", "-t", "0.1", "-p", "-X")
        for u in ("d", "e", "h", "m", "s", "S")
            workload_tool("rdsamp", "-r", "100s", "-t", "0.05", "-p" * u, "-v")
            workload_tool("rdsamp", "-r", "100s", "-t", "0.05", "-P" * u, "-c", "-v")
        end
        workload_tool("rdsamp", "-r", "100s", "-S", "0", "-t", "0.05", "-H")
        workload_tool("rdsamp", "-h")
        workload_tool("rdsamp", "-r", "nosuch")
        workload_tool("rdsamp", "-r", "100s", "-s", "nosuch")
        workload_tool("rdsamp", "-x")
    end
    with_workload_data(files=NODEFAULTS_FILES) do dir
        for opts in ("-r nf -t s5", "-r nf -t 1", "-r nf -f s2 -t s5 -pS", "-r nf -t s5 -p",
                     "-r nf -t s5 -X", "-r uc -t s5", "-r uc -t s5 -p",
                     "-r nr -t s3 -v -p")
            workload_tool("rdsamp", split(opts)...)
        end
        # wfdb-x: legacy mode (original behavior)
        for opts in ("-r nf -t 1 -p -v", "-r uc -t s5 -P -v", "-r nr -t s3 -v -p -X")
            workload_tool("rdsamp", "--legacy", split(opts)...)
        end
    end
end
