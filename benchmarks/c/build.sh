#!/bin/sh
# build.sh: build the benchmark driver of the original C WFDB library.
#
# Usage: benchmarks/c/build.sh OUTPUT_DIRECTORY
#
# Builds the unmodified WFDB Software Package 10.7.0 (third_party/
# wfdb-main.zip) with its own configure script and compiler options, as a
# user would install it (tests/reference/build_reference.sh with
# WFDBX_ORIGINAL=1; it needs libFLAC, or FLAC_PREFIX), into
# OUTPUT_DIRECTORY/wfdb, once; then compiles bench.c against that library as
# OUTPUT_DIRECTORY/wfdb_c_bench.  The tools of that build
# (OUTPUT_DIRECTORY/wfdb/bin) are the C tools that run.py times.
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
set -e
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
if [ ! -f "$OUT/wfdb/lib/libwfdb.a" ]; then
    WFDBX_ORIGINAL=1 sh "$ROOT/tests/reference/build_reference.sh" \
        "$OUT/wfdb" >"$OUT/build.log" 2>&1 || {
        tail -5 "$OUT/build.log" >&2
        exit 1
    }
fi
cc -O2 -o "$OUT/wfdb_c_bench" "$HERE/bench.c" -I"$OUT/wfdb/include" \
    -L"$OUT/wfdb/lib" -lwfdb ${FLAC_PREFIX:+-L$FLAC_PREFIX/lib} -lFLAC -lm
