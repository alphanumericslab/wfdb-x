# WFDBX.jl: wfdb-x for Julia, a reimplementation of the WFDB Software
# Package (version 10.7.0) that reads and writes exactly the same files as
# the original C library, and whose command-line tools produce
# byte-identical output (verified by the conformance suite of wfdb-x). This
# file defines the module and includes the other files.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package. The authors of the C code
# that the other files translate are credited in each file and in
# docs/AUTHORS.md.
#
# Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

"""
    WFDBX

Read and write physiological signal records in the WFDB format used by
PhysioNet. `WFDBX` is a complete Julia implementation of the WFDB Software
Package 10.7.0: the library and all of its command-line tools. It reads and
writes the same files as the original C library, and its tools print the
same output.

You can use it in three ways:

* High-level functions that read and write whole records and annotation
  files: [`read_record`](@ref), [`read_header`](@ref),
  [`read_annotations`](@ref), [`write_record`](@ref),
  [`write_record_physical`](@ref), [`write_annotations`](@ref). They throw
  a [`WfdbError`](@ref) when an operation fails. [`check_record`](@ref)
  checks a record and its annotation files and reports every problem.
* Command-line tools such as `rdsamp`, `rdann` and `wrsamp`, run through
  the driver script `bin/wfdbx.jl`. [`WFDBX.tools`](@ref) lists them, and
  [`WFDBX.run_tool`](@ref) runs one inside a Julia session.
* The WFDB library functions under their C names ([`isigopen`](@ref),
  [`getvec`](@ref), [`annopen`](@ref), [`getann`](@ref), ...). They return
  status codes, as in C. Each takes an optional [`Wfdb`](@ref) object as
  its first argument, which holds the library state. Without it, the
  default object [`lib`](@ref)`()` is used.

Files named by a relative name are read from the input directory and
written to the output directory. Both are the current directory unless you
set them with [`wfdbx_set_input_dir`](@ref) and
[`wfdbx_set_output_dir`](@ref). A full path, a `~` path or a URL is used as
given. Reading a URL needs network access ([`wfdbx_set_network`](@ref)).
Text read from WFDB files is returned as bytes (`Vector{UInt8}`).

# Examples
The examples read `100s`, the first minute of record 100 of the MIT-BIH
Arrhythmia Database, which is included with wfdb-x in `tests/data` of a copy
of the wfdb-x repository:
```julia-repl
julia> using WFDBX

julia> wfdbx_set_input_dir("/path/to/wfdb-x/tests/data");   # holds the sample record 100s

julia> rec = read_record("100s"; to="0:10");   # the first 10 seconds

julia> size(rec.samples), rec.fs
((3600, 2), 360.0)

julia> ann = read_annotations("100s", "atr");

julia> String.(ann.symbols[1:3])
3-element Vector{String}:
 "+"
 "N"
 "N"
```
"""
module WFDBX

# C standard library emulation, types and constants.
include("cstd.jl")
include("types.jl")
include("precompile.jl")    # workload registry (the workloads run at the end)

# The library (one file per C source file; see wfdb.jl).
include("ecgcodes.jl")
include("wfdbio.jl")
include("flac.jl")          # (used by signal.jl)
include("signal.jl")
include("annot.jl")
include("calib.jl")
include("wfdbinit.jl")
include("wfdb.jl")          # WfdbLib: assembles the states of the files above
include("highlevel.jl")
include("check.jl")          # check_record

# The command-line tools: every src/apps/*.jl file defines <tool>_main.
include("cli.jl")
const _APPS_DIR = joinpath(@__DIR__, "apps")
include_dependency(_APPS_DIR)
for _f in sort(readdir(_APPS_DIR))
    endswith(_f, ".jl") && include(joinpath("apps", _f))
end

export Wfdb, WfdbLib, lib, WfdbFile
export check_record, CheckReport, Issue, lines
export Siginfo, Calinfo, Anninfo, Annotation, Seginfo
export WFDB_READ, WFDB_WRITE, WFDB_AHA_READ, WFDB_AHA_WRITE, WFDB_APPEND
export WFDB_LOWRES, WFDB_HIGHRES, WFDB_GVPAD, WFDB_INVALID_SAMPLE
export WFDB_MAXANN, WFDB_MAXSIG, WFDB_MAXSPF, WFDB_MAXRNL, WFDB_MAXUSL, WFDB_MAXDSL
export WFDB_DEFFREQ, WFDB_DEFGAIN, WFDB_DEFRES
export WFDB_AC_COUPLED, WFDB_DC_COUPLED, WFDB_CAL_SQUARE, WFDB_CAL_SINE,
       WFDB_CAL_SAWTOOTH, WFDB_CAL_UNDEF
export getwfdb, setwfdb, resetwfdb, wfdbquiet, wfdbverbose, wfdberror, wfdbfile,
       wfdbmemerr, wfdbversion, wfdbldflags, wfdbcflags, wfdbdefwfdb, wfdbdefwfdbcal
export isigopen
export isann, isqrs, setisqrs, map1, setmap1, map2, setmap2, ammap, mamap, annpos, setannpos

function __init__()
    _reset_cproc!()
    _reset_lib!()
end

if ccall(:jl_generating_output, Cint, ()) == 1
    _run_workloads()
end

end # module
