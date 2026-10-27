# calib.jl: the calibration list: calopen (reads a calibration file into the
# calibration list), getcal (finds an entry of the list), putcal (appends an
# entry), newcal (writes the list to a calibration file) and flushcal
# (empties the list). Calibration files are written with \r\n line
# separators.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of lib/calib.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original code, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language.
#
# Original C code: lib/calib.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1991-2013 George B. Moody; revised 2019-2022 by
#   Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

"The state of calib.c (the `cal` field of a `Wfdb`): the calibration list."
mutable struct CalState
    list::Vector{Calinfo}
end
CalState() = CalState(Calinfo[])

# The signal type that matches any signal (written as "*" in files).
const _CAL_WILDCARD = b"*"

"""
    calopen([w], cfname) -> Int32

C `calopen`: read a calibration file into the calibration list. With
`nothing`, the file named by the environment variable `WFDBCAL` (default
`wfdbcal`) is read. Unless the name begins with `+`, the list is emptied
first. The file is looked for in the WFDB path. Returns 0, or -2 if the
file cannot be read.

Translation of the C function calopen() (lib/calib.c, WFDB 10.7.0): same
arguments and results. Differences: the calibration file is found only where it
is named, not by a search of the WFDB path; see docs/DIVERGENCES.md.
"""
function calopen(w::Wfdb, cfname::OptByteStr)
    # If no calibration file is specified, use the default.
    name = if cfname !== nothing
        cstr(bytes(cfname))
    else
        something(cgetenv("WFDBCAL"), Vector{UInt8}(DEFWFDBCAL))
    end
    if !isempty(name) && name[1] == UInt8('+')  # don't empty the calibration list
        name = name[2:end]                      # discard the '+' prefix
    else
        flushcal(w)                             # empty the calibration list
    end

    # Quit if file can't be found or opened.
    cfile = wfdb_open(w, name, nothing, WFDB_READ)
    if cfile === nothing
        wfdb_error(w, "calopen: can't read calibration file %s\n", name)
        return Int32(-2)
    end

    # Read a line of the calibration file on each iteration. See wfdbcal(5)
    # for a description of the format.
    line = UInt8[]
    while getline!(cfile, line) > 0
        buf = cstr(line)
        # ignore leading whitespace
        k = 1
        while k <= length(buf) && buf[k] in (UInt8(' '), UInt8('\t'), UInt8('\r'))
            k += 1
        end
        # skip comments, empty lines, and improperly formatted lines
        (k <= length(buf) && buf[k] == UInt8('#')) && continue
        t = Strtok(view(buf, k:length(buf)))
        p1 = strtok(t, "\t")            # signal type
        p1 === nothing && continue
        p2 = strtok(t, " \t")           # low, or '-'
        p2 === nothing && continue
        p3 = strtok(t, " \t")           # high, or '-'
        p3 === nothing && continue
        p4 = strtok(t, " \t")           # pulse type
        p4 === nothing && continue
        p5 = strtok(t, " \t")           # scale
        p5 === nothing && continue
        p6 = strtok(t, " \t\r\n")       # units
        p6 === nothing && continue

        c = Calinfo()
        # "*" is a wildcard that matches any signal type.
        c.sigtype = p1 == _CAL_WILDCARD ? UInt8[] : Vector{UInt8}(p1)
        if p2 == b"-"
            c.caltype = WFDB_AC_COUPLED
            c.low = 0.0
        else
            c.caltype = WFDB_DC_COUPLED
            c.low = strtod(p2)[1]
        end
        if p3 == b"-"
            c.high = c.low = 0.0
        else
            c.high = strtod(p3)[1]
        end
        if p4 == b"square"
            c.caltype |= WFDB_CAL_SQUARE
        elseif p4 == b"sine"
            c.caltype |= WFDB_CAL_SINE
        elseif p4 == b"sawtooth"
            c.caltype |= WFDB_CAL_SAWTOOTH
        end                             # otherwise pulse shape is undefined
        c.scale = strtod(p5)[1]
        c.units = Vector{UInt8}(p6)
        push!(w.cal.list, c)
    end
    fclose(cfile)
    Int32(0)
end

