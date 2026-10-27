# Tests of check_record (ported from python/tests/test_check.py).
#
# The corpus (one broken record for each issue code, a clean record, records
# of tests/data, annotation files) is generated in a temporary directory by
# python/tests/check_corpus.py, which also writes the report that Python
# gives for each case (expected.txt); the reports must be identical. The
# corpus tests are skipped if Python (with NumPy) cannot run that script.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It tests wfdb-x; it has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

const CHECK_ALL_CODES = Set([
    "header_unreadable", "no_signals", "fs_missing", "length_missing",
    "header_line_long", "header_not_ascii", "header_name", "length_large",
    "desc_missing", "desc_number", "desc_control", "format_difference",
    "gain_missing", "gain_negative", "units_missing", "units_control",
    "adcres_missing", "adcres_too_large", "adc_range", "filename",
    "desc_duplicate", "file_unreadable", "file_large", "sample_range",
    "invalid_samples", "checksum", "length_short", "length_long",
    "length_unspecified_frames", "read_error", "nested",
    "segment_unreadable", "segment_fs", "layout_signals", "layout_mismatch",
    "layout_missing_signal", "segment_lengths", "annotator_name",
    "annotations_unreadable", "annotations_truncated", "annotations_order",
    "annotation_code", "annotation_null", "annotation_undefined",
    "annotations_after_end"])

# Generate the corpus in a new directory; returns it, or nothing if the
# generator cannot run.
function make_check_corpus()
    root = normpath(joinpath(@__DIR__, "..", ".."))
    script = joinpath(root, "python", "tests", "check_corpus.py")
    data = joinpath(root, "tests", "data")
    (isfile(script) && isdir(data)) || return nothing
    py = Sys.which("python3")
    py === nothing && return nothing
    d = joinpath(tmpdir("check"), "corpus")
    cmd = setenv(`$py $script $d $data`,
                 merge(ENV, Dict("PYTHONPATH" => joinpath(root, "python", "src"))))
    ok = try
        success(pipeline(cmd; stdout=devnull, stderr=devnull))
    catch
        false
    end
    ok && isfile(joinpath(d, "expected.txt")) ? d : nothing
end

# The report of each case of the corpus, in the format of expected.txt.
function check_corpus_report(w, d)
    out = String[]
    codes = Set{String}()
    for line in eachline(joinpath(d, "cases.txt"))
        f = String.(split(line))
        push!(out, "== " * line)
        r = check_record(w, f[1]; annotators=f[2:end], input_dir=d)
        append!(out, lines(r))
        @test r.record == f[1]
        @test r.ok == !any(i -> i.severity == "error", r.issues)
        @test string(r) == join(lines(r), "\n")
        foreach(i -> push!(codes, i.code), r.issues)
    end
    out, codes
end

@testset "check_record" begin
    @testset "quoting" begin
        @test W._q(b"a\tb\x7f\xe9\"c") == "\"a\\x09b\\x7f\\xe9\"c\""
        @test W._q(nothing) == "\"\""
        @test W._is_number(b"12") && W._is_number(b"-1.5") && W._is_number(b"+.5")
        @test !W._is_number(b"1.2.3") && !W._is_number(b"V5") && !W._is_number(b"-")
    end

    @testset "arguments" begin
        @test_throws ArgumentError check_record("")
        @test_throws ArgumentError check_record("100s"; annotators=[1])
        @test_throws MethodError check_record(nothing)
    end

    @testset "sample record" begin
        data = W.workload_data_source()
        if data === nothing
            @test_skip "no test data"
        else
            w = Wfdb()
            r = check_record(w, "100s"; annotators=["atr"], input_dir=data)
            @test r.ok
            @test lines(r) == ["warning: signal 0: the units are not specified",
                               "warning: signal 1: the units are not specified"]
            # one annotator given as a string
            @test lines(check_record(w, "100s"; annotators="atr", input_dir=data)) == lines(r)
        end
    end

    d = make_check_corpus()
    if d === nothing
        @test_skip "the corpus generator (python3 with NumPy) cannot run"
    else
        @testset "corpus" begin
            w = Wfdb()
            out, codes = check_corpus_report(w, d)
            @test out == readlines(joinpath(d, "expected.txt"))
            # every issue code is produced by the corpus (file_large: below)
            @test setdiff(CHECK_ALL_CODES, codes) == Set(["file_large"])
        end

        @testset "issue fields" begin
            w = Wfdb()
            r = check_record(w, "d_cksum"; input_dir=d)
            @test !r.ok && length(r.issues) == 1
            i = r.issues[1]
            @test (i.severity, i.code, i.where) == ("error", "checksum", "signal 1")
            @test i.message == "the checksum does not match: the header gives 1, the samples sum to 0"
            @test string(i) == "error: signal 1: " * i.message
            @test i == Issue("error", "checksum", "signal 1", i.message)
            r = check_record(w, "clean"; annotators="atr", input_dir=d)
            @test r.ok && isempty(r.issues) && string(r) == "no problems found"
            r = check_record(w, "nolen"; input_dir=d)
            @test r.ok && [i.severity for i in r.issues] == ["warning", "info"]
            @test string(r.issues[1]) == "warning: the record length is not specified"
        end

        @testset "settings restored" begin
            w = Wfdb()
            prev_dir = W.wfdbx_get_input_dir(w)
            W.wfdbx_set_legacy(w, true)
            local r
            err = lib_stderr() do
                r = check_record(w, "nofs"; annotators=["nofile"], input_dir=d)
            end
            @test W.wfdbx_get_legacy(w) == 1
            W.wfdbx_set_legacy(w, false)
            # (legacy mode would assume 250 Hz: the frequency is reported missing)
            @test r.issues[1].code == "fs_missing"
            @test err == ""
            @test W.wfdbx_get_input_dir(w) == prev_dir
            # the library's messages are printed again after the call
            err = lib_stderr(() -> W.isigopen(w, "no_such_record", nothing, 0))
            @test occursin("no_such_record", err)
            W.wfdbquit(w)
            # a library that was quiet stays quiet
            W.wfdbquiet(w)
            check_record(w, "nofs"; input_dir=d)
            @test !w.io.error_print
            W.wfdbverbose(w)
        end

        @testset "modification labels" begin
            # codes 42 and 43 defined by the file's modification labels have
            # a mnemonic (no warning); the definitions do not outlive the check
            w = Wfdb()
            W.setannstr(w, 42, "QQ")
            W.setanndesc(w, 42, "my beat")
            try
                W.write_annotations(w, "clean", "lab",
                                    W.Annotations(samples=[10, 20, 30], codes=Int32[42, 1, 43]);
                                    dir=d)
            finally
                W.setannstr(w, -42, "[42]")
                W.setanndesc(w, -42, nothing)
            end
            w.ann.modified[43] = false
            r = check_record(w, "clean"; annotators=["lab"], input_dir=d)
            @test lines(r) == ["warning: annotator lab: 1 annotation uses a code " *
                               "without a mnemonic: at sample 30 (code 43)"]
            @test W.annstr(w, 42) == b"[42]"
        end

        @testset "file_large" begin
            # (a signal file of more than 2^31 - 1 bytes: its size is simulated)
            w = Wfdb()
            W._CHECK_FILE_SIZE[] = ig -> Int64(1) << 31
            try
                r = check_record(w, "clean"; input_dir=d)
                @test lines(r) == ["warning: the signal file \"clean.dat\" has more than " *
                                   "2147483647 bytes, which 32-bit applications cannot handle"]
            finally
                W._CHECK_FILE_SIZE[] = W._file_size
            end
        end
        rm(dirname(d); recursive=true, force=true)
    end
end
