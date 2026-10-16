# precompile.jl: the precompilation workload.
#
# Every conformance case (and every use of a tool) starts a new Julia
# process, so the package must load from its precompiled image without
# compiling anything at run time. When the package is precompiled, the
# workloads registered here are run (in-process, with captured output, in
# temporary directories), so that the native code of everything they
# exercise is cached in the package image.
#
# Each library file or tool registers its own workload:
#
#     register_workload("rdsamp") do
#         with_workload_data() do dir
#             workload_tool("rdsamp", "-r", "100s", "-t", "1")
#             workload_tool("rdsamp", "-r", "100s", "-p", "-v")
#         end
#     end
#
# Keep workloads short (they run at every precompilation) but cover the
# code paths (each tool option, signal format, annotation path, ...):
# anything not exercised is compiled when it is first used, which costs
# startup time in every process.
#
# Julia implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

const _WORKLOADS = Pair{String,Function}[]

"""
    register_workload(f, name)

Register a precompilation workload (a function of no arguments).
"""
register_workload(f::Function, name::AbstractString) = (push!(_WORKLOADS, String(name) => f); nothing)

"The test data of the repository (tests/data), or `nothing` if not found."
function workload_data_source()
    d = normpath(joinpath(@__DIR__, "..", "..", "tests", "data"))
    isdir(d) ? d : nothing
end

"""
    with_workload_data(f; files=Dict())

Run `f(dir)` with `dir` (also the current directory) a temporary directory
holding a copy of the repository's test data (`tests/data`, if available)
and the given extra `files` (name => contents).
"""
function with_workload_data(f::Function; files=Dict{String,Any}())
    mktempdir() do dir
        src = workload_data_source()
        if src !== nothing
            for name in readdir(src)
                p = joinpath(src, name)
                isfile(p) && cp(p, joinpath(dir, name))
            end
        end
        for (name, content) in files
            path = joinpath(dir, name)
            mkpath(dirname(path))
            write(path, content)
        end
        cd(() -> f(dir), dir)
    end
end

"""
    NODEFAULTS_FILES

Extra workload files (for [`with_workload_data`](@ref)) for the wfdb-x
paths without a default sampling frequency, gain, ADC resolution or units
(see `docs/DIVERGENCES.md`): `nf`, a header without a sampling frequency,
`uc`, a record whose signals are uncalibrated (gain 0), and `nr`, a header
without ADC resolutions or units, as in the conformance cases. (Copy `100s.atr` to `nh.atr` for an annotation file
without a header.)
"""
const NODEFAULTS_FILES = Dict{String,Any}(
    "nf.hea" => "nf 2\n100s.dat 212 200 11 1024 995 21537 0 MLII\n" *
                "100s.dat 212 200 11 1024 1011 -3962 0 V5\n",
    "uc.hea" => "uc 2 360 21600\n100s.dat 212 0 11 1024 995 21537 0 MLII\n" *
                "100s.dat 212 0 11 1024 1011 -3962 0 V5\n",
    "nr.hea" => "nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n")

"""
    workload_tool(tool, args...; stdin="", env=("WFDB" => ".",))

Run a tool in-process (see [`run_tool`](@ref)) for a workload, with the
environment variable `WFDB` set to `.` unless `env` says otherwise.
"""
function workload_tool(tool::AbstractString, args::AbstractString...; stdin::ByteStr=UInt8[],
                       env=("WFDB" => ".",))
    run_tool(tool, String[a for a in args]; stdin=stdin, env=env)
end

# The core workload: C standard library emulation and the CLI driver.
register_workload("cstd") do
    for fmt in ("%d %5d %-5d %05d %ld %u %x %lu\n", "%s|%10s|%-3s|%.2s\n",
                "%g %.12g %f %.3f %e %10.4f %c%%\n")
        cformat(fmt, Int32(42), -7, Int64(1) << 40, UInt8(3), 0.1, "ab", b"cd", 1.5e300, 65)
    end
    cformat("%d", Int32(1)); cformat("%d", 1); cformat("%ld", Int64(1)); cformat("%s", "x")
    cformat("%s", UInt8[0x41]); cformat("%g", 1.5); cformat("%.3f", 1.5); cformat("%s %s", "a", "b")
    cformat("%5.3f", 0.25); cformat("%s\n", nothing); cformat("%u", UInt32(7))
    cformat("%c", UInt8('x')); cformat("%c", 'x'); cformat("%d", true)
    strtol("12x", 10); strtod("1.5e3"); strtod(b"0x1p3"); atoi("42"); atof(" 2.5")
    a, b, c = Ref{Int32}(0), Ref{Float64}(0.0), UInt8[]
    csscanf("1 2.5 x", "%d%lf%s", a, b, c)
    i64 = Ref{Int64}(0)
    csscanf("12", "%ld", i64)
    t = Strtok("a b")
    strtok(t, " "); strtok(t, " ")
    collect(fgets_lines("a\nb", 10))
    crand(); csrand(1)
end

function _run_workloads()
    _reset_cproc!()
    _reset_lib!()
    for (name, f) in _WORKLOADS
        try
            f()
        catch e
            @warn "WFDBX: precompilation workload `$name' failed" exception = (e, catch_backtrace())
        end
    end
    # The CLI driver itself.
    precompile(main_cli, (Vector{String},))
    precompile(tool_function, (String,))
    precompile(_run_main, (Function, Vector{String}))
    _reset_cproc!()
    _reset_lib!()
    nothing
end