"""
    getcal([w], desc, units, cal::Calinfo) -> Int32

C `getcal`: find the first calibration list entry whose signal type is a
prefix of `desc` and whose units are `units` (`nothing` matches anything),
and copy it into `cal`. Returns 0, or -1 if there is none.

Translation of the C function getcal() (lib/calib.c, WFDB 10.7.0): same
arguments and results.
"""
function getcal(w::Wfdb, desc::OptByteStr, units::OptByteStr, cal::Calinfo)
    d = desc === nothing ? nothing : cstr(bytes(desc))
    u = units === nothing ? nothing : cstr(bytes(units))
    for c in w.cal.list
        sigtype = something(c.sigtype, UInt8[])
        dmatch = d === nothing || (length(d) >= length(sigtype) &&
                                   view(d, 1:length(sigtype)) == sigtype)
        umatch = u === nothing || (c.units !== nothing && c.units == u)
        if dmatch && umatch
            cal.low = c.low
            cal.high = c.high
            cal.scale = c.scale
            cal.sigtype = c.sigtype === nothing ? nothing : copy(c.sigtype)
            cal.units = c.units === nothing ? nothing : copy(c.units)
            cal.caltype = c.caltype
            return Int32(0)
        end
    end
    Int32(-1)
end

"""
    putcal([w], cal::Calinfo) -> Int32

C `putcal`: append an entry to the calibration list.

Translation of the C function putcal() (lib/calib.c, WFDB 10.7.0): same
arguments and results.
"""
putcal(w::Wfdb, cal::Calinfo) = (push!(w.cal.list, copy(cal)); Int32(0))

"""
    newcal([w], cfname) -> Int32

C `newcal`: write the calibration list to a calibration file. Returns 0, or
-1 on errors.

Translation of the C function newcal() (lib/calib.c, WFDB 10.7.0): same
arguments and results.
"""
function newcal(w::Wfdb, cfname::ByteStr)
    name = cstr(bytes(cfname))
    wfdb_checkname(w, name, "calibration file") < 0 && return Int32(-1)
    cfile = wfdb_open(w, name, nothing, WFDB_WRITE)
    if cfile === nothing
        wfdb_error(w, "newcal: can't create calibration file %s\n", name)
        return Int32(-1)
    end

    for c in w.cal.list
        # If sigtype is an empty string (matches anything), write it as "*".
        sigtype = something(c.sigtype, UInt8[])
        cfprintf(cfile, "%s\t", isempty(sigtype) ? _CAL_WILDCARD : sigtype)
        if c.caltype & WFDB_DC_COUPLED != 0
            cfprintf(cfile, "%g ", c.low)
        else
            cfprintf(cfile, "- ")
        end
        if c.high != c.low
            cfprintf(cfile, "%g ", c.high)
        else
            cfprintf(cfile, "- ")
        end
        shape = c.caltype & ~WFDB_DC_COUPLED
        pulsetype = shape == WFDB_CAL_SQUARE ? "square" :
                    shape == WFDB_CAL_SINE ? "sine" :
                    shape == WFDB_CAL_SAWTOOTH ? "sawtooth" : "undefined"
        cfprintf(cfile, "%s %g %s\r\n", pulsetype, c.scale, c.units)
    end

    errflag = ferror(cfile)
    fclose(cfile) != 0 && (errflag = true)
    if errflag
        wfdb_error(w, "newcal: write error in calibration file\n")
        return Int32(-1)
    end
    Int32(0)
end

"""
    flushcal([w])

C `flushcal`: empty the calibration list.

Translation of the C function flushcal() (lib/calib.c, WFDB 10.7.0): same
arguments and results.
"""
flushcal(w::Wfdb) = (empty!(w.cal.list); nothing)

calopen(cfname::OptByteStr) = calopen(lib(), cfname)
getcal(desc::OptByteStr, units::OptByteStr, cal::Calinfo) = getcal(lib(), desc, units, cal)
putcal(cal::Calinfo) = putcal(lib(), cal)
newcal(cfname::ByteStr) = newcal(lib(), cfname)
flushcal() = flushcal(lib())

export calopen, getcal, putcal, newcal, flushcal
