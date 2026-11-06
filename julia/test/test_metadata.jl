# Tests of the header metadata functions (read_metadata, get_metadata,
# set_metadata, remove_metadata, update_metadata) and of the metadata of
# read_header and write_record (ported from python/tests/test_metadata.py).
#
# The shared cases (tests/metadata/cases.tsv, with the expected headers in
# tests/metadata/expected/) are run by every implementation of WFDB-x, which
# must give the same results and write byte-identical headers. A URL is
# served by the local HTTP server of test_files.jl (127.0.0.1): no test
# contacts another host.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It tests WFDB-x; it has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

const MD_ROOT = normpath(joinpath(@__DIR__, "..", "..", "tests", "metadata"))
const MD_ENV = ("WFDB", "WFDBX_INPUT_DIR", "WFDBX_OUTPUT_DIR", "WFDBX_NETWORK")

# A string of cases.tsv: "x" and its bytes in hexadecimal, or "-" (none).
md_hex(s::AbstractString) = s == "-" ? nothing : hex2bytes(s[2:end])

# A list of KEY:VALUE pairs of cases.tsv (a value "-" is nothing).
function md_pairs(s::AbstractString)
    isempty(s) && return Pair{Vector{UInt8},Union{Nothing,Vector{UInt8}}}[]
    [(kv = split(p, ':'); md_hex(kv[1]) => md_hex(kv[2])) for p in split(s, ',')]
end

# Run f(w, d) in a new empty directory d (the current directory), with a new
# library state whose settings are the defaults (none of WFDB and the WFDBX_
# variables is set, and the local server is reached without a proxy).
function with_md(f, name)
    d = realpath(tmpdir("md-" * name))
    env = Pair{String,Union{Nothing,String}}[k => nothing for k in MD_ENV]
    push!(env, "no_proxy" => "127.0.0.1,localhost", "NO_PROXY" => "127.0.0.1,localhost")
    try
        withenv(env...) do
            cd(d) do
                f(Wfdb(), d)
            end
        end
    finally
        rm(d; recursive=true, force=true)
    end
end

# Copy the header headers/NAME.hea into directory d; returns the record
# name (the path without .hea).
function md_copy(name, d)
    cp(joinpath(MD_ROOT, "headers", name * ".hea"), joinpath(d, name * ".hea"); force=true)
    joinpath(d, name)
end

# (the value of f() or the class of its error: :argument or :file, the
# number of warnings logged)
function md_run(f)
    logs, v = Test.collect_test_logs() do
        try
            f()
        catch e
            e isa ArgumentError ? :argument : e isa WfdbError ? :file : rethrow()
        end
    end
    (v, count(l -> l.level == Base.CoreLogging.Warn, logs))
end

md_str(p::Pair) = String(copy(p.first)) => String(copy(p.second))
md_str(v::AbstractVector{<:Pair}) = map(md_str, v)

@testset "metadata" begin

if !isdir(MD_ROOT)
    @test_skip "the metadata cases of the WFDB-x repository are not available"
else

@testset "shared cases" begin
    n = 0
    for line in eachline(joinpath(MD_ROOT, "cases.tsv"))
        startswith(line, "#") && continue
        c = split(line, '\t'; keepempty=true)
        @assert length(c) == 10
        name, header, op, key, value, changes, err, nwarn, result, output = c
        n += 1
        with_md(name) do w, d
            rec = md_copy(header, d)
            before = read(rec * ".hea")
            got, warnings = md_run() do
                if op == "read"
                    read_metadata(w, rec)
                elseif op == "get"
                    get_metadata(w, rec, md_hex(key))
                elseif op == "set"
                    set_metadata(w, rec, md_hex(key), md_hex(value))
                elseif op == "remove"
                    remove_metadata(w, rec, md_hex(key))
                else
                    update_metadata(w, rec, md_pairs(changes))
                end
            end
            @testset "$name" begin
                if err != "-"
                    @test got === Symbol(err)
                elseif op == "read"
                    @test got == md_pairs(result)
                elseif op == "get"
                    @test got == md_hex(result)
                elseif op == "remove"
                    @test got == parse(Int, result)
                else
                    @test got === nothing
                end
                @test warnings == parse(Int, nwarn)
                after = read(rec * ".hea")
                if output != "-"
                    @test after == read(joinpath(MD_ROOT, output))
                else
                    @test after == before
                end
                # no temporary file is left behind
                @test readdir(d) == [header * ".hea"]
            end
        end
    end
    @test n == 49
end

