# wfdbinit.jl: wfdbinit, wfdbquit, wfdbflush.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of lib/wfdbinit.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original code, but it is new code, not the original C code.
#
# Changes from the original: wfdbquit leaves the input and output directories
# as they are (the original restored the WFDB path); legacy mode
# (wfdbx_set_legacy) restores the original behavior. Each change is marked
# "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
#
# Original C code: lib/wfdbinit.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1983-2012 George B. Moody; revised 2012-2019 by
#   Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

"""
    wfdbinit([w], record, aiarray, nann, siarray, nsig) -> Int32

C `wfdbinit`: open the annotation files (`annopen`) and then the input
signals (`isigopen`) of `record`. Returns the status of `annopen` if it
failed, otherwise that of `isigopen`.

Translation of the C function wfdbinit() (lib/wfdbinit.c, WFDB 10.7.0): same
arguments and results. Differences: those of annopen() and isigopen(); see
docs/DIVERGENCES.md.
"""
function wfdbinit(w::Wfdb, record::OptByteStr, aiarray, nann::Integer,
                  siarray::Union{Nothing,AbstractVector{Siginfo}}, nsig::Integer)
    stat = annopen(w, record, aiarray, nann)
    stat == 0 && (stat = isigopen(w, record, siarray, nsig))
    stat
end
wfdbinit(record::OptByteStr, aiarray, nann::Integer,
         siarray::Union{Nothing,AbstractVector{Siginfo}}, nsig::Integer) =
    wfdbinit(lib(), record, aiarray, nann, siarray, nsig)

"""
    wfdbquit([w])

C `wfdbquit`: close all annotators, signals and the info file, and release
the library's buffers. The input and output directories are left as they
are (WFDB-x; in legacy mode, the WFDB path is restored, as by
[`resetwfdb`](@ref)).

Translation of the C function wfdbquit() (lib/wfdbinit.c, WFDB 10.7.0): same
arguments and results. Differences: the input and output directories are kept
(the WFDB path is restored only in legacy mode); see docs/DIVERGENCES.md.
"""
function wfdbquit(w::Wfdb)
    wfdb_anclose(w)     # close annotation files, reset variables
    wfdb_oinfoclose(w)  # close info file
    wfdb_sigclose(w)    # close signals, reset variables
    # restore the WFDB path (wfdb-x: in legacy mode only; the input directory
    # remains)
    wfdbx_get_legacy(w) != 0 && resetwfdb(w)
    wfdb_sampquit(w)    # release sample data buffer
    wfdb_freeinfo(w)    # release info strings
    nothing
end
wfdbquit() = wfdbquit(lib())

"""
    wfdbflush([w])

C `wfdbflush`: write out buffered output annotations and samples.

Translation of the C function wfdbflush() (lib/wfdbinit.c, WFDB 10.7.0):
same arguments and results.
"""
function wfdbflush(w::Wfdb)
    wfdb_oaflush(w)     # flush buffered output annotations
    wfdb_osflush(w)     # flush buffered output samples
    nothing
end
wfdbflush() = wfdbflush(lib())

export wfdbinit, wfdbquit, wfdbflush
