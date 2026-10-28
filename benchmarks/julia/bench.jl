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
sum64(x) = sum(Int64, x; init=Int64(0))

# Sum of the values that are not NaN, rounded to 3 decimals.
nansum(x) = round(sum(v for v in x if !isnan(v); init=0.0); digits=3)

# Samples, frame by frame (row-major), little-endian.
dump_samples(path, x) = write(path, htol.(permutedims(x)))

# Each annotation: time (int64), code, subtype, chan, num, the length of the
# aux text (int32; -1 if none) and the aux text, little-endian.
function dump_annotations(path, a)
    open(path, "w") do f
        for k in eachindex(a.samples)
            x = a.aux[k]
            write(f, htol(Int64(a.samples[k])), htol(Int32(a.codes[k])),
                  htol(Int32(a.subtypes[k])), htol(Int32(a.chans[k])), htol(Int32(a.nums[k])),
                  htol(Int32(x === nothing ? -1 : length(x))))
            x === nothing || write(f, x)
        end
    end
end

# (run, check, save): run() is the timed call; check and save see its result.
function operation(op::String, out::String)
    if op in ("read_long", "read_mimic", "read_wide")
        rec = op[6:end]
        (() -> read_record(rec).samples, sum64, (x, p) -> dump_samples(p * ".bin", x))
    elseif op == "read_long_phys"
        (() -> physical(read_record("long")), nansum,
         (x, p) -> dump_samples(p * ".bin", x))
    elseif op == "write_long"
        src = read_record("long")
        gains = [s.gain for s in src.siginfo]
        units = [s.units for s in src.siginfo]
        (() -> write_record("out", src.samples, src.fs; fmt=16, gains=gains, adcres=16,
                            units=units, dir=out),
         x -> filesize(joinpath(out, "out.dat")),
         function (x, p)
             cp(joinpath(out, "out.hea"), p * ".hea"; force=true)
             cp(joinpath(out, "out.dat"), p * ".dat"; force=true)
         end)
    elseif op == "read_ann"
        (() -> read_annotations("long", "atr"), length,
         (x, p) -> dump_annotations(p * ".ann", x))
    elseif op == "write_ann"
        ann = read_annotations("long", "atr")
        (() -> write_annotations("out", "atr", Annotations(samples=ann.samples, codes=ann.codes,
                                                           aux=ann.aux); dir=out),
         x -> filesize(joinpath(out, "out.atr")),
         (x, p) -> cp(joinpath(out, "out.atr"), p * ".atr"; force=true))
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
    dump = get(ENV, "WFDBX_BENCH_DUMP", "")
    try
        o = operation(op, out)
        if o === nothing
            println(stderr, "unknown operation ", op)
            return 2
        end
        run, check, save = o
        t = time_ns()
        result = run()
        first = (time_ns() - t) / 1e9
        value = check(result)
        isempty(dump) || save(result, joinpath(dump, op))
        times = Float64[]
        for _ in 1:reps
            t = time_ns()
            run()
            push!(times, (time_ns() - t) / 1e9)
        end
        println("{\"op\": \"", op, "\", \"first\": ", first, ", \"best\": ", minimum(times),
                ", \"times\": [", join(string.(times), ", "), "], \"check\": ", value, "}")
    finally
        rm(out; recursive=true, force=true)
    end
    0
end

exit(main(ARGS))