@testset "read_header and write_record" begin
    with_md("rw") do w, d
        x = zeros(Int32, 10, 1)
        write_record(w, "w", x, 100; gains=200, adcres=12, units="mV",
                     comments=["a comment", "Site: B"], metadata=["Age" => " 63 ", "Notes" => ""])
        tail = b"#a comment\r\n#Site: B\r\n# Age: 63\r\n# Notes:\r\n"
        data = read("w.hea")
        @test data[end-length(tail)+1:end] == tail
        h = read_header(w, "w")
        @test md_str(h.metadata) == ["Site" => "B", "Age" => "63", "Notes" => ""]
        @test h.metadata isa Vector{MetadataEntry}
        @test String.(h.comments) == ["a comment", "Site: B", " Age: 63", " Notes:"]
        write_record(w, "v", x, 100; gains=200, adcres=12, units="mV",
                     metadata=Dict("Dx" => "426783006"))
        @test md_str(read_metadata(w, "v")) == ["Dx" => "426783006"]
        write_record(w, "t", x, 100; gains=200, adcres=12, units="mV",
                     metadata=[(b"Dx", b"1"), ("Age", "2")])
        @test md_str(read_metadata(w, "t")) == ["Dx" => "1", "Age" => "2"]
        write_record_physical(w, "p", zeros(10, 1), 100; gains=200, adcres=12, units="mV",
                              metadata=["Sex" => "F"])
        @test md_str(read_header(w, "p").metadata) == ["Sex" => "F"]
        # a header without entries; the warning of read_header
        @test md_str((@test_logs read_header(w, "v")).metadata) == ["Dx" => "426783006"]
        write("dup.hea", b"dup", read("v.hea")[2:end], b"#dx: 2\r\n")    # (record dup)
        msg = "header of record dup has more than one entry for key Dx (lines 3, 4); the first is used"
        h = @test_logs (:warn, msg) read_header(w, "dup")
        @test md_str(h.metadata) == ["Dx" => "426783006"]
        # an EDF record (no .hea file): no metadata, and no error
        data = W.workload_data_source()
        if data !== nothing
            cp(joinpath(data, "fmt16.edf"), "fmt16.edf")
            h = @test_logs read_header(w, "fmt16.edf")
            @test h.nsig > 0 && isempty(h.metadata)
            rm("fmt16.edf")
        end
        # the default library
        @test md_str(read_metadata(joinpath(d, "t"))) == ["Dx" => "1", "Age" => "2"]
    end
end

@testset "write_record metadata errors" begin
    with_md("rwerr") do w, d
        x = zeros(Int32, 10, 1)
        for md in (["a:b" => "1"], ["Age" => "1\n2"], ["Age" => "1", "AGE" => "2"],
                   ["Age" => nothing], ["" => "x"], "Age", [1 => "x"], ["Age" => 1],
                   [("Age",)])
            @test_throws WfdbError write_record(w, "e", x, 100; gains=200, adcres=12,
                                                units="mV", metadata=md)
        end
        e = try
            write_record(w, "e", x, 100; gains=200, adcres=12, units="mV",
                         comments=["age: 1"], metadata=["Age" => "2"])
        catch e
            e
        end
        @test e isa WfdbError && e.msg == "write_record: metadata key \"age\" is also given in comments"
        @test_throws WfdbError write_record_physical(w, "e", zeros(10, 1), 100; gains=200,
                                                     adcres=12, units="mV",
                                                     metadata=["a#" => "1"])
        @test isempty(readdir(d))       # nothing was written
    end
end

@testset "info file ignored" begin
    with_md("info") do w, d
        rec = md_copy("lf", d)
        write(rec * ".info", "#Age: 1\n")
        @test isempty(read_metadata(w, rec))
    end
end

@testset "input directory and dir" begin
    with_md("dirs") do w, d
        mkdir("in")
        mkdir("out")
        md_copy("basic", "in")
        original = read("in/basic.hea")
        @test get_metadata(w, "basic", "Sex"; input_dir="in") == b"F"
        @test W.wfdbx_get_input_dir(w) === nothing      # (for the call only)
        W.wfdbx_set_input_dir(w, "in")
        @test get_metadata(w, "basic.hea", "sex") == b"F"
        set_metadata(w, "basic", "Age", "64"; dir="out")
        @test read("in/basic.hea") == original
        @test get_metadata(w, "out/basic", "Age"; input_dir="") == b"64"
        # an unchanged header is still written to dir
        @test remove_metadata(w, "basic", "Weight"; dir="out") == 0
        @test read("out/basic.hea") == original
        @test_throws WfdbError set_metadata(w, "basic", "Age", "1"; dir="none")
        @test read("in/basic.hea") == original
        W.wfdbx_set_input_dir(w, nothing)
        # the header is changed where it was read, not in the output directory
        W.wfdbx_set_output_dir(w, "out")
        set_metadata(w, "in/basic", "Age", "65")
        @test get_metadata(w, "in/basic", "Age") == b"65"
        @test sort(readdir("in")) == ["basic.hea"]
        @test sort(readdir("out")) == ["basic.hea"]
    end
