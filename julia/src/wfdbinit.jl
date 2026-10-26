# wfdbinit.jl: wfdbinit, wfdbquit, wfdbflush (port of lib/wfdbinit.c).
#
# Copyright (C) 1983-2012 George B. Moody (original C implementation,
# lib/wfdbinit.c; revised 2012-2019 by Benjamin Moody).
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

"""
    wfdbinit([w], record, aiarray, nann, siarray, nsig) -> Int32

C `wfdbinit`: open the annotation files (`annopen`) and then the input
signals (`isigopen`) of `record`. Returns the status of `annopen` if it
failed, otherwise that of `isigopen`.
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
are (wfdb-x; in legacy mode, the WFDB path is restored, as by
[`resetwfdb`](@ref)).
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
"""
function wfdbflush(w::Wfdb)
    wfdb_oaflush(w)     # flush buffered output annotations
    wfdb_osflush(w)     # flush buffered output samples
    nothing
end
wfdbflush() = wfdbflush(lib())

export wfdbinit, wfdbquit, wfdbflush
