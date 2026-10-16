# wfdb.jl: the library object (`WfdbLib`, the concrete `Wfdb`), which holds
# all the state of the C library, and the default instance used by the
# C-named functions called without a `Wfdb` argument.
#
# Organization: each C library function is a Julia function with the C name
# whose first argument is a `w::Wfdb`, defined in the file that ports the
# corresponding C source file; the state of each C source file is a field of
# `WfdbLib` whose type is defined in that file:
#
# | field  | type       | file        |
# |--------|------------|-------------|
# | `io`   | `IoState`  | wfdbio.jl   |
# | `sig`  | `SigState` | signal.jl   |
# | `ann`  | `AnnState` | annot.jl    |
# | `cal`  | `CalState` | calib.jl    |
# | `maps` | `EcgMaps`  | ecgcodes.jl |
#
# Every function also has a method without the `Wfdb` argument that uses
# the default instance `lib()`: `getwfdb() = getwfdb(lib())`.
#
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

"""
    WfdbLib <: Wfdb

The concrete type of the library state (see [`Wfdb`](@ref)). Create one
with `Wfdb()`; its fields are internal.
"""
mutable struct WfdbLib <: Wfdb
    io::IoState
    sig::SigState
    ann::AnnState
    cal::CalState
    maps::EcgMaps
end

WfdbLib() = WfdbLib(IoState(), SigState(), AnnState(), CalState(), EcgMaps())

"""
    Wfdb() -> WfdbLib

Create a new, independent library state, as at the start of a C program.
"""
Wfdb() = WfdbLib()

const _LIB = Ref{WfdbLib}()

"""
    lib() -> Wfdb

Return the default library state: the one used by the C-style functions
when they are called without a `Wfdb` argument (the equivalent of the C
library's global variables). It is created when the package is loaded.
While a tool runs in-process with [`run_tool`](@ref), `lib()` is a fresh
instance, and the previous one is restored afterwards.
"""
@inline lib() = _LIB[]

_reset_lib!() = (_LIB[] = WfdbLib(); nothing)
