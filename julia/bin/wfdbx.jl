# wfdbx.jl: command-line driver of wfdb-x for Julia.
#
#     julia --startup-file=no --project=/path/to/wfdb-x/julia \
#         /path/to/wfdb-x/julia/bin/wfdbx.jl TOOL [ARGUMENTS ...]
#
# runs the WFDB tool TOOL (e.g. rdsamp) with the given arguments and exits
# with its status.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

# wfdb-x: Julia finds its package depot (with the compiled package) through
# HOME. HOME may have been changed to give `~` names another meaning (the
# conformance suite does): the depot of the user's own home directory (from
# the password database) is then used, so that the package is not compiled
# again under the new HOME. (JULIA_DEPOT_PATH, if set, is used as given.)
if !haskey(ENV, "JULIA_DEPOT_PATH") && Sys.isunix() && !isempty(DEPOT_PATH)
    let home = try Base.Libc.getpwuid(Base.Libc.getuid()).homedir catch; "" end
        if !isempty(home) && home != homedir() && DEPOT_PATH[1] == joinpath(homedir(), ".julia")
            DEPOT_PATH[1] = joinpath(home, ".julia")
        end
    end
end

using WFDBX
exit(WFDBX.main_cli(ARGS))
