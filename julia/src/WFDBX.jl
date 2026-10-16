# WFDBX.jl: wfdb-x for Julia, a reimplementation of the WFDB Software
# Package (version 10.7.0) that reads and writes exactly the same files as
# the original C library, and whose command-line tools produce
# byte-identical output (verified by the conformance suite of wfdb-x).
#
# The C code it ports was written by George B. Moody and others: see
# docs/AUTHORS.md for the authors of each part.
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

"""
    WFDBX

The Julia implementation of wfdb-x: a reimplementation of the WFDB Software
Package 10.7.0 (PhysioNet's library and tools for physiologic signals and
annotations). It reads and writes the same files as the C library.

The package provides:

* A high-level API that reads or writes a whole record or annotation file
  in one call: [`read_header`](@ref), [`read_record`](@ref),
  [`read_annotations`](@ref), [`write_record`](@ref),
  [`write_record_physical`](@ref), [`write_annotations`](@ref). These
  functions throw a [`WfdbError`](@ref) on failure.
* The C library API, with the C function names and arguments
  ([`isigopen`](@ref), [`getvec`](@ref), [`annopen`](@ref),
  [`getann`](@ref), ...). These functions return C status codes. The
  library state is a [`Wfdb`](@ref) object, which every function takes as
  an optional first argument (by default, the instance returned by
  [`lib`](@ref)).
* The WFDB command-line tools (`rdsamp`, `rdann`, `wrsamp`, ...): see
  [`tools`](@ref), [`run_tool`](@ref), and the driver script
  `bin/wfdbx.jl`. Their output is identical to that of the C programs.

Records are found in the directories of the WFDB path (see
[`setwfdb`](@ref); by default it is taken from the environment variable
`WFDB`). Text read from WFDB files is returned as bytes
(`Vector{UInt8}`); string arguments may be `String`s or byte vectors.

# Examples

```julia-repl
julia> using WFDBX

julia> setwfdb("/path/to/data");    # directory holding 100s.hea, 100s.dat, 100s.atr

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

# The command-line tools: every src/apps/*.jl file defines <tool>_main.
include("cli.jl")
const _APPS_DIR = joinpath(@__DIR__, "apps")
include_dependency(_APPS_DIR)
for _f in sort(readdir(_APPS_DIR))
    endswith(_f, ".jl") && include(joinpath("apps", _f))
end

export Wfdb, WfdbLib, lib, WfdbFile
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
