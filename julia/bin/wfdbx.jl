# wfdbx.jl: command-line driver of wfdb-x for Julia.
#
#     julia --startup-file=no --project=/path/to/wfdb-x/julia \
#         /path/to/wfdb-x/julia/bin/wfdbx.jl TOOL [ARGUMENTS ...]
#
# runs the WFDB tool TOOL (e.g. rdsamp) with the given arguments and exits
# with its status.
#
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

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
