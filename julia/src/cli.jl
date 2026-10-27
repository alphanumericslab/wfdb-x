# cli.jl: running the command-line tools: the driver used by bin/wfdbx.jl
# (`main_cli`), and `run_tool`, which runs a tool in-process with its
# standard streams captured (for tests and the precompilation workload).
#
# Each tool is a function `<tool>_main(args::Vector{String})::Integer` (args
# without the program name) defined in src/apps/<tool>.jl.
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

# A tool name: lowercase letters, digits and underscores, not starting with
# an underscore (private functions such as `_run_main` are not tools).
_is_tool_name(name::AbstractString) =
    !isempty(name) && name[1] != '_' &&
    all(c -> ('a' <= c <= 'z') || ('0' <= c <= '9') || c == '_', name)

"""
    tool_function(name) -> Union{Function,Nothing}

Return the main function of the tool `name` (e.g. `rdsamp_main` for
`"rdsamp"`), or `nothing` if there is no such tool. The function takes the
tool's arguments as a `Vector{String}` and returns its exit status.
"""
function tool_function(name::AbstractString)
    _is_tool_name(name) || return nothing
    s = Symbol(name, "_main")
    isdefined(@__MODULE__, s) ? getfield(@__MODULE__, s) : nothing
end

"""
    tools() -> Vector{String}

Return the names of the available command-line tools (`"a2m"`, `"ad2m"`,
..., `"xform"`), sorted.

Part of wfdb-x; not in the original WFDB package.
"""
function tools()
    v = String[]
    for s in names(@__MODULE__; all=true)
        n = String(s)
        endswith(n, "_main") && _is_tool_name(n) && push!(v, n[1:end-5])
    end
    sort!(v)
end

# wfdb-x: the help text of an original tool (printed in legacy mode): the
# lines of `help` except those (indices) that document wfdb-x options.
_help_without(help::Tuple, lines) = Tuple(_help_without(collect(help), lines))
_help_without(help::Vector{String}, lines) = String[help[k] for k in eachindex(help) if !(k in lines)]

# Run a tool's main function: returns its exit status. CExit (C's exit) ends
# it; other exceptions are reported on the standard error (status 1). The
# open files and the standard output are then flushed, as C's exit does.
function _run_main(f, args::Vector{String})
    status = try
        Int32(f(args))
    catch e
        if e isa CExit
            e.status
        else
            cflush()
            msg = try
                sprint(showerror, e)
            catch
                "error"
            end
            cerr_write(string("wfdbx: ", msg, "\n"))
            Int32(1)
        end
    end
    try
        flush_all()
    catch e
        e isa CExit || rethrow()
    end
    status
end

"""
    main_cli(args::Vector{String}) -> Int

The entry point of the command-line driver `bin/wfdbx.jl TOOL ARGS...`:
run the tool `args[1]` with the arguments `args[2:end]`, writing to the
process's standard output and error, and return its exit status. With no
arguments or an unknown tool name, print a message on the standard error
and return 1.

Part of wfdb-x; not in the original WFDB package.
"""
function main_cli(args::Vector{String})
    if isempty(args)
        cerr_write("usage: wfdbx.jl TOOL [ARGUMENTS ...]\n")
        return 1
    end
    f = tool_function(args[1])
    if f === nothing
        cerr_write(string("wfdbx: unknown tool `", args[1], "'\n"))
        return 1
    end
    Int(_run_main(f, args[2:end]))
end

const _WFDB_ENV = ("WFDB", "WFDBCAL", "WFDBANNSORT", "WFDBGVMODE",
                   "WFDBX_INPUT_DIR", "WFDBX_OUTPUT_DIR", "WFDBX_NETWORK")   # (wfdb-x: the last 3)

"""
    run_tool(tool, args; stdin=UInt8[], dir=nothing, env=nothing)
        -> (status::Int32, stdout::Vector{UInt8}, stderr::Vector{UInt8})

Run the command-line tool `tool` (e.g. `"rdsamp"`) with the arguments
`args` (a vector of strings, without the program name) in the current
process, and return its exit status and the bytes it wrote to its standard
output and standard error.

The tool runs as it would in a new process started by `bin/wfdbx.jl`: with
a fresh library state, and the bytes `stdin` as its standard input.

# Keyword arguments
- `stdin`: the standard input of the tool (a `String` or bytes).
- `dir`: the working directory of the tool (default: the current one).
- `env`: environment variables to set while the tool runs, as an iterable
  of `name => value` pairs (e.g. `["WFDB" => "/path/to/data"]`) or a
  `Dict`. The variables `WFDB`, `WFDBCAL`, `WFDBANNSORT` and `WFDBGVMODE`
  are restored afterwards; other variables set this way are not.

The caller's library state ([`lib()`](@ref)) and standard streams are
restored when the tool returns. Throws an `ArgumentError` if there is no
such tool.

# Examples
The example prints the first samples of `100s`, the first minute of record
100 of the MIT-BIH Arrhythmia Database, which is included with wfdb-x in
`tests/data` of a copy of the wfdb-x repository (the tool runs in that
directory, its input directory):
```julia-repl
julia> status, out, err = WFDBX.run_tool("rdsamp", ["-r", "100s", "-t", "s3"]; dir="/path/to/wfdb-x/tests/data");

julia> status
0

julia> first(eachline(IOBuffer(out)))   # sample number, then one column per signal
"              0\\t    995\\t   1011"
```

Part of wfdb-x; not in the original WFDB package.
"""
function run_tool(tool::AbstractString, args::AbstractVector{<:AbstractString};
                  stdin::ByteStr=UInt8[], dir=nothing, env=nothing)
    f = tool_function(tool)
    f === nothing && throw(ArgumentError("unknown tool `$tool'"))
    saved_proc = isassigned(_PROC) ? _PROC[] : nothing
    saved_lib = isassigned(_LIB) ? _LIB[] : nothing
    saved_env = Dict(k => get(ENV, k, nothing) for k in _WFDB_ENV)
    p = CProc()
    p.out_capture = UInt8[]
    p.err_capture = UInt8[]
    p.stdin_mem = Vector{UInt8}(copy(_bv(stdin)))
    _PROC[] = p
    _LIB[] = WfdbLib()
    status = Int32(0)
    try
        if env !== nothing
            for (k, v) in env
                ENV[String(k)] = String(v)
            end
        end
        if dir === nothing
            status = _run_main(f, Vector{String}(args))
        else
            cd(dir) do
                status = _run_main(f, Vector{String}(args))
            end
        end
    finally
        for fl in collect(keys(p.open_files))
            fl isa WfdbFile && _close_fd!(fl)
        end
        for (k, v) in saved_env
            v === nothing ? delete!(ENV, k) : (ENV[k] = v)
        end
        saved_proc === nothing || (_PROC[] = saved_proc)
        saved_lib === nothing || (_LIB[] = saved_lib)
    end
    (status, something(p.out_capture, UInt8[]), something(p.err_capture, UInt8[]))
end
