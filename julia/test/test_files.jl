# Tests of finding files (wfdb-x): the input directory, the output
# directory, network access, files named in headers, and legacy mode (ported
# from python/tests/test_files.py).
#
# Remote files are served by a local HTTP server (127.0.0.1, written below
# with the Sockets standard library): no test contacts another host.
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

using Sockets

const SR_HEA = "sr 2 360 21600\n" *
               "sr.dat 212 200 11 1024 995 21537 0 MLII\n" *
               "sr.dat 212 200 11 1024 1011 -3962 0 V5\n"
const NET_OFF = "wfdb-x: network access is disabled; set WFDBX_NETWORK=1 or call wfdbx_set_network(1) to open "
const WFDB_IGNORED = "wfdb-x: the WFDB environment variable is ignored; set WFDBX_INPUT_DIR instead (or use legacy mode)\n"
const FILES_ENV = ("WFDB", "WFDBX_INPUT_DIR", "WFDBX_OUTPUT_DIR", "WFDBX_NETWORK")

putfile(name, data) = (mkpath(dirname(abspath(name))); write(name, data))

# Record sr (a copy of 100s) in directory d.
function make_sr(d)
    putfile(joinpath(d, "sr.hea"), SR_HEA)
    cp("100s.dat", joinpath(d, "sr.dat"); force=true)
    cp("100s.atr", joinpath(d, "sr.atr"); force=true)
end

b(x) = Vector{UInt8}(x)
sv(x) = x === nothing ? nothing : String(copy(x))

# Run f(w, cwd) in a fresh copy of tests/data (the current directory), with a
# new library state whose settings are the defaults: none of WFDB and the
# WFDBX_ variables is set, HOME is the subdirectory home, and the local
# server is reached without a proxy.
function with_files(f, name)
    data = W.workload_data_source()
    data === nothing && return @test_skip "no test data"
    d = realpath(tmpdir("files-" * name))
    for x in readdir(data)
        p = joinpath(data, x)
        isfile(p) && cp(p, joinpath(d, x))
    end
    mkdir(joinpath(d, "home"))
    env = Pair{String,Union{Nothing,String}}[k => nothing for k in FILES_ENV]
    push!(env, "HOME" => joinpath(d, "home"), "no_proxy" => "127.0.0.1,localhost",
          "NO_PROXY" => "127.0.0.1,localhost")
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

# The library's error output while f() runs (as capture_stderr in
# test_annotations.jl, which is included after this file).
function errors_of(f)
    p = W.cproc()
    p.err_capture = UInt8[]
    try
        f()
        return String(copy(p.err_capture))
    finally
        p.err_capture = nothing
    end
end

# A minimal HTTP server for directory dir on 127.0.0.1 (HTTP/1.0, one
# request per connection), logging the requested paths; /redirect/X
# redirects to /www/X.
mutable struct TestServer
    listener::Sockets.TCPServer
    url::String
    log::Vector{String}
end

