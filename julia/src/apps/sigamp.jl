# sigamp: measure signal amplitudes.
#
# Without an annotator, sigamp measures the RMS amplitude of each signal in
# consecutive nonoverlapping windows; with one (-a), it measures
# peak-to-peak amplitudes in windows around each normal QRS annotation. It
# prints the trimmed means of the measurements (the largest and smallest 5%
# are discarded), and optionally the individual measurements.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of app/sigamp.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency or gain: the record
# must give the sampling frequency (the measurement windows are in seconds),
# and with -p the gain of each signal (the original assumed 250 Hz and 200
# adu/mV); --legacy, as the first argument, restores the original behavior.
# Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the
# reasons.
#
# Original C program: app/sigamp.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1991-2009 George B. Moody; revised 2018 by Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

"Default maximum number of measurements per signal."
const _SIGAMP_NMAX = Int32(300)
"The trimmed means discard 1/_SIGAMP_TRIM of the measurements at each end."
const _SIGAMP_TRIM = 20

# values for timeunits
const _SIGAMP_SECONDS = 1
const _SIGAMP_MINUTES = 2
const _SIGAMP_HOURS = 3
const _SIGAMP_TIMSTR = 4
const _SIGAMP_HHMMSS = 7
const _SIGAMP_SAMPLES = 8

const _SIGAMP_HELP = (
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where OPTIONS may include any of:",
    " -a ANN      specify annotator, measure amplitudes near QRS annotations",
    " -d DT1 DT2  set measurement window relative to QRS annotations",
    "              defaults: DT1 = 0.05 (seconds before annotation);",
    "              DT2 = 0.05 (seconds after annotation)",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -n NMAX     make up to NMAX measurements per signal (default: NMAX = $_SIGAMP_NMAX)",
    " -p          print results in physical units (default: ADC units)",
    "              -p may be followed by a character to choose a time format:",
    "  -pd         print time of day and date if known",
    "  -pe         print elapsed time as <hours>:<minutes>:<seconds>",
    "  -ph         print elapsed time in hours",
    "  -pm         print elapsed time in minutes",
    "  -ps         print elapsed time in seconds (default)",
    "  -pS         print elapsed time in sample intervals",
    " -q          quick mode: print individual measurements only",
    " -t TIME     stop at specified time",
    " -v          verbose mode: print individual measurements and trimmed means",
    " -w DTW      set RMS amplitude measurement window",
    "              default: DTW = 1 (second)")

function _sigamp_help(pname)
    ceprintf(_SIGAMP_HELP[1], pname)
    for i in 2:length(_SIGAMP_HELP)
        ceprintf("%s\n", _SIGAMP_HELP[i])
    end
end

# The C program's global variables.
mutable struct _SigampState
    namp::Int                   # number of measurements made
    nsig::Int32
    pflag::Bool                 # print physical units
    timeunits::Int
    v0::Vector{Int32}
    vmax::Vector{Int32}
    vmin::Vector{Int32}
    vv::Vector{Int32}
    amp::Vector{Vector{Float64}}    # amp[signal][measurement]
    vmean::Vector{Float64}
    vsum::Vector{Float64}
    dt1::Int64
    dt2::Int64
    dtw::Int64
    sfreq::Float64
    si::Vector{Siginfo}
end

# Storage for up to nmax measurements of each of nsig signals.
_sigamp_amp_arrays(nsig::Integer, nmax::Integer) = [zeros(Float64, nmax) for _ in 1:nsig]

# RMS amplitudes of the window starting at t (the input is at t).
function _sigamp_getrms(st::_SigampState, t::Int64)
    nsig = st.nsig
    vv, v0, vmean, vsum = st.vv, st.v0, st.vmean, st.vsum
    getvec(vv) < nsig && return -1
    for i in 1:nsig
        v0[i] = vv[i]
        vmean[i] = vv[i]
        vsum[i] = 0.0
    end
    for _ in 1:st.dtw-1
        getvec(vv) < nsig && return -1
        for i in 1:nsig
            vmean[i] += vv[i]
        end
    end

    (isigsettime(t) < 0 || getvec(vv) < nsig) && return -1

    # The quantity vv[i] - v0[i] is normally zero, but may be non-zero if
    # the signals are stored in difference format (since isigsettime may
    # introduce a DC error in this case).  In the calculation of vmean[i]
    # below, this quantity is used to correct any such error.
    for i in 1:nsig
        vmean[i] = vmean[i] / st.dtw + vv[i] - v0[i]
        v = d2i(vv[i] - vmean[i])
        vsum[i] += Float64(v) * v
    end
    for _ in 1:st.dtw-1
        getvec(vv) < nsig && return -1
        for i in 1:nsig
            v = d2i(vv[i] - vmean[i])
            vsum[i] += Float64(v) * v
        end
    end

    for i in 1:nsig
        st.amp[i][st.namp+1] = sqrt(vsum[i] / st.dtw)
    end
    0
