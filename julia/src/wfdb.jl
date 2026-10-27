# wfdb.jl: the library object (`WfdbLib`, the concrete `Wfdb`), which holds
# all the state of the C library, and the default instance used by the
# C-named functions called without a `Wfdb` argument.
#
# Organization: each C library function is a Julia function with the C name
# whose first argument is a `w::Wfdb`, defined in the file that translates
# the corresponding C source file; the state of each C source file is a
# field of `WfdbLib` whose type is defined in that file:
#
# | field  | type       | file        |
# |--------|------------|-------------|
# | `io`   | `IoState`  | wfdbio.jl   |
# | `sig`  | `SigState` | signal.jl   |
# | `ann`  | `AnnState` | annot.jl    |
# | `cal`  | `CalState` | calib.jl    |
# | `maps` | `EcgMaps`  | ecgcodes.jl |
#
# Every function also has a method without the `Wfdb` argument that uses the
# default instance `lib()`: `getwfdb() = getwfdb(lib())`.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

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

Part of WFDB-x; not in the original WFDB package.
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

Part of WFDB-x; not in the original WFDB package.
"""
@inline lib() = _LIB[]

_reset_lib!() = (_LIB[] = WfdbLib(); nothing)