function _serve(sock, dir, log)
    try
        line = readline(sock)
        while true
            h = readline(sock)
            isempty(h) && break
        end
        path = String(split(line)[2])
        push!(log, path)
        if startswith(path, "/redirect/")
            write(sock, "HTTP/1.0 302 Found\r\nLocation: /www/$(path[11:end])\r\n" *
                        "Content-Length: 0\r\n\r\n")
        else
            p = joinpath(dir, path[2:end])
            if !occursin("..", path) && isfile(p)
                data = read(p)
                write(sock, "HTTP/1.0 200 OK\r\nContent-Length: $(length(data))\r\n\r\n")
                write(sock, data)
            else
                write(sock, "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            end
        end
    catch
    finally
        close(sock)
    end
end

function TestServer(dir)
    port, listener = listenany(ip"127.0.0.1", 18000)
    srv = TestServer(listener, "http://127.0.0.1:$(Int(port))/", String[])
    @async while isopen(listener)
        sock = try
            accept(listener)
        catch
            break
        end
        @async _serve(sock, dir, srv.log)
    end
    srv
end

with_server(f, dir) = (srv = TestServer(dir); try f(srv) finally close(srv.listener) end)

@testset "files" begin

# ---------------------------------------------------------------------------
# Settings

@testset "settings: defaults and previous values" begin
    with_files("settings") do w, _
        @test W.wfdbx_get_input_dir(w) === nothing
        @test W.wfdbx_get_output_dir(w) === nothing
        @test W.wfdbx_get_network(w) == 0
        @test W.wfdbx_set_input_dir(w, "a") === nothing
        @test W.wfdbx_set_input_dir(w, "b") == b"a"
        @test W.wfdbx_set_input_dir(w, "") == b"b"
        @test W.wfdbx_get_input_dir(w) === nothing
        @test W.wfdbx_set_output_dir(w, "o") === nothing
        @test W.wfdbx_set_output_dir(w, nothing) == b"o"
        @test W.wfdbx_set_network(w, 1) == 0
        @test W.wfdbx_set_network(w, true) == 1
        @test W.wfdbx_set_network(w, 0) == 1
        @test W.wfdbx_set_network(w, nothing) == 0
        @test W.wfdbx_set_network(w, -1) == 0
        @test W.wfdbx_get_network(w) == 0
        # (an output directory URL is refused: the current value is returned)
        W.wfdbx_set_output_dir(w, "o")
        W.wfdbquiet(w)
        @test W.wfdbx_set_output_dir(w, "http://127.0.0.1:1/") == b"o"
        @test W.wfdberror(w) == b"wfdbx_set_output_dir: the output directory must be a local directory\n"
        @test W.wfdbx_get_output_dir(w) == b"o"
        # the settings survive wfdbquit, and belong to the library state
        W.wfdbx_set_input_dir(w, "a")
        W.wfdbx_set_network(w, true)
        W.wfdbquit(w)
        @test (W.wfdbx_get_input_dir(w), W.wfdbx_get_output_dir(w), W.wfdbx_get_network(w)) ==
              (b"a", b"o", 1)
        @test W.wfdbx_get_input_dir(Wfdb()) === nothing
    end
end

@testset "settings: environment" begin
    with_files("env") do _, _
        withenv("WFDBX_INPUT_DIR" => "in", "WFDBX_OUTPUT_DIR" => "out", "WFDBX_NETWORK" => "1") do
            w = Wfdb()      # (the variables are read when first needed)
            @test (W.wfdbx_get_input_dir(w), W.wfdbx_get_output_dir(w), W.wfdbx_get_network(w)) ==
                  (b"in", b"out", 1)
            @test (W.wfdbx_set_input_dir(w, "x"), W.wfdbx_set_input_dir(w, nothing)) == (b"in", b"x")
            @test (W.wfdbx_set_output_dir(w, "y"), W.wfdbx_set_output_dir(w, "")) == (b"out", b"y")
            @test (W.wfdbx_set_network(w, 0), W.wfdbx_set_network(w, -1)) == (1, 0)
            @test (W.wfdbx_get_input_dir(w), W.wfdbx_get_output_dir(w), W.wfdbx_get_network(w)) ==
                  (b"in", b"out", 1)
            # (later changes of the environment are not seen)
            ENV["WFDBX_INPUT_DIR"] = "changed"
            @test W.wfdbx_get_input_dir(w) == b"in"
        end
        # strtol(value) != 0
        for (value, on) in (("0", 0), ("", 0), ("x", 0), (" 2", 1), ("-1", 1), ("0x1", 0),
                            ("1abc", 1))
            withenv("WFDBX_NETWORK" => value) do
                @test W.wfdbx_get_network(Wfdb()) == on
            end
        end
        withenv("WFDBX_INPUT_DIR" => "") do
            @test W.wfdbx_get_input_dir(Wfdb()) === nothing
        end
        withenv("WFDBX_OUTPUT_DIR" => "http://127.0.0.1:1/") do
            w = Wfdb()
            @test errors_of(() -> @test W.wfdbx_get_output_dir(w) === nothing) ==
                  "wfdbx_set_output_dir: the output directory must be a local directory\n"
        end
    end
end

@testset "setwfdb, getwfdb, resetwfdb" begin
    with_files("setwfdb") do w, _
        W.wfdbquiet(w)
        @test W.getwfdb(w) == b"."
        for (p, d) in (("sub", "sub"), ("  sub  ", "sub"), (";sub;", "sub"),
                       ("http://h:80/a", "http://h:80/a"), ("~/x", "~/x"), ("@file", "@file"),
                       ("%r", "%r"), ("", nothing), (";", nothing), (nothing, nothing))
            W.setwfdb(w, "old")
            W.setwfdb(w, p)
            @test sv(W.wfdbx_get_input_dir(w)) == d
            @test String(W.getwfdb(w)) == something(d, ".")
        end
        W.setwfdb(w, "keep")
        for p in ("a b", "a;b", "a:b", ". http://h/x", "http://h/x:/y")
            W.setwfdb(w, p)
            @test W.wfdbx_get_input_dir(w) == b"keep"
            @test startswith(String(W.wfdberror(w)), "setwfdb: wfdb-x reads from a single input directory; use wfdbx_set_input_dir")
        end
        # resetwfdb restores the setting of the last setwfdb; wfdbquit does
        # not call it
        W.wfdbx_set_input_dir(w, "other")
        W.wfdbquit(w)
        @test W.wfdbx_get_input_dir(w) == b"other"
        W.resetwfdb(w)
        @test W.wfdbx_get_input_dir(w) == b"keep"
        # (setwfdb does not export WFDB in normal mode)
        @test W.cgetenv("WFDB") === nothing
    end
end

@testset "the WFDB variable is ignored" begin
    with_files("wfdbvar") do _, cwd
        make_sr("sub")
        withenv("WFDB" => "sub") do
            w = Wfdb()
            err = errors_of() do
                @test W.isigopen(w, "100s", nothing, 2) == 2
                W.wfdbquit(w)
                @test W.isigopen(w, "100s", nothing, 2) == 2
                W.wfdbquit(w)
            end
            @test err == WFDB_IGNORED       # (once)
            w = Wfdb()
            @test errors_of(() -> @test W.isigopen(w, "sr", nothing, 2) == -1) ==
                  WFDB_IGNORED * "init: can't open header for record sr\n"
            # not needed for an absolute name; not printed in legacy mode,
            # where WFDB is the path
            w = Wfdb()
            @test errors_of(() -> @test W.isigopen(w, joinpath(cwd, "100s"), nothing, 2) == 2) == ""
            w = Wfdb()
            W.wfdbx_set_legacy(w, true)
            @test errors_of(() -> @test W.isigopen(w, "sr", nothing, 2) == 2) == ""
        end
        withenv("WFDB" => "") do
            w = Wfdb()
            @test errors_of(() -> @test W.getwfdb(w) == b".") == ""
        end
    end
end

# ---------------------------------------------------------------------------
# Names

@testset "names" begin
    with_files("names") do w, cwd
        make_sr("sub")
        make_sr("home/hr")
        mkpath("sub/deeper")
        f(t, r) = sv(W.wfdbfile(w, t, r))
        @test f("hea", "100s") == "100s.hea"
        @test f("hea", "sub/sr") == "sub/sr.hea"
        @test f("hea", "sub/deeper/../sr") == "sub/deeper/../sr.hea"      # ('..' allowed)
        @test f("hea", "sub/../100s") == "sub/../100s.hea"
        @test f("hea", cwd * "/sub/sr") == cwd * "/sub/sr.hea"
        @test f("hea", "~/hr/sr") == cwd * "/home/hr/sr.hea"
        @test f("hea", "~nosuchuser-wfdbx/hr/sr") === nothing
        @test f("hea", "sr") === nothing                    # nothing is searched
        W.wfdbx_set_input_dir(w, "sub")
        @test f("hea", "sr") == "sub/sr.hea"
        @test f("hea", "100s") === nothing                  # nothing is searched
        @test f("hea", "../100s") == "sub/../100s.hea"
        @test f("hea", cwd * "/100s") == cwd * "/100s.hea"
        W.wfdbx_set_input_dir(w, "sub/")
        @test f("hea", "sr") == "sub/sr.hea"                # (one separator)
        W.wfdbx_set_input_dir(w, cwd * "/sub")
        @test f("hea", "sr") == cwd * "/sub/sr.hea"
        W.wfdbx_set_input_dir(w, "~/hr")
        @test f("hea", "sr") == cwd * "/home/hr/sr.hea"
        W.wfdbx_set_input_dir(w, "~")
        @test f("hea", "hr/sr") == cwd * "/home/hr/sr.hea"
        W.wfdbx_set_input_dir(w, ".")
        @test f("hea", "100s") == "./100s.hea"
        # (the trailing '/' expansion and the 8.3 form are kept)
        W.wfdbx_set_input_dir(w, nothing)
        mkpath("sr")
        cp("sub/sr.hea", "sr/sr.hea")
        @test f("hea", "sr/") == "sr/sr.hea"
        putfile("sub/x.abc", "")
        @test f("abcdef", "sub/x") == "sub/x.abc"
        # (a URL input directory, without a final '/', needs the network)
        W.wfdbx_set_input_dir(w, "http://127.0.0.1:1/d")
        W.wfdbquiet(w)
        @test f("hea", "100s") === nothing
        @test W.wfdberror(w) == b(NET_OFF * "http://127.0.0.1:1/d/100s.hea\n")
    end
end

@testset "~ expansion" begin
    e(x) = String(W._expand_home(b(x)))
    withenv("HOME" => "/h/") do
        @test (e("~"), e("~/a"), e("a~"), e("x")) == ("/h", "/h/a", "a~", "x")
    end
    withenv("HOME" => "") do
        @test e("~/a") == "/a"
        @test e("~") == "/"
    end
    if Sys.isunix()
        pw = Base.Libc.getpwuid(Base.Libc.getuid())
        @test e("~" * pw.username * "/a") == rstrip(pw.homedir, '/') * "/a"
        @test e("~nosuchuser-wfdbx/a") == "~nosuchuser-wfdbx/a"
        withenv("HOME" => nothing) do
            @test e("~/a") == rstrip(pw.homedir, '/') * "/a"
        end
    end
end

@testset "output names" begin
    with_files("outnames") do w, cwd
        a = Annotation(time=0, anntyp=W.NORMAL % Int8)
        function wr(record, name="x")
            st = W.annopen(w, record, [Anninfo(name, WFDB_WRITE)], 1)
            st == 0 && W.putann(w, 0, a)
            W.wfdbquit(w)
            st
        end
        W.wfdbx_set_output_dir(w, "out")
        @test wr("r") == 0 && isfile("out/r.x")
        @test wr("sub/r") == 0 && isfile("out/sub/r.x")
        @test wr("../up") == 0 && isfile("up.x")
        @test wr(cwd * "/abs") == 0 && isfile("abs.x")
        @test wr("~/hm") == 0 && isfile("home/hm.x")
        W.wfdbx_set_output_dir(w, "~/o2")
        @test wr("r") == 0 && isfile("home/o2/r.x")
        W.wfdbx_set_output_dir(w, "out/")
        @test wr("r", "y") == 0 && isfile("out/r.y")
        W.wfdbx_set_output_dir(w, nothing)
        W.wfdbquiet(w)
        @test wr("http://127.0.0.1:1/r") == -4
        # legacy mode: any name in the output directory (as in round 1)
        W.wfdbx_set_legacy(w, true)
        W.wfdbx_set_output_dir(w, "lout")
        @test wr(cwd * "/labs") == 0
        @test isfile("lout" * cwd * "/labs.x")
    end
end

# ---------------------------------------------------------------------------
# Files named in headers

@testset "header-relative files" begin
    with_files("hdr") do w, _
        make_sr("sub")
        putfile("sub/dd.hea", "dd 1 360 10\ndata/a.dat 16\n")
        cp("fmt16.dat", "sub/a.dat")
        mkpath("sub/data")
        cp("fmt16.dat", "sub/data/a.dat")
        # sr.dat is next to sub/sr.hea (not in the current directory)
        rec = W.read_record(w, "sub/sr"; to=2)
        @test rec.samples == Int32[995 1011; 995 1011]
        @test rec.siginfo[1].fname == b"sr.dat"     # (as written in the header)
        @test W.read_record(w, "sub/dd"; to=2).samples == reshape(Int32[-7, 32], 2, 1)
        # a header naming a file that is not next to it: nothing is searched
        putfile("sub/sib.hea", "sib 1 360 10\n100s.dat 212\n")
        W.wfdbquiet(w)
        @test_throws W.WfdbError W.read_record(w, "sub/sib")
        # legacy mode: the WFDB path is searched (here, "." first)
        @test size(W.read_record(w, "sub/sib"; legacy=true).samples, 1) > 0
    end
end

@testset "header containment" begin
    with_files("contain") do w, _
        cp("fmt16.dat", "ok.dat")
        mkpath("sub")
        cp("fmt16.dat", "sub/ok.dat")
        W.wfdbquiet(w)
        for name in ("../100s.dat", "/100s.dat", "~/100s.dat", "~", "http://127.0.0.1:1/a.dat",
                     "https://127.0.0.1:1/a.dat", "data/../../100s.dat", "..", "a/../b.dat")
            putfile("sub/bad.hea", "bad 2 360 10\n$name 16\nok.dat 16\n")
            @test W.isigopen(w, "sub/bad", nothing, 2) == 1    # (the second file opens)
            @test String(W.wfdberror(w)) ==
                  "init: file $name named in the header of record sub/bad is not in the header's directory\n"
            W.wfdbquit(w)
        end
        # ".." within a name, "./x"
        mkpath("sub/a..b")
        putfile("sub/ok.hea", "ok 3 360 10\nx..y.dat 16\na..b/c.dat 16\n./d.dat 16\n")
        for n in ("x..y.dat", "a..b/c.dat", "d.dat")
            cp("fmt16.dat", "sub/" * n)
        end
        @test W.isigopen(w, "sub/ok", nothing, 3) == 3
        W.wfdbquit(w)
    end
end

@testset "segments" begin
    with_files("segs") do w, _
        putfile("sub/dd.hea", "dd 1 360 10\ndata/a.dat 16 200 12 0 0 0 0 s\n")
        mkpath("sub/data")
        cp("fmt16.dat", "sub/data/a.dat")
        mkpath("sub/seg")
        putfile("sub/seg/dd.hea", "dd 1 360 10\nx.dat 16 200 12 0 0 0 0 s\n")
        cp("fmt16.dat", "sub/seg/x.dat")
        # a null segment (~), a layout header, and a segment in a subdirectory
        putfile("sub/ms.hea", "ms/4 1 360 30\nms_0 0\n~ 10\ndd 10\nseg/dd 10\n")
        putfile("sub/ms_0.hea", "ms_0 1 360 0\n~ 0 200 12 0 0 0 0 s\n")
        dd = W.read_record(w, "sub/dd"; to=9).samples[:, 1]
        @test W.read_record(w, "sub/ms"; to=19).samples[:, 1] == [fill(Int32(-32768), 10); dd]
        @test W.read_record(w, "sub/ms"; from=20, to=29).samples[:, 1] == dd   # (seg/dd)
        # segments outside the directory are refused
        W.wfdbquiet(w)
        for seg in ("../sub/dd", "/x", "~/dd", "http://127.0.0.1:1/dd")
            putfile("sub/ms2.hea", "ms2/2 1 360 20\ndd 10\n$seg 10\n")
            @test W.isigopen(w, "sub/ms2", nothing, 1) == 1
            @test W.isigsettime(w, 10) == -1
            W.wfdbquit(w)
        end
        # setmsheader: the segment names are given by the caller (resolved as
        # any name)
        W.wfdbverbose(w)
        @test W.setmsheader(w, "msw", ["sub/dd", "sub/seg/dd"], 2) == 0
        W.wfdbquit(w)
        @test split(read("msw.hea", String), "\r\n")[2:3] == ["sub/dd 10", "sub/seg/dd 10"]
    end
end

# ---------------------------------------------------------------------------
# Network access

@testset "network off" begin
    with_files("netoff") do w, cwd
        with_server(cwd) do srv
            W.wfdbquiet(w)
            @test W.isigopen(w, srv.url * "100s", nothing, 2) == -1
            @test String(W.wfdberror(w)) == "init: can't open header for record $(srv.url)100s\n"
            @test isempty(srv.log)
            w = Wfdb()
            err = errors_of() do
                W.wfdbfile(w, "hea", srv.url * "100s")
                W.wfdbfile(w, "atr", srv.url * "100s")
            end
            @test err == NET_OFF * srv.url * "100s.hea\n"      # (once)
            @test isempty(srv.log)
        end
    end
end

@testset "network on" begin
    with_files("neton") do w, cwd
        with_server(cwd) do srv
            W.wfdbx_set_network(w, true)
            rec = W.read_record(w, srv.url * "100s"; to=3)
            @test rec.samples == repeat(Int32[995 1011], 3)
            @test length(W.read_annotations(w, srv.url * "100s", "atr")) == 75
            # each URL is requested once
            @test allunique(srv.log)
            @test issubset(["/100s.hea", "/100s.dat", "/100s.atr"], srv.log)
            n = length(srv.log)
            W.wfdbx_set_input_dir(w, srv.url)
            @test W.read_record(w, "100s"; to=1).samples == Int32[995 1011]
            @test length(srv.log) == n          # (cached)
            @test W.wfdbfile(w, "hea", "100s") == b(srv.url * "100s.hea")
            W.wfdbx_set_input_dir(w, srv.url[1:end-1])     # (without the final '/')
            @test W.wfdbfile(w, "hea", "100s") == b(srv.url * "100s.hea")
        end
    end
end

@testset "network: subdirectories and errors" begin
    with_files("netsub") do w, cwd
        with_server(cwd) do srv
            mkpath("www/data")
            putfile("www/rec.hea", "rec 1 360 10\ndata/a.dat 16\n")
            cp("fmt16.dat", "www/data/a.dat")
            putfile("www/nodat.hea", "nodat 1 360 10\nnodat.dat 16\n")
            putfile("www/bad.hea", "bad 1 360 10\n../100s.dat 16\n")
            make_sr("www")
            W.wfdbx_set_network(w, true)
            W.wfdbx_set_input_dir(w, srv.url * "www")
            @test W.read_record(w, "rec"; to=2).samples == reshape(Int32[-7, 32], 2, 1)
            @test "/www/data/a.dat" in srv.log
            W.wfdbquiet(w)
            @test_throws W.WfdbError W.read_record(w, "nodat")
            @test_throws W.WfdbError W.read_record(w, "nosuch")    # 404
            @test_throws W.WfdbError W.read_record(w, "bad")
            @test startswith(String(W.wfdberror(w)), "isigopen: none of the signals")
            n = length(srv.log)
            @test_throws W.WfdbError W.read_record(w, "nosuch")    # (the failure is cached)
            @test length(srv.log) == n
            @test !("/100s.dat" in srv.log) && !("/www/../100s.dat" in srv.log)
            # redirects are followed (the header's directory is that of its URL)
            W.wfdbx_set_input_dir(w, nothing)
            @test W.read_record(w, srv.url * "redirect/sr"; to=1).samples == Int32[995 1011]
            # a URL cannot be written; an output directory URL is refused
            @test W.annopen(w, srv.url * "x", [Anninfo("a", WFDB_WRITE)], 1) == -4
            @test W.wfdbx_set_output_dir(w, srv.url) === nothing
        end
    end
end

@testset "network: legacy mode" begin
    # legacy mode reads no remote files (as the reference C build), even
    # with network access on; URL path entries are not opened either
    with_files("netleg") do w, cwd
        with_server(cwd) do srv
            W.wfdbx_set_network(w, true)
            W.wfdbx_set_legacy(w, true)
            W.wfdbquiet(w)
            @test W.isigopen(w, srv.url * "100s", nothing, 2) == -1
            W.setwfdb(w, srv.url)
            @test W.isigopen(w, "100s", nothing, 2) == -1
            W.setwfdb(w, ".")
            @test isempty(srv.log)
        end
    end
end

# ---------------------------------------------------------------------------
# The high-level options

@testset "high-level input_dir and network" begin
    with_files("hl") do w, cwd
        with_server(cwd) do srv
            make_sr("sub")
            W.wfdbx_set_input_dir(w, "elsewhere")
            @test length(W.read_header(w, "sr"; input_dir="sub").siginfo) == 2
            rec = W.read_record(w, "100s"; input_dir=srv.url, network=true, to=1)
            @test rec.samples == Int32[995 1011]
            @test length(W.read_annotations(w, "sr", "atr"; input_dir="sub")) == 75
            @test W.wfdbx_get_input_dir(w) == b"elsewhere"     # restored
            @test W.wfdbx_get_network(w) == 0
            # also on errors
            W.wfdbquiet(w)
            @test_throws W.WfdbError W.read_record(w, "nosuch"; input_dir="sub", network=true)
            @test (W.wfdbx_get_input_dir(w), W.wfdbx_get_network(w)) == (b"elsewhere", 0)
            # network=false forbids it for the call; nothing keeps the setting
            W.wfdbx_set_network(w, true)
            @test_throws W.WfdbError W.read_header(w, srv.url * "100s"; network=false)
            @test W.wfdbx_get_network(w) == 1
            @test length(W.read_header(w, srv.url * "100s").siginfo) == 2
            # the output directory (dir=) and the input directory are
            # independent
            W.write_annotations(w, "w1", "q", W.Annotations(samples=[1, 2], symbols=[b"N", b"N"]);
                                dir="sub")
            @test isfile("sub/w1.q")
            @test length(W.read_annotations(w, "w1", "q"; input_dir="sub", fs=100)) == 2
        end
    end
end

@testset "legacy mode unchanged" begin
    with_files("legacy") do w, _
        make_sr("sub")
        W.wfdbquiet(w)
        W.wfdbx_set_legacy(w, true)
        W.wfdbx_set_input_dir(w, "sub")         # (not used in legacy mode)
        @test W.isigopen(w, "sr", nothing, 2) == -1
        W.setwfdb(w, "sub .")                   # the WFDB path
        @test W.isigopen(w, "sr", nothing, 2) == 2
        @test W.wfdbfile(w, "atr", "sr") == b"sub/sr.atr"
        @test W.getwfdb(w) == b"sub ."
        @test W.isigopen(w, "sub/../100s", nothing, 2) == -1   # ".." refused
        @test W.wfdbfile(w, "hea", "~/x") === nothing
        W.setwfdb(w, ".")
    end
end


# wfdb-x: only the last component of a record name is checked when writing
# (outside legacy mode), and headers name the record, its signal files and
# its segments relative to the header's directory.
@testset "record names with dotted directories" begin
    with_files("names") do w, cwd
        x = Int32[1 2; 3 4; 5 6]
        wr(rec; kw...) = W.write_record(w, rec, x, 100.0; gains=[200.0], adcres=12,
                                        units="mV", names=["a", "b"], kw...)
        mkpath("my.data")
        wr("my.data/rec")
        @test readlines("my.data/rec.hea")[1:2] == ["rec 2 100 3", "rec.dat 16 200/mV 12 0 1 9 0 a"]
        @test W.read_record(w, "my.data/rec").samples == x
        abs = joinpath(cwd, "my.data", "sub.d", "abs")
        mkpath(dirname(abs))
        wr(abs)
        @test readlines(abs * ".hea")[1] == "abs 2 100 3"
        @test W.read_record(w, abs).samples == x
        # newheader with a dotted directory
        @test W.osigfopen(w, [W.Siginfo(fname=b"my.data/nh.dat", fmt=16, gain=200.0,
                                        adcres=12, units=b"mV", desc=b"a")], 1) == 1
        @test W.putvec(w, Int32[7]) == 1
        @test W.newheader(w, "my.data/nh") == 0
        W.wfdbquit(w)
        h = readlines("my.data/nh.hea")
        @test split(h[1])[1] == "nh" && h[2] == "nh.dat 16 200/mV 12 0 7 7 0 a"
        # setmsheader: the segments are named relative to the directory
        wr("my.data/s1")
        wr("my.data/s2")
        @test W.setmsheader(w, "my.data/ms", ["my.data/s1", "my.data/s2"], 2) == 0
        W.wfdbquit(w)
        @test readlines("my.data/ms.hea") == ["ms/2 2 100 6", "s1 3", "s2 3"]
        @test W.read_record(w, "my.data/ms").samples == [x; x]
        # the last component is checked, with the same message
        err = errors_of() do
            @test_throws W.WfdbError wr("rec.1")
        end
        @test startswith(err, "init: illegal character 46 in record name\n")
        err = errors_of() do
            @test_throws W.WfdbError wr("my.data/")
        end
        @test startswith(err, "init: illegal character 0 in record name\n")
        # legacy mode: the whole name is checked, and names are written as given
        err = errors_of() do
            @test_throws W.WfdbError wr("my.data/r2"; legacy=true)
        end
        @test startswith(err, "init: illegal character 46 in record name\n")
        mkpath("out")
        wr("out/rec"; legacy=true)
        @test readlines("out/rec.hea")[1:2] == ["out/rec 2 100 3", "out/rec.dat 16 200/mV 12 0 1 9 0 a"]
        # annotator names are checked as before
        W.wfdbquiet(w)
        @test_throws W.WfdbError W.write_annotations(w, "my.data/rec", "a.b",
                                                     W.Annotations(samples=[1], symbols=[b"N"]))
        W.wfdbverbose(w)
    end
end

end