end

@testset "missing and invalid arguments" begin
    with_md("invalid") do w, d
        @test_throws WfdbError read_metadata(w, "none")
        @test_throws WfdbError set_metadata(w, "none", "Age", "1")
        @test_throws ArgumentError read_metadata(w, "")
        @test_throws ArgumentError read_metadata(w, "-")
        @test_throws ArgumentError read_metadata(w, "-.hea")
        md_copy("basic", d)
        original = read("basic.hea")
        @test_throws MethodError set_metadata(w, "basic", "Age", 63)
        @test_throws ArgumentError update_metadata(w, "basic", ["Age" => 63])
        @test_throws ArgumentError update_metadata(w, "basic", "Age")
        @test_throws ArgumentError update_metadata(w, "basic", [("Age", "1", "2")])
        @test_throws ArgumentError get_metadata(w, "basic", "a:b")
        @test read("basic.hea") == original
        # the messages
        msg(f) = try f(); "" catch e; e.msg end
        @test msg(() -> set_metadata(w, "basic", " ", "1")) == "metadata key must not be empty"
        @test msg(() -> set_metadata(w, "basic", "a:b", "1")) ==
              "metadata key \"a:b\" must not contain ':'"
        @test msg(() -> set_metadata(w, "basic", "Age", "1\r\n")) ==
              "value of metadata key \"Age\" must not contain a line break"
        @test msg(() -> set_metadata(w, "basic", "Age", "1\n2")) ==
              "value of metadata key \"Age\" must not contain a line break"
        @test msg(() -> set_metadata(w, "basic", "Age", "1\0")) ==
              "value of metadata key \"Age\" must not contain a NUL character"
        @test msg(() -> update_metadata(w, "basic", ["Age" => "1", "AGE" => nothing])) ==
              "metadata key \"AGE\" is given more than once (keys are compared without regard to letter case)"
        @test msg(() -> read_metadata(w, "none")) == "can't read header for record none"
        @test msg(() -> set_metadata(w, "basic", "Age", "1"; dir="none")) ==
              "directory none does not exist"
        # bytes are kept as given
        set_metadata(w, "basic", b"Name", b"Z\xc3\xbcrich")
        @test get_metadata(w, "basic", "Name") == b"Z\xc3\xbcrich"
        set_metadata(w, "basic", "City", "Zürich")              # (a String: its UTF-8 bytes)
        @test get_metadata(w, "basic", "city") == Vector{UInt8}("Zürich")
        write("norec.hea", "# only a comment\n")
        @test isempty(read_metadata(w, "norec"))
        @test_throws ArgumentError set_metadata(w, "norec", "Age", "1")
        @test read("norec.hea") == b"# only a comment\n"
        @test sort(readdir(d)) == ["basic.hea", "norec.hea"]
    end
end

if !Sys.iswindows()
    @testset "permissions kept" begin
        with_md("perm") do w, d
            rec = md_copy("basic", d)
            chmod(rec * ".hea", 0o640)
            set_metadata(w, rec, "Age", "64")
            @test filemode(rec * ".hea") & 0o7777 == 0o640
            # a new file in dir: the default permissions
            mkdir("new")
            set_metadata(w, rec, "Age", "65"; dir="new")
            @test filemode("new/basic.hea") & 0o777 == 0o666 & ~W._md_umask()
        end
    end
end

@testset "URL" begin
    with_md("url") do w, d
        md_copy("basic", d)
        with_server(d) do srv
            url = srv.url * "basic"
            W.wfdbquiet(w)
            @test_throws WfdbError read_metadata(w, url)             # network off
            @test get_metadata(w, url, "Age"; network=true) == b"63"
            @test W.wfdbx_get_network(w) == 0                        # (for the call only)
            @test_throws ArgumentError set_metadata(w, url, "Age", "1"; network=true)
            mkdir("copy")
            set_metadata(w, url, "Age", "1"; network=true, dir="copy")
            @test get_metadata(w, "copy/basic", "Age") == b"1"
            @test get_metadata(w, "basic", "Age") == b"63"
            @test all(p -> startswith(p, "/basic.hea"), srv.log)
        end
    end
end

end # isdir(MD_ROOT)

end
