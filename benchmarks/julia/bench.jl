# bench.jl: benchmark driver for the Julia implementation of WFDB-x.
#
#     julia --startup-file=no --project=julia benchmarks/julia/bench.jl OP DATADIR REPS
#
# See benchmarks/README.md for the operations and the output (one JSON line).
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

using WFDBX

# Sum of the samples as a 64-bit integer.
sum64(rec) = sum(Int64, rec.samples; init=Int64(0))

# Sum of the values that are not NaN, rounded to 3 decimals.
nansum(x) = round(sum(v for v in x if !isnan(v); init=0.0); digits=3)

function operation(op::String, out::String)
    if op == "read_long"
        () -> sum64(read_record("long"))
    elseif op == "read_long_phys"
        () -> nansum(physical(read_record("long")))
    elseif op == "read_mimic"
        () -> sum64(read_record("mimic"))
    elseif op == "read_wide"
        () -> sum64(read_record("wide"))
    elseif op == "write_long"
        src = read_record("long")
        gains = [s.gain for s in src.siginfo]
        units = [s.units for s in src.siginfo]
        function ()
            write_record("out", src.samples, src.fs; fmt=16, gains=gains, adcres=16,
                         units=units, dir=out)
            filesize(joinpath(out, "out.dat"))
        end
    elseif op == "read_ann"
        () -> length(read_annotations("long", "atr"))
    elseif op == "write_ann"
        ann = read_annotations("long", "atr")
        function ()
            write_annotations("out", "atr", Annotations(samples=ann.samples, codes=ann.codes,
                                                        aux=ann.aux); dir=out)
            filesize(joinpath(out, "out.atr"))
        end
    else
        nothing
    end
end

function main(args::Vector{String})
    if length(args) != 3
        println(stderr, "usage: bench.jl OP DATADIR REPS")
        return 2
    end
    op, d, reps = args[1], args[2], parse(Int, args[3])
    wfdbx_set_input_dir(d)
    out = mktempdir(; prefix="wfdbx-bench-", cleanup=false)
    try
        run = operation(op, out)
        if run === nothing
            println(stderr, "unknown operation ", op)
            return 2
        end
        t = time_ns()
        check = run()
        first = (time_ns() - t) / 1e9
        times = Float64[]
        for _ in 1:reps
            t = time_ns()
            run()
            push!(times, (time_ns() - t) / 1e9)
        end
        println("{\"op\": \"", op, "\", \"first\": ", first, ", \"best\": ", minimum(times),
                ", \"times\": [", join(string.(times), ", "), "], \"check\": ", check, "}")
    finally
        rm(out; recursive=true, force=true)
    end
    0
end

exit(main(ARGS))
