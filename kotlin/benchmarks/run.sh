#!/bin/sh
# Benchmarks of the Kotlin implementation against C++ and Rust (and the
# Python high-level API, for context), on the same machine, with the
# outputs verified identical. See the "Performance" section of
# kotlin/README.md.
#
#   kotlin/benchmarks/run.sh [WORKDIR]      (default: kotlin/build/bench/work)
#
# It builds the benchmark programs (kotlin/benchmarks/src/Bench.kt,
# cpp/bench.cpp, rust/), the C++ and Rust libraries and tools (in
# kotlin/build/bench), and the Kotlin jars; writes the input record `big`
# (4 signals of 2,000,000 frames in format 16, 16 MB) with the Python
# implementation; then, for each implementation:
#
#   read_record        reads big (all samples, ADC units)
#   write_record       writes the samples read as a new record (fmt 16)
#   write_annotations  writes 200,000 annotations (the same in all)
#   rdsamp             the tool: rdsamp -r big > file (a new process)
#   getvec             isigopen + a getvec loop over the whole record
#
# The library operations report the best of REPS runs (default 5) after
# one untimed run (which lets the JVM compile the code); rdsamp is timed
# as a whole process, best of 3. The outputs are compared: the digests of
# the samples read (FNV-1a), the files written (cmp), and the output of
# rdsamp (cmp). Requirements: java 11+, g++, cmake, cargo, python3 with
# NumPy.
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

set -eu
here=$(cd "$(dirname "$0")" && pwd)
kt=$(dirname "$here")
root=$(dirname "$kt")
build=$kt/build/bench
work=${1:-$build/work}
reps=${REPS:-5}
unset JAVA_TOOL_OPTIONS || true

echo "== building" >&2
(cd "$kt" && ./gradlew -q benchJar fatJar)
cmake -S "$root/cpp" -B "$build/cpp" -DCMAKE_BUILD_TYPE=Release -DWFDBX_BUILD_TESTS=OFF >/dev/null
cmake --build "$build/cpp" -j4 >/dev/null
g++ -O2 -std=c++17 -I"$root/cpp/include" "$here/cpp/bench.cpp" "$build/cpp/libwfdbx.a" -o "$build/cpp-bench"
CARGO_TARGET_DIR=$build/rust cargo build -q --release --manifest-path "$here/rust/Cargo.toml"
CARGO_TARGET_DIR=$build/rust cargo build -q --release --manifest-path "$root/rust/Cargo.toml" --bin rdsamp

KT_BENCH="java -Xmx3g -jar $kt/build/libs/wfdbx-bench.jar"
CPP_BENCH=$build/cpp-bench
RS_BENCH=$build/rust/release/wfdbx-bench
PY_BENCH="python3 $here/bench.py"
export PYTHONPATH=$root/python/src

rm -rf "$work"
mkdir -p "$work/in"
for l in kotlin cpp rust python; do mkdir -p "$work/$l"; done
echo "== input record" >&2
$PY_BENCH gen "$work/in"

run() {  # LANGUAGE COMMAND...: prints "LANGUAGE: output"
    lang=$1
    shift
    echo "$lang: $("$@")"
}

results=$work/results.txt
: > "$results"
for op in read write ann getvec; do
    echo "== $op" >&2
    for l in kotlin cpp rust python; do
        case $l in
            kotlin) b=$KT_BENCH ;;
            cpp) b=$CPP_BENCH ;;
            rust) b=$RS_BENCH ;;
            python) b=$PY_BENCH ;;
        esac
        [ "$l" = python ] && [ "$op" = getvec ] && continue
        case $op in
            read) run $l $b read "$work/in" big "$reps" ;;
            write) run $l $b write "$work/in" big "$work/$l" "$reps" ;;
            ann) run $l $b ann "$work/$l" "$reps" ;;
            getvec) run $l $b getvec "$work/in" big "$reps" ;;
        esac
    done | tee -a "$results" >&2
done

# rdsamp: the whole process, best of 3
now_ms() { date +%s%N | awk '{ printf "%.1f", $1 / 1e6 }'; }
echo "== rdsamp" >&2
for l in kotlin cpp rust; do
    case $l in
        kotlin) cmd="$kt/bin/wfdbx rdsamp" ;;
        cpp) cmd="$build/cpp/bin/rdsamp" ;;
        rust) cmd="$build/rust/release/rdsamp" ;;
    esac
    best=
    for i in 1 2 3; do
        t0=$(now_ms)
        WFDBX_INPUT_DIR=$work/in $cmd -r big > "$work/$l/rdsamp.txt"
        t1=$(now_ms)
        ms=$(echo "$t0 $t1" | awk '{ printf "%.1f", $2 - $1 }')
        best=$(echo "${best:-$ms} $ms" | awk '{ print ($2 < $1) ? $2 : $1 }')
    done
    echo "$l: rdsamp $best ms lines=$(wc -l < "$work/$l/rdsamp.txt")" | tee -a "$results" >&2
done

echo "== verification" >&2
status=0
digests=$(grep -E ": (read_record|getvec) " "$results" | sed 's/.*digest=//' | sort -u | wc -l)
if [ "$digests" = 1 ]; then echo "samples: identical (one digest)"; else echo "samples: DIFFERENT"; status=1; fi
for l in cpp rust python; do
    for f in big.dat big.hea big.bench; do
        if cmp -s "$work/kotlin/$f" "$work/$l/$f"; then :; else echo "$f: kotlin and $l DIFFER"; status=1; fi
    done
done
for l in cpp rust; do
    cmp -s "$work/kotlin/rdsamp.txt" "$work/$l/rdsamp.txt" || { echo "rdsamp output: kotlin and $l DIFFER"; status=1; }
done
[ $status = 0 ] && echo "files written and rdsamp output: byte-identical in all implementations"
echo "results: $results"
exit $status