end

# Peak-to-peak amplitudes in the window from t+dt1 to t+dt2.
function _sigamp_getptp(st::_SigampState, t::Int64)
    nsig = st.nsig
    vv, vmin, vmax = st.vv, st.vmin, st.vmax
    isigsettime(t + st.dt1) < 0 && return -1
    getvec(vmin) < nsig && return -1
    copyto!(vmax, vmin)
    for _ in st.dt1:st.dt2-1
        getvec(vv) < nsig && return -1
        for i in 1:nsig
            if vv[i] < vmin[i]
                vmin[i] = vv[i]
            elseif vv[i] > vmax[i]
                vmax[i] = vv[i]
            end
        end
    end
    for i in 1:nsig
        st.amp[i][st.namp+1] = vmax[i] - vmin[i]    # (Int32: wraps as in C)
    end
    0
end

function _sigamp_printamp(st::_SigampState, t::Int64)
    tu = st.timeunits
    if tu == _SIGAMP_TIMSTR
        cprintf("%s", mstimstr(-t))
    elseif tu == _SIGAMP_HHMMSS
        cprintf("%s", mstimstr(t))
    elseif tu == _SIGAMP_SAMPLES
        cprintf("%ld", t)
    else
        cprintf("%lf", t / st.sfreq)
    end
    for i in 1:st.nsig
        a = st.amp[i][st.namp+1]
        cprintf("\t%g", st.pflag ? a / st.si[i].gain : a)
    end
    cprintf("\n")
end

# strtim of an argument that may start with '-' (which is skipped), and
# whether it did.
function _sigamp_strtim_neg(p::Vector{UInt8})
    if get(p, 1, 0x00) == UInt8('-')
        strtim(p[2:end]), true
    else
        strtim(p), false
    end
end

