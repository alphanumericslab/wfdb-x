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

using WFDBX
exit(WFDBX.main_cli(ARGS))