function sigamp_main(args::Vector{String})
    # wfdb-x: --legacy as the first argument selects legacy mode (the
    # behavior of the original program; see wfdbx_legacy_args)
    legacy = wfdbx_legacy_args(args) != 0
    argv = cargs(args)              # C argv[i] (i >= 1) is argv[i]
    argc = length(argv) + 1
    pname = "sigamp"
    record = nothing
    ainame = nothing
    gvmode = Int32(0)
    nmax = _SIGAMP_NMAX
    pflag = qflag = vflag = false
    timeunits = _SIGAMP_SECONDS
    # argument indices at first (converted to times once the record is open)
    dt1 = dt2 = dtw = from = to = Int64(0)

    # Interpret command-line arguments.
    i = 1
    while i < argc
        a = argv[i]
        if get(a, 1, 0x00) == UInt8('-')
            c = get(a, 2, 0x00)
            if c == UInt8('a')
                i += 1
                if i >= argc
                    ceprintf("%s: annotator name must follow -a\n", pname)
                    cexit(1)
                end
                ainame = argv[i]
            elseif c == UInt8('d')
                i += 1
                if i >= argc - 1
                    ceprintf("%s: DT1 and DT2 must follow -d\n", pname)
                    cexit(1)
                end
                # save arg list index, convert arguments to samples later
                # (after record has been opened and sampling frequency is
                # known)
                dt1 = i
                i += 1
            elseif c == UInt8('f')
                i += 1
                if i >= argc
                    ceprintf("%s: start time must follow -f\n", pname)
                    cexit(1)
                end
                from = i    # save arg list index, convert argument to samples later
            elseif c == UInt8('h')      # help requested
                _sigamp_help(pname)
                cexit(0)
            elseif c == UInt8('H')      # operate in WFDB_HIGHRES mode
                gvmode = WFDB_HIGHRES
            elseif c == UInt8('n')
                i += 1
                if i >= argc
                    ceprintf("%s: number of measurements must follow -n\n", pname)
                    cexit(1)
                end
                nmax = atoi(argv[i])
                nmax < 1 && (nmax = _SIGAMP_NMAX)
            elseif c == UInt8('p')
                pflag = true
                c2 = get(a, 3, 0x00)
                timeunits = c2 == UInt8('d') ? _SIGAMP_TIMSTR :
                            c2 == UInt8('e') ? _SIGAMP_HHMMSS :
                            c2 == UInt8('h') ? _SIGAMP_HOURS :
                            c2 == UInt8('m') ? _SIGAMP_MINUTES :
                            c2 == UInt8('S') ? _SIGAMP_SAMPLES : _SIGAMP_SECONDS
            elseif c == UInt8('q')
                qflag = true
            elseif c == UInt8('r')
                i += 1
                if i >= argc
                    ceprintf("%s: record name must follow -r\n", pname)
                    cexit(1)
                end
                record = argv[i]
            elseif c == UInt8('t')
                i += 1
                if i >= argc
                    ceprintf("%s: stop time must follow -t\n", pname)
                    cexit(1)
                end
                to = i      # save arg list index, convert argument to samples later
            elseif c == UInt8('v')
                vflag = true
            elseif c == UInt8('w')
                i += 1
                if i >= argc
                    ceprintf("%s: window size must follow -w\n", pname)
                    cexit(1)
                end
                dtw = i     # save arg list index, convert argument to samples later
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
        _sigamp_help(pname)
        cexit(1)
    end

    # Finish initialization.
    if gvmode == 0
        p = cgetenv("WFDBGVMODE")
        p === nothing || (gvmode = atoi(p))
    end
    setgvmode(gvmode | WFDB_GVPAD)

    nsig = isigopen(record, nothing, 0)
    nsig <= 0 && cexit(2)
    si = [Siginfo() for _ in 1:nsig]
    isigopen(record, si, nsig) != nsig && cexit(2)
    # wfdb-x: no default gain (the C program assumed 200 adu/mV for
    # uncalibrated signals, as legacy mode does).
    for k in 1:nsig
        if legacy
            si[k].gain == 0.0 && (si[k].gain = WFDB_DEFGAIN)
        elseif pflag && si[k].gain == 0.0
            ceprintf("%s: signal %d of record %s is uncalibrated\n", pname, k - 1, record)
            cexit(2)
        end
    end
    # wfdb-x: no default sampling frequency (the C program assumed 250 Hz,
    # as legacy mode does); the measurement windows are defined in seconds.
    sfreq = sampfreq(nothing)
    if sfreq <= 0.0 && legacy
        sfreq = WFDB_DEFFREQ
    elseif sfreq <= 0.0
        ceprintf("%s: sampling frequency of record %s is not specified\n", pname, record)
        cexit(2)
    end

    # Adjust timeunits if starting time is undefined.
    if (timeunits == _SIGAMP_TIMSTR || timeunits == _SIGAMP_HHMMSS) &&
       !startswith(timstr(0), '[')
        timeunits = _SIGAMP_HHMMSS
    end
    if timeunits == _SIGAMP_HOURS
        sfreq *= 3600.0
    elseif timeunits == _SIGAMP_MINUTES
        sfreq *= 60.0
    end

    from > 0 && (from = strtim(argv[from]))
    to > 0 && (to = strtim(argv[to]))
    from < 0 && (from = -from)
    to < 0 && (to = -to)
    from >= to && (to = strtim("e"))

    st = _SigampState(0, nsig, pflag, timeunits, zeros(Int32, nsig), zeros(Int32, nsig),
                      zeros(Int32, nsig), zeros(Int32, nsig),
                      _sigamp_amp_arrays(nsig, nmax), zeros(nsig), zeros(nsig),
                      0, 0, 0, sfreq, si)

    # Collect amplitudes, print them if qflag or vflag set.
    if ainame !== nothing       # windows are relative to annotations
        annot = Annotation()
        if dtw > 0
            ceprintf("%s: -a and -w options cannot be used together;\n", pname)
            ceprintf("  -w option is being ignored\n")
        end
        annopen(record, [Anninfo(ainame, WFDB_READ)], 1) < 0 && cexit(2)
        if dt1 == 0
            dt2 = strtim("0.05")
            dt1 = -dt2
        else
            x, neg = _sigamp_strtim_neg(argv[dt1+1])
            dt2 = neg ? -x : x
            x, neg = _sigamp_strtim_neg(argv[dt1])
            dt1 = neg ? x : -x
            dt1 > dt2 && ((dt1, dt2) = (dt2, dt1))
        end
        dt1 == dt2 && (dt2 += 1)
        st.dt1, st.dt2 = dt1, dt2
        iannsettime(from) < 0 && cexit(2)
        while getann(0, annot) == 0 && st.namp < nmax && (to == 0 || annot.time < to)
            if map1(annot.anntyp) == NORMAL
                _sigamp_getptp(st, annot.time) < 0 && break
                (vflag || qflag) && _sigamp_printamp(st, annot.time)
                st.namp += 1
            end
        end
    else                        # windows are consecutive nonoverlapping segments
        if dt1 > 0
            ceprintf("%s: -d option must be used with -a;\n", pname)
            ceprintf("  -d option is being ignored\n")
        end
        dtw != 0 && (dtw = strtim(argv[dtw]))
        dtw <= 0 && (dtw = strtim("1"))
        st.dtw = dtw
        from > 0 && isigsettime(from) < 0 && cexit(2)
        t = from
        while st.namp < nmax && (to == 0 || t < to)
            _sigamp_getrms(st, t) < 0 && break
            (vflag || qflag) && _sigamp_printamp(st, t)
            st.namp += 1
            t += dtw
        end
    end

    # Calculate trimmed means of collected amplitudes unless -q option set.
    if !qflag
        namp = st.namp
        jlow = namp ÷ _SIGAMP_TRIM
        jhigh = namp - jlow
        vflag && cprintf("Trimmed mean")
        for i in 1:nsig
            amp = sort!(view(st.amp[i], 1:namp))
            a = 0.0
            for j in jlow+1:jhigh
                a += amp[j]
            end
            # (C: 0.0/0.0 if there are no measurements, a negative NaN on x86.)
            a = jhigh == jlow ? -NaN : a / (jhigh - jlow)
            cprintf("\t%g", pflag ? a / si[i].gain : a)
        end
        cprintf("\n")
    end
    cexit(0)
end

register_workload("sigamp") do
    with_workload_data() do dir
        workload_tool("sigamp", "-r", "100s", "-t", "5")
        workload_tool("sigamp", "-r", "100s", "-t", "5", "-v", "-p")
        workload_tool("sigamp", "-r", "100s", "-f", "1", "-t", "4", "-q", "-pS", "-w", "0.5")
        workload_tool("sigamp", "-r", "100s", "-t", "3", "-v", "-pd")
        workload_tool("sigamp", "-r", "100s", "-t", "3", "-v", "-pe", "-d", "0.1", "0.1")
        workload_tool("sigamp", "-r", "100s", "-t", "3", "-v", "-ph", "-H")
        workload_tool("sigamp", "-r", "100s", "-t", "3", "-v", "-pm", "-n", "2")
        workload_tool("sigamp", "-r", "100s", "-a", "atr", "-t", "10", "-v", "-p", "-w", "1")
        workload_tool("sigamp", "-r", "100s", "-a", "atr", "-d", "-0.1", "-0.2", "-n", "5", "-q")
        workload_tool("sigamp", "-r", "mfreq", "-v")
        workload_tool("sigamp", "-r", "fmt16", "-pd", "-v", "-t", "2")
        workload_tool("sigamp", "-r", "100s", "-a", "nosuch")
        workload_tool("sigamp", "-r", "nosuch")
        workload_tool("sigamp", "-r", "100s", "-f", "e")
        workload_tool("sigamp", "-x")
        workload_tool("sigamp", "x")
        workload_tool("sigamp", "-r")
        workload_tool("sigamp", "-h")
        workload_tool("sigamp")
    end
    with_workload_data(files=NODEFAULTS_FILES) do dir
        workload_tool("sigamp", "-r", "nf")
        workload_tool("sigamp", "-r", "uc", "-t", "2")
        workload_tool("sigamp", "-r", "uc", "-t", "2", "-p")
        # wfdb-x: legacy mode (original behavior)
        workload_tool("sigamp", "--legacy", "-r", "nf", "-t", "2", "-p")
        workload_tool("sigamp", "--legacy", "-r", "uc", "-t", "2", "-p", "-v")
    end
end
