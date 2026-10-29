# Tests of the signal functions (signal.jl) and of the high-level API
# (highlevel.jl): ported from rust/tests/signals.rs (expected values
# produced by the C library).
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

# Run f(w) in a fresh copy of tests/data (the current directory), with a
# library instance whose WFDB path is ".".
function with_data(f)
    data = W.workload_data_source()
    data === nothing && return @test_skip "no test data"
    d = tmpdir("sig")
    for name in readdir(data)
        p = joinpath(data, name)
        isfile(p) && cp(p, joinpath(d, name))
    end
    w = Wfdb()
    W.setwfdb(w, ".")
    keeping_wfdb_env() do
        cd(d) do
            try
                f(w)
            finally
                W.wfdbquit(w)
            end
        end
    end
    rm(d; recursive=true, force=true)
end

isig(w, rec) = W.isigopen(w, rec, nothing, 8)

# The message of the WfdbError thrown by f() (nothing if none).
hlerr(f) = try
    f()
    nothing
catch e
    e isa W.WfdbError || rethrow()
    e.msg
end

# getvec / getframe: the status followed by n samples.
function vec_(w, n)
    v = zeros(Int32, n + 8)
    st = W.getvec(w, v)
    Int32[st; v[1:n]]
end
function frame_(w, n)
    v = zeros(Int32, n + 8)
    st = W.getframe(w, v)
    Int32[st; v[1:n]]
end

function segs(w)
    r = Ref{Union{Nothing,Vector{Seginfo}}}(nothing)
    n = W.getseginfo(w, r)
    s = something(r[], Seginfo[])
    ["$(String(copy(s[i].recname))) $(s[i].nsamp) $(s[i].samp0)" for i in 1:max(n, 0)]
end

unhex(h) = (d = filter(!=(' '), h); UInt8[parse(UInt8, d[i:i+1]; base=16) for i in 1:2:length(d)])

# Is the FLAC codec available (flac.jl)?
function flac_available()
    data = W.workload_data_source()
    data === nothing && return false
    d = W.flac_decode(read(joinpath(data, "flac16.dat")), 3, 16)
    d.status == W.FLAC_OK
end

@testset "signals" begin

@testset "interval strings" begin
    with_data() do w
        @test W.isigopen(w, "100s", nothing, 0) == 2
        @test W.strtim(w, "1:0") == 21600
        @test W.timstr(w, 21600) == "    1:00"
        @test W.mstimstr(w, 1234) == "    0:03.428"
        @test W.strtim(w, "s7") == 7
        @test W.strtim(w, "e") == 21600
    end
end

@testset "absolute times" begin
    with_data() do w
        W.isigopen(w, "fmt16", nothing, 0)
        @test W.timstr(w, 0) == "[12:34:56 31/12/1999]"
        @test W.strtim(w, "[12:35:00]") == -803
        @test W.mstimstr(w, -2500) == "[12:35:06.789 31/12/1999]"
    end
end

@testset "dates" begin
    w = Wfdb()
    for s in ("01/01/2000", "29/02/2000", "15/10/1582", "31/12/1999")
        @test W.datstr(w, W.strdat(w, s)) == " " * s
    end
    @test W.datstr(w, W.strdat(w, "29/02/1900")) == " 01/03/1900"
    @test W.strdat(w, "bogus") == 0
end

@testset "counter and base time" begin
    with_data() do w
        isig(w, "100s")
        @test W.getcfreq(w) == 360.0
        @test W.getbasecount(w) == 0.0
        W.setcfreq(w, 1000.0)
        W.setbasecount(w, 500.5)
        @test W.getcfreq(w) == 1000.0
        @test W.getbasecount(w) == 500.5
        @test W.strtim(w, "c1500.5") == 360
        @test W.strtim(w, "c500.5") == 0
        W.setcfreq(w, 0.0)
        @test W.getcfreq(w) == 360.0
        @test W.setbasetime(w, "10:20:30 15/6/2001") == 0
        @test W.timstr(w, 0) == "[10:20:30 15/06/2001]"
        @test W.timstr(w, 360) == "    0:01"
        @test W.timstr(w, -360) == "[10:20:31 15/06/2001]"
        @test W.mstimstr(w, -1000) == "[10:20:32.778 15/06/2001]"
        @test W.setbasetime(w, "8:00") == 0
        @test W.timstr(w, 0) == "[00:08:00]"
        @test W.timstr(w, -720) == "[00:08:02]"
        W.wfdbquiet(w)
        @test W.setbasetime(w, "garbage") == -1
        W.wfdbverbose(w)
        W.setcfreq(w, 500.0)
        W.wfdbquit(w)
        @test W.getcfreq(w) == 500.0
    end
end

@testset "errors" begin
    with_data() do w
        W.wfdbquiet(w)
        @test isig(w, "nosuch") == -1
        @test W.wfdberror(w) == b"init: can't open header for record nosuch\n"
    end
end

@testset "buffer sizes" begin
    with_data() do w
        W.wfdbquiet(w)
        @test W.setibsize(w, 0) == 8192
        @test W.setibsize(w, 1000) == 1000
        @test W.setibsize(w, -1) == -2
        @test W.setobsize(w, 0) == 8192
        @test W.setobsize(w, 2000) == 2000
        @test W.setobsize(w, -5) == -2
        isig(w, "100s")
        @test W.setibsize(w, 512) == -1
    end
end

@testset "getvec modes and frequencies" begin
    with_data() do w
        @test W.getgvmode(w) == 0
        @test isig(w, "100s") == 2
        @test W.getifreq(w) == 360.0
        @test W.getspf(w) == 1
        W.wfdbquit(w)
        isig(w, "fmt16")
        @test vec_(w, 3) == [3, -7, 32, -33]
        @test vec_(w, 3) == [3, 4, 53, -47]
        @test vec_(w, 3) == [3, -20, 24, -27]
        @test W.setifreq(w, 100.0) == 0
        @test W.getifreq(w) == 100.0
        @test W.isigsettime(w, 0) == 0
        @test vec_(w, 3) == [3, -7, 32, -33]
        @test vec_(w, 3) == [3, -21, 23, -35]
        @test vec_(w, 3) == [3, 7, -14, -44]
        @test W.setifreq(w, 1000.0) == 0
        @test W.getifreq(w) == 1000.0
        @test W.isigsettime(w, 2) == 0
        @test vec_(w, 3) == [3, -7, 32, -33]
        for _ in 1:4
            @test vec_(w, 3) == [3, 4, 53, -47]
        end
        W.wfdbquiet(w)
        @test W.setifreq(w, -1.0) == -1
        W.wfdbverbose(w)
        @test W.getifreq(w) == 250.0
        W.wfdbquit(w)
        isig(w, "100s")
        W.setgvmode(w, WFDB_HIGHRES)
        @test W.getgvmode(w) == 1
        W.setgvmode(w, WFDB_GVPAD | WFDB_LOWRES)
        @test W.getgvmode(w) == 2
        W.setgvmode(w, WFDB_HIGHRES | WFDB_GVPAD | 4)
        @test W.getgvmode(w) == 3
        W.setgvmode(w, 0)
    end
end

@testset "amplitude conversion" begin
    with_data() do w
        isig(w, "100s")     # gain 200, baseline 1024
        @test W.adumuv(w, 0, 200) == 1000
        @test W.adumuv(w, 0, -37) == -185
        @test W.adumuv(w, 1, 1) == 5
        @test W.adumuv(w, 0, -1) == -5
        W.wfdbquiet(w)
        @test W.adumuv(w, 7, 100) == WFDB_INVALID_SAMPLE   # WFDB-x: no default gain
        @test W.muvadu(w, 0, 1000) == 200
        @test W.muvadu(w, 0, -333) == -67
        @test W.muvadu(w, 1, 2) == 0
        @test W.muvadu(w, 9, 1000) == WFDB_INVALID_SAMPLE
        @test W.aduphys(w, 0, 1224) == 1.0
        @test W.aduphys(w, 1, 900) == -0.62
        @test isnan(W.aduphys(w, 5, 300))
        @test W.physadu(w, 0, 1.0) == 1224
        @test W.physadu(w, 1, -0.5023) == 924
        @test W.physadu(w, 5, 1.5) == WFDB_INVALID_SAMPLE
        W.wfdbverbose(w)
        W.wfdbquit(w)
        isig(w, "fmt16")    # 100(-5)/mV, 150(5)/uV, 200(15)/mmHg
        @test W.adumuv(w, 0, 100) == 1000
        @test W.adumuv(w, 1, 150) == 1000
        @test W.adumuv(w, 2, -7) == -35
        @test W.muvadu(w, 0, 1000) == 100
        @test W.muvadu(w, 1, 1000) == 150
        @test W.muvadu(w, 2, -2500) == -500
        @test W.aduphys(w, 0, 95) == 1.0
        @test W.aduphys(w, 1, 10) == 0.033333333333333333
        @test W.aduphys(w, 2, -3) == -0.089999999999999997
        @test W.physadu(w, 0, 1.0) == 95
        @test W.physadu(w, 1, -2.25) == -333
        @test W.physadu(w, 2, 0.4) == 95
    end
end

@testset "sample random access" begin
    with_data() do w
        isig(w, "100s")
        @test W.sample_valid(w) == 0
        @test W.sample(w, 0, 0) == 995
        @test W.sample_valid(w) == 1
        @test W.sample(w, 1, 1000) == 970
        @test W.sample_valid(w) == 1
        @test W.sample(w, 0, 21599) == 975
        @test W.sample_valid(w) == 1
        @test W.sample(w, 0, 21600) == 975
        @test W.sample_valid(w) == 0
        @test W.sample(w, 0, 5) == 995
        @test W.sample_valid(w) == 1
        @test W.sample(w, 1, -3) == 1011
        @test W.sample_valid(w) == 1
        @test W.sample(w, 2, 0) == -32768
        @test W.sample_valid(w) == -1
    end
end

@testset "getframe multifrequency" begin
    with_data() do w
        isig(w, "mfreq")    # 1, 2 and 4 samples per frame
        @test W.getspf(w) == 1
        @test W.getifreq(w) == 100.0
        @test frame_(w, 7) == [3, 138, 218, 2699, 219, -1316, 1120, 1973]
        @test frame_(w, 7) == [3, 2677, 1201, 275, -989, 1822, 2762, 1927]
        @test vec_(w, 3) == [3, -597, -455, 181]
        W.isigsettime(w, 599)
        @test frame_(w, 7) == [3, -1394, 715, 558, 2215, -1785, 860, -491]
        @test frame_(w, 7)[1] == -1
        W.wfdbquit(w)
        W.setgvmode(w, WFDB_HIGHRES)
        isig(w, "mfreq")
        @test W.getspf(w) == 4
        @test W.getifreq(w) == 400.0
        @test frame_(w, 7) == [3, 138, 218, 2699, 219, -1316, 1120, 1973]
        @test vec_(w, 3) == [3, 2677, 1201, -989]
        @test vec_(w, 3) == [3, 2677, 1201, 1822]
        W.wfdbquit(w)
        W.setgvmode(w, 0)
    end
end

@testset "isgsettime groups" begin
    with_data() do w
        isig(w, "twog")     # group 0: signal 0; group 1: signals 1 and 2
        @test vec_(w, 3) == [3, 1020, 977, 316]
        @test W.isgsettime(w, 1, 100) == 0
        @test vec_(w, 3) == [3, 1880, -630, 83]
        @test vec_(w, 3) == [3, 325, 245, 1597]
        @test W.isgsettime(w, 0, 500) == 0
        @test vec_(w, 3) == [3, -1823, 338, -709]
        @test W.isgsettime(w, 1, 1001) == 0
        @test vec_(w, 3)[1] == -1
    end
end

@testset "tnextvec getseginfo" begin
    with_data() do w
        isig(w, "100s")
        @test isempty(segs(w))
        @test W.tnextvec(w, 0, 5) == 5
        @test W.tnextvec(w, 1, 0) == 0
        W.wfdbquit(w)
        isig(w, "multi")
        @test segs(w) == ["100s 21600 0", "null 1800 21600", "100s 21600 23400"]
        @test W.tnextvec(w, 0, 0) == 0
        @test W.tnextvec(w, 0, 21599) == 21599
        @test W.tnextvec(w, 1, 21700) == 23500
        @test W.tnextvec(w, 0, 44999) == 44999
        @test W.tnextvec(w, 0, 45000) == -1
        W.wfdbquit(w)
        isig(w, "vlay")
        @test segs(w) == ["vlay_0 0 0", "fmt16 1500 0", "~ 200 1500", "fmt212 1501 1700"]
        W.wfdbquiet(w)
        @test W.tnextvec(w, 0, 0) == 0
        @test W.tnextvec(w, 1, 1499) == 1700
        @test W.tnextvec(w, 2, 1500) == -1
        @test W.tnextvec(w, 0, 1600) == -1
        @test W.tnextvec(w, 5, 0) == -1
        W.wfdbverbose(w)
    end
end

@testset "skew and start" begin
    with_data() do w
        isig(w, "skew")
        @test W.wfdbgetskew(w, 0) == 0
        @test W.wfdbgetskew(w, 1) == 3
        @test W.wfdbgetskew(w, 2) == 7
        @test W.wfdbgetskew(w, 3) == 0
        @test vec_(w, 3) == [3, -7, 21, -32768]
        W.wfdbsetiskew(w, 1, 2)
        W.wfdbsetiskew(w, 2, 100000)    # too large: ignored
        W.wfdbsetiskew(w, 0, -1)        # negative: ignored
        @test W.wfdbgetskew(w, 0) == 0
        @test W.wfdbgetskew(w, 1) == 2
        @test W.wfdbgetskew(w, 2) == 7
        W.wfdbquit(w)
        isig(w, "prolog")
        @test W.wfdbgetstart(w, 0) == 100
        @test W.wfdbgetstart(w, 2) == 100
        @test W.wfdbgetstart(w, 3) == 0
        W.wfdbquit(w)
        isig(w, "100s")
        @test W.wfdbgetstart(w, 0) == 0
    end
end

@testset "getframe deskew" begin
    with_data() do w
        isig(w, "skew")
        @test frame_(w, 3) == [3, -7, 21, -32768]
        @test frame_(w, 3) == [3, 4, -14, -85]
        W.isigsettime(w, 1497)
        @test frame_(w, 3) == [-1, -32755, 16705, -32768]
        @test frame_(w, 3) == [-1, -32751, -14, 16705]
    end
end

@testset "uncalibrated signals" begin
    with_data() do w
        isig(w, "null")     # gain 0 (WFDB-x: no default gain)
        W.wfdbquiet(w)
        @test W.adumuv(w, 0, 100) == WFDB_INVALID_SAMPLE
        @test W.muvadu(w, 1, 100) == WFDB_INVALID_SAMPLE
        @test isnan(W.aduphys(w, 0, 100))
        @test W.physadu(w, 1, 0.5) == WFDB_INVALID_SAMPLE
        W.wfdbverbose(w)
        @test vec_(w, 2) == [2, -32768, -32768]
    end
end

@testset "multifrequency resampling" begin
    with_data() do w
        isig(w, "mfreq")
        @test W.setifreq(w, 200.0) == 0
        @test vec_(w, 3) == [3, 138, 1459, 499]
        @test vec_(w, 3) == [3, 2677, 738, 1381]
        @test vec_(w, 3) == [3, 2677, 738, 1381]
        W.wfdbquit(w)
        isig(w, "mfreq")
        @test W.sample(w, 2, 10) == 869
        @test W.sample_valid(w) == 1
        @test W.sample(w, 1, 599) == 637
        @test W.sample_valid(w) == 1
        W.wfdbquit(w)
        isig(w, "multi")
        @test W.isigsettime(w, 100) == 0
        @test W.tnextvec(w, 0, 21650) == 23450
        @test vec_(w, 2) == [2, 969, 996]
    end
end

# After a failed seek (past the end of a FLAC stream), libFLAC aborts the
# decoding of the next block in the C library: getvec fails, and so do later
# seeks; a seek to the current time is not performed.
@testset "FLAC failed seek" begin
    with_data() do w
        @test isig(w, "flac16") == 3
        @test W.isigsettime(w, 99999) == -1
        @test vec_(w, 3) == [-3, 0, 0, 0]
        @test W.isigsettime(w, 0) == -1
        @test vec_(w, 3) == [-3, 0, 0, 0]
        W.wfdbquit(w)
        isig(w, "flac16")
        @test W.isigsettime(w, 99999) == -1
        @test W.isigsettime(w, 5) == 0
        @test vec_(w, 3) == [3, -77, -57, -47]
        W.wfdbquit(w)
        isig(w, "flac16")
        @test vec_(w, 3) == [3, -31, -38, -33]
        @test W.isigsettime(w, 9001) == -1
        @test W.isigsettime(w, 1) == 0
        @test vec_(w, 3) == [-3, 0, 0, 0]
    end
end

@testset "output prolog skew flush" begin
    with_data() do w
        W.setcfreq(w, 0.0)
        si = [Siginfo(fname=Vector{UInt8}(b"out.dat"), desc=Vector{UInt8}(i == 2 ? b"second" : b"first"),
                      units=Vector{UInt8}(b"mV"), gain=100.0, group=0, fmt=16, adcres=12) for i in 1:2]
        W.setsampfreq(w, 100.0)
        @test W.osigfopen(w, si, 2) == 2
        @test W.wfdbputprolog(w, b"PROLOG!", 7, 0) == 0
        W.wfdbsetskew(w, 1, 4)
        for i in 0:4
            W.putvec(w, Int32[i, -i])
        end
        W.wfdbflush(w)
        @test filesize("out.dat") == 27
        @test W.newheader(w, "out") == 0
        @test W.putinfo(w, "info line") == 0
        W.wfdbquit(w)
        @test read("out.hea") == b"out 2 100 5\r\nout.dat 16+7 100/mV 12 0 0 10 0 first\r\nout.dat 16:4+7 100/mV 12 0 0 -10 0 second\r\n#info line\r\n"
        @test read("out.dat") == unhex("50524f4c4f4721 0000 0000 0100 ffff 0200 feff 0300 fdff 0400 fcff")

        W.setsampfreq(w, 100.0)
        si[1].fname = Vector{UInt8}(b"out2.dat")
        si[2].fname = Vector{UInt8}(b"out2.dat")
        W.osigfopen(w, si, 2)
        W.wfdbsetstart(w, 0, 512)
        W.putvec(w, Int32[1, 2])
        W.newheader(w, "out2")
        W.wfdbquit(w)
        @test read("out2.hea") == b"out2 2 100 1\r\nout2.dat 16+512 100/mV 12 0 1 1 0 first\r\nout2.dat 16+512 100/mV 12 0 2 2 0 second\r\n"
        @test filesize("out2.dat") == 4
    end
end

@testset "info strings" begin
    with_data() do w
        xform = b"Produced by xform from record 100, beginning at 0:0"
        @test W.getinfo(w, "100s") == b" 69 M 1085 1629 x1"
        @test W.getinfo(w, nothing) == b" Aldomet, Inderal"
        @test W.getinfo(w, nothing) == xform
        @test W.setinfo(w, "newrec") == 0
        @test W.putinfo(w, "first") == 0
        @test W.putinfo(w, "second") == 0
        @test W.setinfo(w, nothing) == 0
        W.wfdbquiet(w)
        @test W.putinfo(w, "third") == -1
        W.wfdbverbose(w)
        @test read("newrec.info") == b"#first\r\n#second\r\n"
        @test W.getinfo(w, "newrec") == b"first"
        @test W.getinfo(w, nothing) == b"second"
        @test W.getinfo(w, nothing) === nothing
        @test W.setinfo(w, "100s") == 0
        @test W.putinfo(w, "extra") == 0
        W.wfdbquit(w)
        @test W.getinfo(w, "100s") == b" 69 M 1085 1629 x1"
        @test W.getinfo(w, nothing) == b" Aldomet, Inderal"
        @test W.getinfo(w, nothing) == xform
        @test W.getinfo(w, nothing) == b"extra"
        isig(w, "fmt16")
        @test W.getinfo(w, nothing) === nothing
    end
end

@testset "wfdb_freeinfo" begin
    # After wfdb_freeinfo, getinfo(nothing) rereads the info strings of the
    # open input record from the first, or fails if there is none.
    with_data() do w
        first, second = b" 69 M 1085 1629 x1", b" Aldomet, Inderal"
        @test W.getinfo(w, "100s") == first
        @test W.getinfo(w, nothing) == second
        W.wfdb_freeinfo(w)
        W.wfdbquiet(w)
        @test W.getinfo(w, nothing) === nothing
        @test W.wfdberror(w) == b"getinfo: caller did not specify record name\n"
        W.wfdbverbose(w)
        isig(w, "100s")
        @test W.getinfo(w, nothing) == first
        @test W.getinfo(w, nothing) == second
        W.wfdb_freeinfo(w)
        @test W.getinfo(w, nothing) == first
        W.wfdb_freeinfo(w)
        W.wfdb_freeinfo(w)
        @test W.getinfo(w, nothing) == first
        W.wfdbquit(w)
        # the same on the default instance
        oldpath = W.getwfdb()
        W.setwfdb(".")
        try
            @test W.getinfo("100s") == first
            W.wfdb_freeinfo()
            W.wfdbquiet()
            @test W.getinfo(nothing) === nothing
            W.wfdbverbose()
            W.isigopen("100s", nothing, 8)
            @test W.getinfo(nothing) == first
            @test W.getinfo(nothing) == second
            W.wfdb_freeinfo()
            @test W.getinfo(nothing) == first
        finally
            W.wfdbverbose()
            W.wfdbquit()
            W.setwfdb(oldpath)
        end
    end
end

@testset "setmsheader segments" begin
    with_data() do w
        names = ["100s", "null", "100s"]
        @test W.setmsheader(w, "msrec", names, 3) == 0
        W.wfdbquiet(w)
        @test W.setmsheader(w, "msbad", names, 0) == -1
        @test W.setmsheader(w, "msbad", ["100s", "fmt16"], 2) == -4
        W.wfdbverbose(w)
        W.wfdbquit(w)
        @test read("msrec.hea") == b"msrec/3 2 360 45000\r\n100s 21600\r\nnull 1800\r\n100s 21600\r\n"
        @test isig(w, "msrec") == 2
        @test segs(w) == ["100s 21600 0", "null 1800 21600", "100s 21600 23400"]
        W.isigsettime(w, 21599)
        @test vec_(w, 2) == [2, 975, 989]
        @test vec_(w, 2) == [2, -32768, -32768]
    end
end

# Round trips through write_record / read_record, in every storage format
# (FLAC formats if the codec is available).
@testset "signal roundtrip" begin
    have_flac = flac_available()
    ranges = [(8, 1000), (16, 32767), (61, 32767), (80, 127), (160, 32767), (212, 2047),
              (310, 511), (311, 511), (24, 8388607), (32, 2147483647),
              (508, 127), (516, 32767), (524, 8388607)]
    with_data() do w
        for (fmt, hi) in ranges
            if fmt >= 500 && !have_flac
                @test_skip "FLAC format $fmt"
                continue
            end
            for nsig in 1:3
                rng = W.GlibcRand(fmt * 10 + nsig)
                n = fmt >= 500 ? 5003 : 1001
                x = zeros(Int32, n, nsig)
                if fmt == 8
                    for s in 1:nsig
                        v = Int32(0)
                        for i in 1:n
                            v += W.glibc_rand!(rng) % Int32(121) - Int32(60)
                            x[i, s] = v
                        end
                    end
                else
                    for i in 1:n, s in 1:nsig
                        r = (Int64(W.glibc_rand!(rng)) << 31) | Int64(W.glibc_rand!(rng))
                        x[i, s] = (r % (2 * hi) - hi + 1) % Int32
                    end
                end
                W.write_record(w, "rt", x, 250.0; fmt=fmt, gains=200.0, adcres=16,
                               units="mV")
                y = W.read_record(w, "rt").samples
                if (fmt == 310 || fmt == 311) && (n * nsig) % 3 == 2
                    # A final group of two samples is written in 4 bytes, so
                    # the file appears to contain an extra (zero) sample.
                    @test all(iszero, y[end, :])
                    y = y[1:end-1, :]
                end
                @test y == x
                # random access with the per-sample interface
                W.isigopen(w, "rt", nothing, nsig)
                for t in (n - 1, 0, n ÷ 2, 3, n - 2), s in 0:nsig-1
                    @test W.sample(w, s, t) == x[t+1, s+1]
                end
                W.wfdbquit(w)
            end
        end
    end
end

# getvecs (used by read_record) returns exactly what getvec does.
@testset "getvecs equals getvec" begin
    have_flac = flac_available()
    with_data() do w
        W.wfdbquiet(w)
        for rec in ("fmt212", "fmt310", "fmt311", "fmt8", "twog", "100s", "skew", "mfreq",
                    "multi", "vlay", "fmt212b", "fmt310b", "fmt311b", "fmtblk", "prolog",
                    "fms", "null", "flac16", "flacmf")
            startswith(rec, "flac") && !have_flac && continue
            n = W.isigopen(w, rec, nothing, 0)
            @test n > 0
            si = [Siginfo() for _ in 1:n]
            W.isigopen(w, rec, si, n)
            v = zeros(Int32, n)
            reference = Int32[]
            while W.getvec(w, v) >= 0
                append!(reference, v)
            end
            W.wfdbquit(w)
            r = W.read_record(w, rec)
            @test vec(permutedims(r.samples)) == reference
        end
        W.wfdbverbose(w)
    end
end

@testset "physical units" begin
    with_data() do w
        r = W.read_record(w, "100s"; to=3)
        @test size(r.samples, 1) == 3
        p = W.physical(r)
        @test all(abs.(p[:, 1] .+ 0.145) .< 1e-12)
        @test all(abs.(p[:, 2] .+ 0.065) .< 1e-12)
        @test W.signal_names(r)[1] == b"MLII"
    end
end

@testset "multifrequency" begin
    with_data() do w
        lo = W.read_record(w, "mfreq"; to=10)
        hi = W.read_record(w, "mfreq"; to=20, highres=true)
        @test size(lo.samples) == (10, 3)
        @test size(hi.samples) == (20, 3)
        @test hi.fs == 400.0 && lo.fs == 100.0
    end
end

@testset "variable layout" begin
    with_data() do w
        W.wfdbquiet(w)
        r = W.read_record(w, "vlay"; from=1498, to=1502)
        W.wfdbverbose(w)
        @test size(r.samples, 1) == 4
        @test all(==(WFDB_INVALID_SAMPLE), r.samples[3, :])
    end
end

@testset "time strings in options" begin
    with_data() do w
        r = W.read_record(w, "100s"; from="0:1", to="0:2", channels=["V5"])
        @test size(r.samples) == (360, 1) && r.sampfrom == 360
        @test r.siginfo[1].desc == b"V5"
        @test r.comments[1] == b" 69 M 1085 1629 x1"
    end
end

@testset "header writing" begin
    with_data() do w
        x = zeros(Int32, 10, 2)
        W.write_record(w, "hw", x, 125.5; gains=[100.0, 0.0], adcres=16, units=["mV", "uV"],
                       names=["lead I", "pressure"], base_time="12:00:00 01/02/2003",
                       comments=["c1"])
        text = String(read("hw.hea"))
        @test startswith(text, "hw 2 125.5 10 12:00:00 01/02/2003\r\n")
        @test occursin("hw.dat 16 100/mV 16 0 0 0 0 lead I\r\n", text)
        @test endswith(text, "#c1\r\n")
        h = W.read_header(w, "hw").siginfo
        @test length(h) == 2
        @test h[2].desc == b"pressure"
        @test h[2].units == b"uV"
    end
end

@testset "physical writing" begin
    with_data() do w
        x = [0.0 1.0; -0.5 0.0025; NaN 2.0]
        W.write_record_physical(w, "ph", x, 100.0; gains=[200.0], adcres=[12], units="mV")
        r = W.read_record(w, "ph")
        @test r.samples == Int32[0 200; -100 1; WFDB_INVALID_SAMPLE 400]
        @test isnan(W.physical(r)[3, 1])
    end
end

@testset "errors are thrown" begin
    with_data() do w
        W.wfdbquiet(w)
        e = try
            W.read_record(w, "nosuch")
            nothing
        catch err
            err
        end
        @test e isa W.WfdbError && e.msg == "can't read record nosuch"
        @test_throws W.WfdbError W.read_record(w, "100s"; channels=["XX"])
        @test_throws W.WfdbError W.read_header(w, "nosuch")
        W.wfdbverbose(w)
    end
end

@testset "annotations (high-level)" begin
    if isdefined(W, :getann)    # (annot.jl)
        with_data() do w
            a = W.read_annotations(w, "100s", "atr")
            @test length(a) == 75
            @test a.samples[1:3] == [18, 77, 370]
            @test a.symbols[1:3] == [b"+", b"N", b"N"]
            @test a.fs == 360.0 && a.aux[1] == b"(N"
            @test length(W.read_annotations(w, "100s", "atr"; from="0:10", to="0:20")) == 12
            W.write_annotations(w, "100s", "cpy", a; fs=360)
            c = W.read_annotations(w, "100s", "cpy")
            @test (c.samples, c.codes, c.subtypes, c.chans, c.nums, c.aux) ==
                  (a.samples, a.codes, a.subtypes, a.chans, a.nums, a.aux)
        end
    else
        @test_skip "annot.jl"
    end
end

# WFDB-x: no default sampling frequency or gain (t_nodefaults of
# tests/reference/api_expect.c; see docs/DIVERGENCES.md).
NF_HEA = "nf 2\n100s.dat 212 200 11 1024 995 21537 0 MLII\n" *
               "100s.dat 212 200 11 1024 1011 -3962 0 V5\n"

@testset "no default frequency or gain" begin
    with_data() do w
        ts = ["s10", "e", "i", "o", "c10", "f3", "10", "1:0", "[10:00:00]", " s5", ""]
        # (api_expect runs this after t_counter, so a counter frequency is set:
        # "c10" needs the sampling frequency only then)
        W.setcfreq(w, 10.0)
        @test [W.wfdbx_time_needs_freq(w, t) for t in ts] == [0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 1]
        W.setcfreq(w, 0.0)
        @test W.wfdbx_time_needs_freq(w, "c10") == 0
        W.wfdbquiet(w)
        # no input record: no sampling frequency
        @test W.strtim(w, "1:0") == 0
        @test W.wfdberror(w) == b"strtim: sampling frequency is not specified\n"
        @test W.strtim(w, "s10") == 10
        @test W.timstr(w, 360) == "s360"
        @test W.wfdberror(w) == b"timstr: sampling frequency is not specified\n"
        @test W.mstimstr(w, -360) == "s360"
        @test W.wfdberror(w) == b"mstimstr: sampling frequency is not specified\n"
        # a header without a sampling frequency
        write("nf.hea", NF_HEA)
        @test isig(w, "nf") == 2
        @test W.sampfreq(w, nothing) == 0.0
        @test W.getifreq(w) == 0.0
        @test W.setifreq(w, 100.0) == -1
        @test W.wfdberror(w) == b"setifreq: sampling frequency is not specified\n"
        @test W.strtim(w, "2") == 0
        @test W.strtim(w, "e") == 0
        @test W.mstimstr(w, 100) == "s100"
        W.wfdbquit(w)
        # a frequency set by the caller applies
        @test W.setsampfreq(w, 500.0) == 0
        @test isig(w, "nf") == 2
        @test W.sampfreq(w, nothing) == 500.0
        @test W.strtim(w, "2") == 1000
        @test W.mstimstr(w, 100) == "    0:00.200"
        W.wfdbquit(w)
        @test W.sampfreq(w, "nf") == 0.0
        W.wfdbquit(w)
        # uncalibrated signals (record null) and invalid signal numbers
        isig(w, "null")
        @test isnan(W.aduphys(w, 0, 100))
        @test W.wfdberror(w) == b"aduphys: signal 0 is uncalibrated\n"
        @test W.physadu(w, 0, 1.0) == -32768
        @test W.wfdberror(w) == b"physadu: signal 0 is uncalibrated\n"
        @test W.adumuv(w, 1, 100) == -32768
        @test W.muvadu(w, 1, 100) == -32768
        @test W.wfdberror(w) == b"muvadu: signal 1 is uncalibrated\n"
        W.wfdbquit(w)
        isig(w, "100s")
        @test W.aduphys(w, 0, 1124) == 0.5
        @test W.physadu(w, 1, -0.5) == 924
        @test W.adumuv(w, 0, 100) == 500
        @test W.muvadu(w, 0, 1000) == 200
        @test isnan(W.aduphys(w, 5, 100))
        @test W.wfdberror(w) == b"aduphys: invalid signal number 5\n"
        @test W.physadu(w, 5, 1.0) == -32768
        @test W.adumuv(w, 2, 100) == -32768
        @test W.muvadu(w, 2, 100) == -32768
        @test W.wfdberror(w) == b"muvadu: invalid signal number 2\n"
        W.wfdbquit(w)
        # no default ADC resolution (0) or units (NULL)
        write("nr.hea", "nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n")
        si = [Siginfo() for _ in 1:8]
        @test W.isigopen(w, "nr", si, 8) == 2
        @test si[1].adcres == 0 && si[2].adcres == 0
        @test si[1].units === nothing
        W.wfdbquit(w)
        W.isigopen(w, "100s", si, 8)
        @test si[1].adcres == 11 && si[2].adcres == 11
        W.wfdbquit(w)
        W.wfdbverbose(w)
    end
end

# WFDB-x legacy mode (t_legacy of tests/reference/api_expect.c; see
# docs/DIVERGENCES.md, "Legacy mode"): the original library's defaults.
@testset "legacy mode" begin
    with_data() do w
        @test W.wfdbx_get_legacy(w) == 0
        @test W.wfdbx_set_legacy(w, 1) == 0
        @test W.wfdbx_get_legacy(w) == 1
        # amplitude conversion (gain 200, baseline 1024; invalid signal
        # numbers: gain 200, baseline 0)
        isig(w, "100s")
        @test [W.adumuv(w, 0, 200), W.adumuv(w, 0, -37), W.adumuv(w, 1, 1),
               W.adumuv(w, 0, -1), W.adumuv(w, 7, 100)] == [1000, -185, 5, -5, 500]
        @test [W.muvadu(w, 0, 1000), W.muvadu(w, 0, -333), W.muvadu(w, 1, 2),
               W.muvadu(w, 9, 1000)] == [200, -67, 0, 200]
        @test W.aduphys(w, 0, 1224) == 1.0
        @test W.aduphys(w, 1, 900) ≈ -0.62
        @test W.aduphys(w, 5, 300) == 1.5
        @test [W.physadu(w, 0, 1.0), W.physadu(w, 1, -0.5023), W.physadu(w, 5, 1.5)] ==
              [1224, 924, 300]
        @test W.aduphys(w, 5, 100) == 0.5
        @test W.physadu(w, 5, 1.0) == 200
        @test W.adumuv(w, 2, 100) == 500
        @test W.muvadu(w, 2, 100) == 20
        W.wfdbquit(w)
        # uncalibrated signals (record null): gain 200
        isig(w, "null")
        @test (W.adumuv(w, 0, 100), W.muvadu(w, 1, 100)) == (500, 20)
        @test W.aduphys(w, 0, 100) == 0.5
        @test W.physadu(w, 1, 0.5) == 100
        @test W.physadu(w, 0, 1.0) == 200
        W.wfdbquit(w)
        W.wfdbquiet(w)
        # no input record: 1 sample per second
        @test W.strtim(w, "1:0") == 60
        @test W.strtim(w, "s10") == 10
        @test W.timstr(w, 360) == "    6:00"
        @test W.mstimstr(w, -360) == "    6:00.000"
        # a header without a sampling frequency: 250 Hz
        write("nf.hea", NF_HEA)
        @test isig(w, "nf") == 2
        @test W.sampfreq(w, nothing) == 250.0
        @test W.getifreq(w) == 250.0
        @test W.strtim(w, "2") == 500
        @test W.strtim(w, "e") == 0
        @test W.mstimstr(w, 100) == "    0:00.400"
        @test W.setifreq(w, 100.0) == 0
        @test W.getifreq(w) == 100.0
        W.wfdbquit(w)
        @test W.sampfreq(w, "nf") == 250.0
        W.wfdbquit(w)
        # setifreq with an input record but no frequency
        isig(w, "100s")
        W.setsampfreq(w, 0.0)
        @test W.setifreq(w, 100.0) == -1
        @test W.wfdberror(w) == b"setifreq: no open input record\n"
        W.wfdbquit(w)
        # ADC resolution inferred from the format, or WFDB_DEFRES
        write("nr.hea", "nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n")
        si = [Siginfo() for _ in 1:8]
        @test W.isigopen(w, "nr", si, 8) == 2
        @test (si[1].adcres, si[2].adcres) == (12, 12)
        W.wfdbquit(w)
        write("nr3.hea", "nr3 5 360 10\nfmt16.dat 16\nfmt80.dat 80\nfmt310.dat 310\n" *
                         "fmt160.dat 160\nfmt24.dat 24\n")
        @test W.isigopen(w, "nr3", si, 8) == 5
        @test [si[i].adcres for i in 1:5] == [12, 8, 10, 16, 12]
        W.wfdbquit(w)
        W.wfdbverbose(w)
        @test W.wfdbx_set_legacy(w, 0) == 1
        @test W.wfdbx_get_legacy(w) == 0
        # wfdbx_legacy_args: only "--legacy" as the first argument
        args = ["-r", "--legacy"]
        @test W.wfdbx_legacy_args(w, args) == 0 && args == ["-r", "--legacy"]
        @test W.wfdbx_get_legacy(w) == 0
        args = ["--legacy", "-r", "100s"]
        @test W.wfdbx_legacy_args(w, args) == 1 && args == ["-r", "100s"]
        @test W.wfdbx_get_legacy(w) == 1
        @test W.wfdbx_get_legacy(Wfdb()) == 0    # per library instance
        W.wfdbx_set_legacy(w, false)
    end
end

@testset "high-level API without defaults" begin
    with_data() do w
        W.wfdbquiet(w)
        write("nf.hea", NF_HEA)
        write("uc.hea", "uc 2 360 21600\n100s.dat 212 0 11 1024 995 21537 0 MLII\n" *
                        "100s.dat 212 0 11 1024 1011 -3962 0 V5\n")
        # read_record: fs 0, time strings that need a frequency fail
        r = W.read_record(w, "nf"; from="s2", to=5)
        @test r.fs == 0.0 && size(r.samples) == (3, 2) && r.base_time === nothing
        @test r.samples == W.read_record(w, "100s"; from=2, to=5).samples
        @test W.physical(r)[1, 1] == (r.samples[1, 1] - 1024) / 200
        @test hlerr(() -> W.read_record(w, "nf"; to="0:1")) ==
              "sampling frequency of record nf is not specified"
        @test hlerr(() -> W.read_record(w, "nf"; from="1")) ==
              "sampling frequency of record nf is not specified"
        # physical units of an uncalibrated signal fail (no default gain)
        u = W.read_record(w, "uc"; channels=["V5"], to=3)
        @test u.channels == [1] && u.siginfo[1].gain == 0.0
        @test hlerr(() -> W.physical(u)) == "signal 1 of record uc is uncalibrated"
        # write_record: gains are required, 0 means uncalibrated; fs > 0
        x = Int32[1 2; 3 4]
        @test hlerr(() -> W.write_record(w, "wn", x, 100.0)) == "write_record: gains must be specified"
        @test hlerr(() -> W.write_record(w, "wn", x, 100.0; gains=Float64[])) ==
              "write_record: gains must be specified"
        @test hlerr(() -> W.write_record(w, "wn", x, 0.0; gains=200.0, adcres=16, units="mV")) ==
              "write_record: the sampling frequency must be > 0"
        W.write_record(w, "wn", x, 100.0; gains=[0.0, 50.0], adcres=[16, 12],
                       units=[nothing, "uV"])
        h = W.read_header(w, "wn").siginfo
        @test h[1].gain == 0.0 && h[2].gain == 50.0
        @test h[1].adcres == 16 && h[2].adcres == 12
        @test h[1].units === nothing && h[2].units == b"uV"
        # write_record: ADC resolutions are required (>= 1), and the units of
        # every calibrated signal
        @test hlerr(() -> W.write_record(w, "wn", x, 100.0; gains=200.0, units="mV")) ==
              "write_record: ADC resolution(s) must be specified"
        @test hlerr(() -> W.write_record(w, "wn", x, 100.0; gains=200.0, adcres=[16, 0],
                                         units="mV")) ==
              "write_record: ADC resolution(s) must be specified"
        @test hlerr(() -> W.write_record(w, "wn", x, 100.0; gains=200.0, adcres=16)) ==
              "write_record: units must be specified"
        @test hlerr(() -> W.write_record(w, "wn", x, 100.0; gains=[0.0, 200.0], adcres=16,
                                         units=["mV", ""])) ==
              "write_record: units must be specified"
        W.write_record(w, "wn", x, 100.0; gains=0.0, adcres=16)
        @test all(s -> s.units === nothing, W.read_header(w, "wn").siginfo)
        # read_record: an unspecified resolution is 0, unspecified units nothing
        write("nr.hea", "nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n")
        n = W.read_record(w, "nr"; to=3)
        @test all(s -> s.adcres == 0 && s.units === nothing, n.siginfo)
        @test hlerr(() -> W.write_record_physical(w, "wp", [1.0 2.0], 100.0)) ==
              "write_record: gains must be specified"
        @test hlerr(() -> W.write_record_physical(w, "wp", [1.0 2.0], 100.0; gains=[200.0, 0.0])) ==
              "write_record: signal 1 is uncalibrated"
        @test hlerr(() -> W.write_record_physical(w, "wp", [1.0 2.0], -1.0; gains=200.0,
                                                  adcres=16, units="mV")) ==
              "write_record: the sampling frequency must be > 0"
        @test hlerr(() -> W.write_record_physical(w, "wp", [1.0 2.0], 100.0; gains=200.0,
                                                  units="mV")) ==
              "write_record: ADC resolution(s) must be specified"
        # read_annotations: no default frequency; fs applies without one
        if isdefined(W, :getann)
            cp("100s.atr", "nh.atr")
            a = W.read_annotations(w, "nh", "atr")
            @test a.fs == 0.0 && length(a) == 75
            @test length(W.read_annotations(w, "nh", "atr"; to="s1000")) ==
                  count(<(1000), a.samples)
            @test hlerr(() -> W.read_annotations(w, "nh", "atr"; to="0:10")) ==
                  "sampling frequency of record nh is not specified"
            b = W.read_annotations(w, "nh", "atr"; fs=360, from="0:10", to="0:20")
            @test b.fs == 360.0 && length(b) == 12
            @test W.read_annotations(w, "100s", "atr"; fs=100).fs == 360.0   # header wins
            @test hlerr(() -> W.read_annotations(w, "nh", "atr"; fs=0)) ==
                  "read_annotations: fs must be > 0"
        end
        W.wfdbverbose(w)
    end
end

# WFDB-x: the legacy option of the high-level functions (the behavior of
# the port before WFDB-x removed the built-in defaults).
@testset "high-level API legacy option" begin
    with_data() do w
        W.wfdbquiet(w)
        write("nf.hea", NF_HEA)
        x = Int32[1 2; 3 4]
        # write_record: gain 200, resolution from the format, no units needed
        W.write_record(w, "wl", x, 100.0; legacy=true)
        h = W.read_header(w, "wl").siginfo
        @test all(s -> s.gain == 200.0 && s.adcres == 16 && s.units === nothing, h)
        W.write_record(w, "wl", x, 100.0; fmt=212, legacy=true)
        @test all(s -> s.adcres == 12, W.read_header(w, "wl").siginfo)
        @test W.wfdbx_get_legacy(w) == 0            # restored
        # The library's legacy mode also applies (without legacy=true)
        W.wfdbx_set_legacy(w, true)
        W.write_record(w, "wg", x, 100.0)
        W.wfdbx_set_legacy(w, false)
        @test all(s -> s.gain == 200.0 && s.adcres == 16, W.read_header(w, "wg").siginfo)
        W.write_record_physical(w, "wl", [1.0 2.0], 100.0; gains=[0.0, 100.0], legacy=true)
        @test W.read_record(w, "wl").samples == Int32[200 200]
        # read_record physical on uncalibrated signals (record null, whose
        # samples are invalid, and uc): gain 200
        r = W.read_record(w, "null"; to=3, legacy=true)
        @test all(isnan, W.physical(r; legacy=true))
        @test hlerr(() -> W.physical(r)) == "signal 0 of record null is uncalibrated"
        write("uc.hea", "uc 2 360 21600\n100s.dat 212 0 11 1024 995 21537 0 MLII\n" *
                        "100s.dat 212 0 11 1024 1011 -3962 0 V5\n")
        u = W.read_record(w, "uc"; to=1, legacy=true)
        @test W.physical(u; legacy=true) == [(995 - 1024) / 200 (1011 - 1024) / 200]
        # a header without a frequency: 250 Hz; ADC resolution from the format
        n = W.read_record(w, "nf"; to="0:1", legacy=true)
        @test n.fs == 250.0 && size(n.samples, 1) == 250
        write("nr.hea", "nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n")
        @test all(s -> s.adcres == 12, W.read_header(w, "nr"; legacy=true).siginfo)
        @test all(s -> s.adcres == 0, W.read_header(w, "nr").siginfo)
        # read_annotations without a header: 250 Hz (fs still applies)
        if isdefined(W, :getann)
            cp("100s.atr", "nh.atr")
            a = W.read_annotations(w, "nh", "atr"; to="0:1", legacy=true)
            @test a.fs == 250.0 && a.samples == [s for s in a.samples if s < 250]
            @test W.read_annotations(w, "nh", "atr"; fs=360, legacy=true).fs == 360.0
        end
        # the previous setting is restored, also on errors
        @test hlerr(() -> W.read_record(w, "nosuch"; legacy=true)) !== nothing
        @test W.wfdbx_get_legacy(w) == 0
        W.wfdbx_set_legacy(w, true)
        W.read_header(w, "100s"; legacy=true)
        @test W.wfdbx_get_legacy(w) == 1
        W.wfdbx_set_legacy(w, false)
        W.wfdbverbose(w)
    end
end

@testset "tools in legacy mode" begin
    data = W.workload_data_source()
    if data !== nothing
        env = ("WFDBX_INPUT_DIR" => ".",)
        st, out, err = W.run_tool("wrsamp", ["--legacy", "-o", "tl"]; stdin="1 2\n",
                                  dir=mktempdir(), env=env)
        @test st == 0
        st, out, err = W.run_tool("rdann", ["--legacy", "-F", "360"]; dir=data, env=env)
        @test st == 1 && err == b"rdann: unrecognized option -F\n"
        st, out, err = W.run_tool("rdann", ["-r", "100s", "--legacy"]; dir=data, env=env)
        @test st == 1
    end
end

@testset "default instance functions" begin
    with_data() do _
        setwfdb(".")
        @test isigopen("100s", nothing, 0) == 2
        @test strtim("e") == 21600
        v = zeros(Int32, 2)
        @test isigopen("100s", nothing, 2) == 2
        @test getvec(v) == 2
        @test v == [995, 1011]
        @test size(read_record("100s").samples, 1) == 21600
        wfdbquit()
    end
end

@testset "tools in-process" begin
    data = W.workload_data_source()
    if data !== nothing
        env = ("WFDBX_INPUT_DIR" => ".",)
        st, out, err = W.run_tool("rdsamp", ["-r", "100s", "-t", "s3"]; dir=data, env=env)
        @test st == 0 && isempty(err)
        @test out == b"              0\t    995\t   1011\n              1\t    995\t   1011\n              2\t    995\t   1011\n"
        st, out, err = W.run_tool("wfdbdesc", ["100s"]; dir=data, env=env)
        @test st == 0 && startswith(String(out), "Record 100s\n")
        st, out, err = W.run_tool("wrsamp", ["-F", "100"]; stdin="1 2\n3 4\n", dir=data, env=env)
        @test st == 0 && out == UInt8[1, 0, 2, 0, 3, 0, 4, 0]
    end
end


# ---------------------------------------------------------------------------
# WFDB-x: the output directory (wfdbx_set_output_dir), the in-process sorting
# of an annotation file written there, and absolute paths (as t_outdir in
# api_expect.c and test_api.py)

OREC_OAT = unhex(
    "00581efc232320616e6e6f746174696f6e207479706520646566696e6974696f" *
    "6e73005816fc3135205b31355d206d79206465736372697074696f6e005807fc" *
    "3432206e65772000005815fc232320656e64206f6620646566696e6974696f6e" *
    "730000ecffffffff0100050405140a040a040000")

function annv_(w, n)
    a = Annotation()
    st = W.getann(w, n, a)
    Int64[st, a.time, a.anntyp, a.subtyp, a.chan, a.num]
end

@testset "output directory" begin
    with_data() do w
        # (the annotation type table, as left by t_strings in api_expect.c)
        W.setanndesc(w, 15, "my description")
        W.setannstr(w, 42, "new")
        W.setanndesc(w, 42, "")
        @test W.wfdbx_get_output_dir(w) === nothing
        mkdir("odir")
        @test W.wfdbx_set_output_dir(w, "odir") === nothing
        @test W.wfdbx_get_output_dir(w) == b"odir"
        si = [Siginfo(fname=Vector{UInt8}("orec.dat"), desc=Vector{UInt8}("sig"), gain=200.0,
                      fmt=16, adcres=12, spf=1)]
        W.setsampfreq(w, 100.0)
        @test W.osigfopen(w, si, 1) == 1
        for i in 0:2
            W.putvec(w, Int32[10i - 7])
        end
        @test W.newheader(w, "orec") == 0
        @test W.annopen(w, "orec", [Anninfo("oat", WFDB_WRITE)], 1) == 0
        a = Annotation()
        for (i, t) in enumerate([30, 10, 20, 10, 5])    # out of order, a duplicate
            a.time = t
            a.anntyp = i == 4 ? W.PVC : W.NORMAL
            W.putann(w, 0, a)
        end
        W.wfdbquiet(w)
        W.wfdbquit(w)       # (the output directory is kept)
        W.wfdbverbose(w)
        @test W.wfdbx_set_output_dir(w, "") == b"odir"
        @test W.wfdbx_get_output_dir(w) === nothing
        @test W.wfdbx_set_output_dir(w, "odir2") === nothing
        @test W.wfdbx_set_output_dir(w, nothing) == b"odir2"
        @test W.wfdbx_get_output_dir(w) === nothing
        @test read("odir/orec.hea") == b"orec 1 100 3\r\norec.dat 16 200 12 0 -7 9 0 sig\r\n"
        @test read("odir/orec.dat") == unhex("f9ff03000d00")
        @test read("odir/orec.oat") == OREC_OAT
        @test !isfile("orec.hea")
        # a missing output directory is created (as are the missing
        # directories of any output file name)
        W.wfdbx_set_output_dir(w, "newdir")
        @test W.osigfopen(w, si, 1) == 1
        @test W.annopen(w, "orec", [Anninfo("oat", WFDB_WRITE)], 1) == 0
        W.wfdbquit(w)
        W.wfdbx_set_output_dir(w, nothing)
        @test (filesize("newdir/orec.dat"), filesize("newdir/orec.oat")) == (0, 2)
        # the record is read from the output directory
        W.setwfdb(w, "odir")
        @test isig(w, "orec") == 1
        @test [vec_(w, 1) for _ in 1:3] == [[1, -7], [1, 3], [1, 13]]
        @test W.annopen(w, "orec", [Anninfo("oat", WFDB_READ)], 1) == 0
        @test [annv_(w, 0) for _ in 1:5] == [[0, 5, 1, 0, 0, 0], [0, 10, 5, 0, 0, 0],
                                             [0, 20, 1, 0, 0, 0], [0, 30, 1, 0, 0, 0],
                                             [-1, 0, 0, 0, 0, 0]]
        W.wfdbquit(w)
        # t_sortfix: an out-of-order annotation at time 0 is not lost (it is
        # in legacy mode, as by sortann), and in legacy mode with an output
        # directory, sortann runs in that directory
        W.setwfdb(w, ".")
        a = Annotation(time=0, anntyp=W.NORMAL % Int8)
        W.wfdbquiet(w)
        for legacy in (false, true)
            W.wfdbx_set_legacy(w, legacy)
            @test W.annopen(w, "100s", [Anninfo(legacy ? "l0" : "m0", WFDB_WRITE)], 1) == 0
            for t in (5, 0, 3)
                a.time = t
                W.putann(w, 0, a)
            end
            W.wfdbquit(w)
            W.wfdbx_set_output_dir(w, "odir")
            @test W.annopen(w, "orec", [Anninfo(legacy ? "lsrt" : "msrt", WFDB_WRITE)], 1) == 0
            for t in (30, 10, 20)
                a.time = t
                W.putann(w, 0, a)
            end
            W.wfdbquit(w)
            W.wfdbx_set_output_dir(w, nothing)
        end
        W.wfdbx_set_legacy(w, false)
        W.wfdbverbose(w)
        for (name, times) in (("m0", [0, 3, 5]), ("l0", [5]))
            @test W.annopen(w, "100s", [Anninfo(name, WFDB_READ)], 1) == 0
            @test [annv_(w, 0) for _ in times] == [[0, t, 1, 0, 0, 0] for t in times]
            @test annv_(w, 0)[1] == -1
            W.wfdbquit(w)
        end
        @test read("odir/orec.msrt") == read("odir/orec.lsrt") ==
              [OREC_OAT[1:end-10]; unhex("0a040a040a040000")]
        # the setting belongs to the library state
        @test W.wfdbx_set_output_dir(w, "odir") === nothing
        @test W.wfdbx_get_output_dir(Wfdb()) === nothing
    end
end

@testset "absolute paths" begin
    with_data() do w
        rec = joinpath(realpath(pwd()), "100s")
        W.wfdbquiet(w)
        @test isig(w, rec) == 2
        @test vec_(w, 2) == [2, 995, 1011]
        @test W.wfdbfile(w, "hea", rec) == Vector{UInt8}(rec * ".hea")
        @test W.annopen(w, rec, [Anninfo("atr", WFDB_READ)], 1) == 0
        @test annv_(w, 0) == [0, 18, 28, 0, 0, 0]
        W.wfdbquit(w)
        @test W.sampfreq(w, rec) == 360
        W.wfdbquit(w)
        @test isig(w, joinpath(pwd(), "nosuch")) == -1
        W.wfdbquit(w)
        # legacy mode: as in C, an absolute name is searched for in the WFDB
        # path (here "./" followed by the name) ...
        W.wfdbx_set_legacy(w, true)
        @test isig(w, rec) == -1
        @test W.annopen(w, rec, [Anninfo("atr", WFDB_READ)], 1) == -3
        W.wfdbquit(w)
        # ... unless the WFDB path has an empty component (names as given)
        W.setwfdb(w, ";")
        @test isig(w, rec) == 2
        @test vec_(w, 2) == [2, 995, 1011]
        W.wfdbquit(w)
        W.wfdbx_set_legacy(w, false)
        @test isig(w, rec) == 2
        W.wfdbverbose(w)
    end
end

@testset "write_record: dir checks first" begin
    with_data() do w
        x = Int32[0 1; 2 3]
        mkdir("out")
        for f in (W.write_record, W.write_record_physical)
            e = try     # (no gains, fs 0)
                f(w, "sub/rec", x, 0.0; dir="out")
            catch err
                err
            end
            @test e isa W.WfdbError &&
                  e.msg == "record name must not contain a directory when dir is given"
            e = try
                f(w, "rec", x, 0.0; dir="nosuch")
            catch err
                err
            end
            @test e isa W.WfdbError && e.msg == "directory nosuch does not exist"
            e = try
                f(w, "rec", x, 360.0; dir="out")
            catch err
                err
            end
            @test e isa W.WfdbError && e.msg == "write_record: gains must be specified"
        end
        @test isempty(readdir("out"))
    end
end

@testset "write_record dir" begin
    with_data() do w
        x = Int32.(reshape(0:19, 10, 2))
        mkdir("out")
        W.wfdbx_set_output_dir(w, "elsewhere")
        W.write_record(w, "rec", x, 360.0; gains=200.0, adcres=12, units="mV", dir="out")
        @test W.wfdbx_get_output_dir(w) == b"elsewhere"     # restored
        W.wfdbx_set_output_dir(w, nothing)
        @test sort(readdir("out")) == ["rec.dat", "rec.hea"]
        @test !isfile("rec.hea") && !isfile("rec.dat")
        hea = split(String(read("out/rec.hea")), "\r\n")
        @test hea[1] == "rec 2 360 10"
        @test startswith(hea[2], "rec.dat 16 ")
        W.setwfdb(w, "out")
        @test W.read_record(w, "rec").samples == x
        W.setwfdb(w, ".")
        W.write_record_physical(w, "phys", Float64.(x) ./ 200, 360.0; gains=200.0, adcres=12,
                                units="mV", dir="out")
        @test read("out/phys.dat") == read("out/rec.dat")
        # legacy mode: the same
        W.write_record(w, "leg", x, 360.0; dir="out", legacy=true)
        @test startswith(String(read("out/leg.hea")), "leg 2 360 10\r\nleg.dat 16 ")
        e = try
            W.write_record(w, "rec", x, 360.0; gains=200.0, adcres=12, units="mV", dir="nosuch")
        catch err
            err
        end
        @test e isa W.WfdbError && e.msg == "directory nosuch does not exist"
        e = try
            W.write_record(w, "sub/rec", x, 360.0; gains=200.0, adcres=12, units="mV",
                           dir="out")
        catch err
            err
        end
        @test e isa W.WfdbError && e.msg == "record name must not contain a directory when dir is given"
        @test !isdir("nosuch") && !isdir("out/sub")
        # restored also on errors
        @test W.wfdbx_get_output_dir(w) === nothing
        W.wfdbx_set_output_dir(w, "keep")
        @test_throws W.WfdbError W.write_record(w, "r2", x, 0.0; gains=200.0, adcres=12,
                                                units="mV", dir="out")
        @test W.wfdbx_get_output_dir(w) == b"keep"
        W.wfdbx_set_output_dir(w, nothing)
    end
end


# A signal file shorter than its header says (getvec status -3, unexpected
# EOF) is an error of read_record, not the end of the data; the low-level
# API is unchanged.
@testset "read_record truncated signal file" begin
    with_data() do w
        W.wfdbquiet(w)
        x = Int32[1 2; 3 4; 5 6; 7 8]
        for name in ("tr", "ok")
            W.write_record(w, name, x, 100.0; gains=100.0, adcres=16, units="mV")
        end
        open(f -> truncate(f, 8), "tr.dat", "r+")   # 2 of the 4 frames (format 16)
        for legacy in (false, true)
            # (1) the error, and the library is left usable
            @test hlerr(() -> W.read_record(w, "tr"; legacy=legacy)) ==
                  "can't read signal data of record tr (getvec status -3)"
            @test W.read_record(w, "ok"; legacy=legacy).samples == x
            # reading only what the file holds is not an error
            @test W.read_record(w, "tr"; to=2, legacy=legacy).samples == x[1:2, :]
            # (2) a sub-interval, and `to` past the end of a record whose
            # header gives its length (what there is, no error)
            @test W.read_record(w, "ok"; from=1, to=3, legacy=legacy).samples == x[2:3, :]
            @test W.read_record(w, "ok"; to=10, legacy=legacy).samples == x
        end
        # (3) the low-level API: getvec returns -3 at the end of the
        # truncated file, getvecs the frames read
        @test W.isigopen(w, "tr", nothing, 2) == 2
        @test [vec_(w, 2)[1] for _ in 1:3] == [2, 2, -3]
        W.wfdbquit(w)
        buf = zeros(Int32, 20)
        @test W.isigopen(w, "tr", nothing, 2) == 2
        @test W.getvecs_status(w, buf, 10) == (2, -3)
        W.wfdbquit(w)
        @test W.isigopen(w, "tr", nothing, 2) == 2
        @test W.getvecs(w, buf, 10) == 2
        W.wfdbquit(w)
        @test W.isigopen(w, "ok", nothing, 2) == 2
        @test W.getvecs_status(w, buf, 10) == (4, -1)
        W.wfdbquit(w)
        W.wfdbverbose(w)
    end
end


# WFDB-x: a checksum error (getvec status -4) is a warning of read_record
# (every frame is returned), not an error; checksum_warning=false turns it
# off. The library's getvec message is not printed then.
@testset "read_record checksum warning" begin
    with_data() do w
        msg = "checksum error in record ck: the signal data do not match the checksums in its header"
        x = Int32[1 2; 3 4; 5 6; 7 8]
        W.write_record(w, "ck", x, 100.0; gains=100.0, adcres=16, units="mV")
        open("ck.dat", "r+") do f       # sample (1, 0): 3 -> 9
            seek(f, 4)
            write(f, UInt8[9, 0])
        end
        y = copy(x)
        y[2, 1] = 9
        # (the same samples with correct checksums: every frame, the last one
        # included, is returned in both cases)
        W.write_record(w, "good", y, 100.0; gains=100.0, adcres=16, units="mV")
        for legacy in (false, true)
            g = W.read_record(w, "good"; legacy=legacy)
            good = g.samples
            @test good == y
            @test g.checksum_ok
            local r
            err = lib_stderr() do
                r = @test_logs (:warn, msg) W.read_record(w, "ck"; legacy=legacy)
            end
            @test r.samples == y && size(r.samples) == size(good)
            @test !r.checksum_ok
            @test err == ""                 # (no getvec message)
            @test W.physical(r) == y ./ 100.0
            err = lib_stderr() do
                # no warning with the option off; none when the record is
                # not read to its end (no checksum is verified)
                r = @test_logs W.read_record(w, "ck"; checksum_warning=false, legacy=legacy)
                @test r.samples == y
                @test !r.checksum_ok        # (independent of the warning)
                r3 = @test_logs W.read_record(w, "ck"; to=3, legacy=legacy)
                @test r3.samples == y[1:3, :] && r3.checksum_ok
                @test (@test_logs W.read_record(w, "ck"; from=1, to="e", checksum_warning=false,
                                                legacy=legacy)).samples == y[2:end, :]
            end
            @test err == ""
        end
        # the truncated case is still an error
        W.write_record(w, "tr", x, 100.0; gains=100.0, adcres=16, units="mV")
        open(f -> truncate(f, 8), "tr.dat", "r+")
        W.wfdbquiet(w)
        @test_throws W.WfdbError W.read_record(w, "tr")
        W.wfdbverbose(w)
        # the low-level API is unchanged: getvec returns -4 for the last
        # frame (filled), getvecs stops before it, and the message is printed
        local v
        err = lib_stderr() do
            @test W.isigopen(w, "ck", nothing, 2) == 2
            v = [vec_(w, 2) for _ in 1:4]
            W.wfdbquit(w)
            buf = zeros(Int32, 20)
            @test W.isigopen(w, "ck", nothing, 2) == 2
            @test W.getvecs_status(w, buf, 10) == (3, -4)
            @test buf[1:6] == vec(permutedims(y[1:3, :]))
            W.wfdbquit(w)
        end
        @test [x[1] for x in v] == [2, 2, 2, -4] && v[4][2:3] == [7, 8]
        @test err == "getvec: checksum error in signal 0\n"^2
        @test W.wfdberror(w) == b"getvec: checksum error in signal 0\n"
    end
end

# WFDB-x: in high-resolution mode, every vector of the frame at which the
# checksum is verified has getvec status -4; read_record returns all of them
# (and reads on to the end), with a single warning.
@testset "read_record checksum error, high resolution" begin
    with_data() do w
        wr(rec, x, spf) = W.write_record(w, rec, x, 100.0; samps_per_frame=spf, gains=100.0,
                                         adcres=16, units="mV",
                                         names=["sig$k" for k in 0:length(spf)-1])
        msg(rec) = "checksum error in record $rec: the signal data do not match the checksums in its header"
        nfr = 4
        for spf in ([2], [3], [1, 2], [2, 3])
            ncol = sum(spf)
            x = reshape(Int32.(1:nfr*ncol), nfr, ncol)
            for frame in (1, nfr)       # the corrupt sample: in the first or the last frame
                wr("mf", x, spf)
                @test filesize("mf.dat") == 2 * nfr * ncol      # (format 16)
                open("mf.dat", "r+") do f
                    seek(f, 2 * ncol * (frame - 1))
                    write(f, UInt8[99, 0])
                end
                y = copy(x)
                y[frame, 1] = 99
                wr("good", y, spf)
                for legacy in (false, true)
                    g = W.read_record(w, "good"; highres=true, legacy=legacy)
                    @test g.checksum_ok && size(g.samples, 1) == nfr * maximum(spf)
                    r = @test_logs (:warn, msg("mf")) W.read_record(w, "mf"; highres=true,
                                                                       legacy=legacy)
                    @test r.samples == g.samples && !r.checksum_ok
                    r = @test_logs W.read_record(w, "mf"; highres=true, checksum_warning=false,
                                                 legacy=legacy)
                    @test r.samples == g.samples && !r.checksum_ok
                    if length(spf) == 2
                        for ch in ([1], [1, 0], ["sig1"])
                            gc = W.read_record(w, "good"; highres=true, channels=ch, legacy=legacy)
                            r = @test_logs W.read_record(w, "mf"; highres=true, channels=ch,
                                                         checksum_warning=false, legacy=legacy)
                            @test r.samples == gc.samples && !r.checksum_ok
                            @test r.channels == gc.channels
                        end
                    end
                    # from inside the record to the end
                    r = @test_logs W.read_record(w, "mf"; highres=true, from=1,
                                                 checksum_warning=false, legacy=legacy)
                    @test r.samples == g.samples[2:end, :] && !r.checksum_ok
                    # ending before the last frame: no checksum check
                    to = (nfr - 1) * maximum(spf) - 1
                    r = @test_logs W.read_record(w, "mf"; highres=true, to=to, legacy=legacy)
                    @test r.samples == g.samples[1:to, :] && r.checksum_ok
                    # ending within the last frame, or at its end
                    for to in ((nfr - 1) * maximum(spf) + 1, nfr * maximum(spf))
                        r = W.read_record(w, "mf"; highres=true, to=to, checksum_warning=false,
                                          legacy=legacy)
                        @test r.samples == g.samples[1:to, :]
                    end
                    # low resolution: one vector per frame, unchanged
                    gl = W.read_record(w, "good"; legacy=legacy)
                    @test size(gl.samples, 1) == nfr
                    r = @test_logs (:warn, msg("mf")) W.read_record(w, "mf"; legacy=legacy)
                    @test r.samples == gl.samples && !r.checksum_ok
                end
            end
        end
        # the example of the specification (spf 2 and 3, a single signal)
        for spf in (2, 3)
            x = reshape(Int32.(1:4*spf), spf, 4)'      # frames 1..spf, spf+1..2spf, ...
            wr("mf", Matrix(x), [spf])
            open(f -> write(f, UInt8[99, 0]), "mf.dat", "r+")
            r = W.read_record(w, "mf"; highres=true, checksum_warning=false)
            @test vec(r.samples) == [99; 2:4*spf] && !r.checksum_ok
        end
    end
end

# WFDB-x: an output signal file is never a signal file of the open input
# record (the files are compared, not their names); legacy mode: no check
# (as t_alias in api_expect.c).
@testset "output file is an input file" begin
    with_data() do w
        spec(fname) = [Siginfo(fname=Vector{UInt8}(fname), desc=Vector{UInt8}("s$i"),
                               units=Vector{UInt8}("mV"), gain=100.0, group=0, fmt=16,
                               adcres=12, spf=1) for i in 0:2]
        fmt16 = read("fmt16.dat")
        fmt212 = read("fmt212.dat")
        hardlink("fmt16.dat", "ahard16.dat")
        # an open signal file; under another name; a hard link; a segment of
        # a multi-segment record that is not open yet (fmt212, vlay's last)
        for (rec, fname) in [("fmt16", "fmt16.dat"), ("fmt16", "./fmt16.dat"),
                             ("fmt16", "ahard16.dat"), ("skew", "fmt16.dat"),
                             ("vlay", "fmt16.dat"), ("vlay", "fmt212.dat")]
            W.wfdbquit(w)
            W.wfdbquiet(w)
            @test W.isigopen(w, rec, nothing, 3) == 3
            W.wfdbverbose(w)
            W.setsampfreq(w, 250.0)
            err = lib_stderr(() -> @test W.osigfopen(w, spec(fname), 3) == -3)
            @test err == "osigfopen: output file $fname is also an input file\n"
            @test vec_(w, 3)[1] == 3        # the input is still readable
        end
        # osigopen names itself
        W.wfdbquit(w)
        @test W.isigopen(w, "fmt16", nothing, 3) == 3
        err = lib_stderr(() -> @test W.osigopen(w, "fmt16", nothing, 3) == -3)
        @test err == "osigopen: output file fmt16.dat is also an input file\n"
        W.wfdbquit(w)
        @test read("fmt16.dat") == fmt16 && read("fmt212.dat") == fmt212
        # not an input file: another file, a file that does not exist yet
        W.wfdbquiet(w)
        for fname in ("fmt8.dat", "new.dat")
            @test W.isigopen(w, "vlay", nothing, 3) == 3
            W.setsampfreq(w, 250.0)
            @test W.osigfopen(w, spec(fname), 3) == 3
            W.wfdbquit(w)
        end
        W.wfdbverbose(w)
        # with no input record open, any file can be written
        W.setsampfreq(w, 250.0)
        @test lib_stderr(() -> @test W.osigfopen(w, spec("fmt8.dat"), 3) == 3) == ""
        W.wfdbquit(w)
        # legacy mode: the original behavior (the file is created, truncated)
        W.wfdbx_set_legacy(w, true)
        @test W.isigopen(w, "fmt16", nothing, 3) == 3
        W.setsampfreq(w, 250.0)
        @test W.osigfopen(w, spec("fmt16.dat"), 3) == 3
        W.wfdbquit(w)
        W.wfdbx_set_legacy(w, false)
        @test filesize("fmt16.dat") == 0
    end
end

# read_header returns the header; base_time_ms and base_date of Record and
# Header.
@testset "read_header and base time and date" begin
    with_data() do w
        h = W.read_header(w, "100s")
        @test h isa W.Header
        @test h.name == "100s" && h.fs == 360.0 && h.nsamples == 21600 && h.nsig == 2
        @test h.counter_freq == 360.0 && h.base_counter == 0.0
        @test [s.desc for s in h.siginfo] == [b"MLII", b"V5"]
        r = W.read_record(w, "100s"; to=2)
        @test h.base_time == r.base_time && h.comments == r.comments
        @test h.base_time_ms == r.base_time_ms && h.base_date == r.base_date
        x = Int32[1; 2; 3;;]
        W.write_record(w, "bt", x, 250.0; gains=200.0, adcres=16, units="mV")
        sig = "bt.dat 16 200/mV 16 0 1 6 0 s\n"
        for (line, txt, ms, date) in [
                ("bt 1 250 3 14:00:03.500 21/06/2024", "[14:00:03 21/06/2024]", 50403500,
                 (2024, 6, 21)),
                ("bt 1 250 3 14:00:03", "[14:00:03]", 50403000, nothing),
                ("bt 1 250 3", nothing, nothing, nothing),
                ("bt 1 250 3 0:0:0 01/03/1900", "[00:00:00 01/03/1900]", 0, (1900, 3, 1))]
            write("bt.hea", line * "\n" * sig * "#c\n")
            for o in (W.read_header(w, "bt"), W.read_record(w, "bt"))
                @test o.base_time == txt
                @test o.base_time_ms === (ms === nothing ? nothing : Int64(ms))
                @test o.base_date === date
                @test o.comments == [b"c"]
            end
            # (as datstr)
            if date !== nothing
                W.isigopen(w, "bt", nothing, 1)
                @test W.datstr(w, w.sig.bdate) ==
                      String(W.cformat(" %02d/%02d/%d", date[3], date[2], date[1]))
                W.wfdbquit(w)
            end
        end
        # counter frequency and base counter; no samples count; no frequency
        write("bt.hea", "bt 1 250/1000(5)\n" * sig)
        h = W.read_header(w, "bt")
        @test h.fs == 250.0 && h.counter_freq == 1000.0 && h.base_counter == 5.0
        @test h.nsamples == 0 && h.nsig == 1 && h.comments == Vector{UInt8}[]
        write("bt.hea", "bt 1\n" * sig)
        @test W.read_header(w, "bt").fs == 0.0
        @test W.read_header(w, "bt"; legacy=true).fs == 250.0
        # no signals
        write("ns.hea", "ns 0 100 50 10:00:00\n")
        h = W.read_header(w, "ns")
        @test h.nsig == 0 && isempty(h.siginfo) && h.nsamples == 50 && h.base_time_ms == 36000000
        # a multi-segment record: the length of the record
        @test W.read_header(w, "vlay").nsamples == size(W.read_record(w, "vlay").samples, 1)
    end
end

# WFDB-x: the bulk frame reader (_bulk_frames!) gives exactly what the
# per-frame path gives (samples, statuses, and the state of the library).
function bulk_state(w)
    st = w.sig
    (st.istime, [(i.samp, i.info.cksum, i.info.nsamp) for i in st.isd[1:st.nisig]],
     [(g.bp, g.be, g.count, g.data, g.datb, g.stat) for g in st.igd[1:st.nigroup]])
end
function bulk_trace(w, rec, nsig, bulk; mode=W.WFDB_LOWRES, from=0, chunks=(1000,))
    W._BULK_ENABLED[] = bulk
    out = Any[]
    try
        W.wfdbquiet(w)
        @test W.isigopen(w, rec, nothing, nsig) == nsig
        W.setgvmode(w, mode)
        from > 0 && push!(out, W.isigsettime(w, from))
        k = 0
        while k < 1000
            c = chunks[k % length(chunks) + 1]
            buf = zeros(Int32, c * nsig)
            got, stat = W.getvecs_status(w, buf, c)
            push!(out, (got, stat, buf, bulk_state(w)))
            stat < 0 && break
            k += 1
        end
        push!(out, W.wfdberror(w))
        W.wfdbquit(w)
    finally
        W._BULK_ENABLED[] = true
        W.wfdbverbose(w)
    end
    out
end

# (a small random number generator: xorshift64; a value in lo:hi)
mutable struct XorShift
    s::UInt64
end
function rnd(r::XorShift, lo::Integer, hi::Integer)
    x = r.s
    x ⊻= x << 13
    x ⊻= x >> 7
    x ⊻= x << 17
    r.s = x
    lo + Int(x % UInt64(hi - lo + 1))
end
rnd(r::XorShift, lo::Integer, hi::Integer, n::Integer) = [Int32(rnd(r, lo, hi)) for _ in 1:n]

@testset "bulk reading equals per-frame reading" begin
    with_data() do w
        rng = XorShift(0x9e3779b97f4a7c15)
        ranges = Dict(8 => 100, 80 => 127, 16 => 32767, 61 => 32767, 160 => 32767,
                      24 => 8388607, 32 => 2147483647, 212 => 2047, 310 => 511, 311 => 511)
        for fmt in (8, 80, 16, 61, 160, 24, 32, 212, 310, 311), n0 in (1, 2, 3)
            # group 0: n0 signals of format fmt; group 1: 2 signals of format 16
            nf = 3000 + rnd(rng, 0, 2000)
            lim = ranges[fmt]
            x = zeros(Int32, nf, n0 + 2)
            for j in 1:n0
                if fmt == 8
                    x[:, j] = cumsum(rnd(rng, -60, 60, nf))
                else
                    x[:, j] = rnd(rng, -lim, lim, nf)
                    x[rnd(rng, 1, nf, 40), j] .= WFDB_INVALID_SAMPLE
                end
            end
            x[:, n0+1] = rnd(rng, -30000, 30000, nf)
            x[:, n0+2] = rnd(rng, -30000, 30000, nf)
            x[rnd(rng, 1, nf, 20), n0+1] .= WFDB_INVALID_SAMPLE
            si = [Siginfo(fname=Vector{UInt8}(j <= n0 ? "b0.dat" : "b1.dat"),
                          desc=Vector{UInt8}("s$j"), units=Vector{UInt8}("mV"),
                          gain=100.0, group=j <= n0 ? 0 : 1, fmt=j <= n0 ? fmt : 16,
                          adcres=16, spf=1) for j in 1:n0+2]
            W.wfdbquit(w)
            @test W.osigfopen(w, si, n0 + 2) == n0 + 2
            W.setsampfreq(w, 100.0)
            for i in 1:nf
                W.putvec(w, x[i, :])
            end
            @test W.newheader(w, "bk") == 0
            W.wfdbquit(w)
            nsig = n0 + 2
            for mode in (W.WFDB_LOWRES, W.WFDB_LOWRES | W.WFDB_GVPAD, W.WFDB_HIGHRES),
                (from, chunks) in ((0, (1000,)), (0, (7, 1, 4096)), (rnd(rng, 1, nf - 1), (513,)),
                                   (nf - 1, (10,)))
                @test bulk_trace(w, "bk", nsig, true; mode, from, chunks) ==
                      bulk_trace(w, "bk", nsig, false; mode, from, chunks)
            end
            for cols in (nothing, [nsig - 1, 0])
                a = W.read_record(w, "bk"; channels=cols, pad=true)
                W._BULK_ENABLED[] = false
                b = W.read_record(w, "bk"; channels=cols, pad=true)
                W._BULK_ENABLED[] = true
                @test a.samples == b.samples && a.checksum_ok && b.checksum_ok
            end
            # a wrong checksum (the checksum frame), a truncated file
            hea = read("bk.hea", String)
            write("bk.hea", replace(hea, r"(b0\.dat \S+ \S+ \S+ \S+ \S+ )(-?\d+)" =>
                                         s"\g<1>12345"; count=1))
            t = bulk_trace(w, "bk", nsig, true)
            @test t == bulk_trace(w, "bk", nsig, false)
            @test t[end-1][2] == -4
            write("bk.hea", hea)
            open(f -> truncate(f, filesize("b0.dat") - 100), "b0.dat", "r+")
            t = bulk_trace(w, "bk", nsig, true; chunks=(333,))
            @test t == bulk_trace(w, "bk", nsig, false; chunks=(333,))
            @test t[end-1][2] == -3
        end
        # the record of the bulk path (100s, format 212, read in full)
        @test W.read_record(w, "100s").samples ==
              (W._BULK_ENABLED[] = false; r = W.read_record(w, "100s").samples;
               W._BULK_ENABLED[] = true; r)
    end
end

# WFDB-x: records of several sampling frequencies, and multi-segment
# records, are read in bulk too: the same samples as frame by frame.
MF_RANGES = Dict(8 => 30000, 80 => 127, 16 => 32767, 61 => 32767, 160 => 32767,
                       24 => 8388607, 32 => 2147483647, 212 => 2047, 310 => 511, 311 => 511)
MF_RES = Dict(8 => 12, 80 => 8, 16 => 16, 61 => 16, 160 => 16, 24 => 24, 32 => 32,
                    212 => 12, 310 => 10, 311 => 10)

# A random multi-frequency record (spf: samples per frame of each signal; n
# frames), with about 1% invalid samples (and invalid at the start).
function mf_record(w, name, rng, fmt, spf, n; gains=200.0, names=nothing)
    x = zeros(Int32, n, sum(spf))
    lim = MF_RANGES[fmt]
    c = 0
    for sf in spf
        if fmt == 8
            # (a random walk of the signal's samples, in time order)
            v = cumsum(rnd(rng, -60, 60, n * sf))
            x[:, c+1:c+sf] = permutedims(reshape(v, sf, n))
        else
            x[:, c+1:c+sf] = reshape(rnd(rng, -lim + 1, lim, n * sf), n, sf)
        end
        c += sf
    end
    if fmt != 8
        for i in eachindex(x)
            rnd(rng, 1, 100) == 1 && (x[i] = WFDB_INVALID_SAMPLE)
        end
        x[1:2, 1] .= WFDB_INVALID_SAMPLE
    end
    W.write_record(w, name, x, 250.0; fmt, gains, adcres=MF_RES[fmt], units="mV",
                   samps_per_frame=spf, names)
    x
end

MF_MODES = ((;), (; pad=true), (; highres=true), (; highres=true, pad=true),
                  (; physical=true), (; from=1234), (; from=7, to=15000),
                  (; highres=true, from=3, to=9001), (; channels=[1, 0, 1]))

# read_record with the bulk path and with the per-frame path only: the
# samples (physical units with physical=true), checksum_ok, and the number
# of vectors read and read in bulk; or the exception.
function mf_read(w, rec, bulk; physical=false, kw...)
    W._BULK_ENABLED[] = bulk
    W._BULK_VECTORS[] = 0
    try
        r = W.read_record(w, rec; kw...)
        x = physical ? W.physical(r) : r.samples
        return (x, r.checksum_ok, size(r.samples, 1), W._BULK_VECTORS[])
    catch e
        e isa W.WfdbError || rethrow()
        return e
    finally
        W._BULK_ENABLED[] = true
    end
end
function mf_same(w, rec, kw::NamedTuple)
    a = mf_read(w, rec, true; kw...)
    b = mf_read(w, rec, false; kw...)
    a isa Exception && return b isa Exception && typeof(a) == typeof(b)
    b isa Exception && return false
    @test b[4] == 0
    isequal(a[1], b[1]) && a[2] == b[2] && a[3] == b[3]
end

# The most vectors that the bulk path may leave to getvec: the bulk path
# reads only the data in the input buffers, so a few frames at each buffer
# boundary (and near the end) go through getvec (per: vectors per frame).
function nonbulk_max(files, per)
    nbuf = sum(f -> filesize(f) ÷ W.WFDB_BUFSIZ + 1, files)
    3 * per * (nbuf + 4)
end

@testset "bulk reading of multi-frequency records" begin
    with_data() do w
        rng = XorShift(0x2545f4914f6cdd1d)
        for fmt in (8, 80, 16, 61, 160, 24, 32, 212, 310, 311)
            for spf in ([4, 1, 1, 1], [2, 3], [1, 2], [8, 1], [3, 3, 1])
                n = rnd(rng, 16000, 24000)
                mf_record(w, "m", rng, fmt, spf, n)
                for kw in MF_MODES
                    @test mf_same(w, "m", kw)
                end
                # (all but the frames near the end are read in bulk)
                _, ok, rows, nbulk = mf_read(w, "m", true; highres=true)
                @test ok && rows == n * maximum(spf)
                @test rows - nbulk <= nonbulk_max(["m.dat"], maximum(spf))
                _, ok, rows, nbulk = mf_read(w, "m", true)
                @test ok && rows == n && rows - nbulk <= nonbulk_max(["m.dat"], 1)
            end
        end
    end
end

# (writes the segments name_1, ... of the given lengths)
function mf_segments(w, name, rng, fmt, spf, lens; kw...)
    segs = Tuple{String,Int}[]
    for (k, n) in enumerate(lens)
        seg = "$(name)_$k"
        mf_record(w, seg, rng, fmt, spf, n; kw...)
        push!(segs, (seg, n))
    end
    segs
end

@testset "bulk reading of multi-segment records" begin
    with_data() do w
        rng = XorShift(0x9e3779b97f4a7c15 ⊻ 11)
        names = ["ECG", "ABP", "RESP"]
        # fixed layout
        segs = mf_segments(w, "fx", rng, 212, [4, 1, 1], [9000, 7001, 12000]; names)
        write("fx.hea", "fx/3 3 250 $(sum(last, segs))\n" *
                        join(("$s $n\n" for (s, n) in segs)))
        for kw in (MF_MODES..., (; from=8999, to=16002))
            @test mf_same(w, "fx", kw)
        end
        _, ok, rows, nbulk = mf_read(w, "fx", true)
        @test rows == 28001 && rows - nbulk <= nonbulk_max(["fx_$k.dat" for k in 1:3], 1)
        # variable layout: segments with all the signals, a subset in another
        # order with other gains, one signal of another format, and a null
        # segment
        write("vl_0.hea", "vl_0 3 250 0\n" *
                          "~ 0x4 400(10)/mV 12 0 0 0 0 ECG\n" *
                          "~ 0 100/mV 16 0 0 0 0 ABP\n" *
                          "~ 0 50/mV 16 0 0 0 0 RESP\n")
        s1 = mf_segments(w, "va", rng, 16, [4, 1, 1], [5000]; names, gains=[400.0, 100.0, 50.0])
        s2 = mf_segments(w, "vb", rng, 16, [1, 4], [6003]; names=["RESP", "ECG"],
                         gains=[25.0, 200.0])
        s3 = mf_segments(w, "vc", rng, 212, [1], [4000]; names=["ABP"], gains=[100.0])
        segs = [("vl_0", 0); s1; [("~", 2500)]; s2; s3]
        write("vl.hea", "vl/$(length(segs)) 3 250 $(sum(last, segs))\n" *
                        join(("$s $n\n" for (s, n) in segs)))
        W.wfdbquiet(w)
        for kw in (MF_MODES..., (; from=4990, to=9000))
            @test mf_same(w, "vl", kw)
        end
        _, ok, rows, nbulk = mf_read(w, "vl", true)
        @test rows == 17503 && rows - nbulk <= nonbulk_max(["va_1.dat", "vb_1.dat", "vc_1.dat"], 1)
        W.wfdbverbose(w)
        x = W.physical(W.read_record(w, "vl"))
        @test size(x) == (17503, 3)
        @test all(isnan, x[5001:7500, :])       # (the null segment)
    end
end

@testset "bulk reading of the test records" begin
    with_data() do w
        W.wfdbquiet(w)
        for h in sort(filter(f -> endswith(f, ".hea"), readdir(".")))
            rec = h[1:end-4]
            rec in ("8", "16") && continue      # (signals on the standard input)
            for kw in ((;), (; pad=true), (; highres=true), (; highres=true, pad=true),
                       (; from=3))
                @test mf_same(w, rec, kw)
            end
        end
        W.wfdbverbose(w)
    end
end

# The multi-frame reader (getvecs_status) mixed with getvec and isigsettime
# on a multi-frequency record (in high resolution also from the middle of a
# frame): the same vectors, statuses and library state as getvec alone.
function mf_state(w)
    st = w.sig
    (st.istime, st.gvc, [(i.samp, i.info.cksum, i.info.nsamp) for i in st.isd[1:st.nisig]],
     [(g.bp, g.be, g.count, g.data, g.datb, g.stat) for g in st.igd[1:st.nigroup]])
end
@testset "bulk reading interleaved with getvec (multi-frequency)" begin
    with_data() do w
        rng = XorShift(0x0123456789abcdef)
        mf_record(w, "mf", rng, 212, [4, 1, 3], 20001)
        for hr in (false, true)
            mode = (hr ? WFDB_HIGHRES : WFDB_LOWRES) | WFDB_GVPAD
            steps = (('f', 999), ('v', 3), ('f', 4097), ('t', 17), ('v', 1), ('f', 9001),
                     ('v', 2), ('t', 30), ('f', 200000))
            out = Any[]
            for bulk in (true, false)
                W._BULK_ENABLED[] = bulk
                got = Any[]
                try
                    @test W.isigopen(w, "mf", nothing, 3) == 3
                    W.setgvmode(w, mode)
                    for (op, k) in steps
                        if op == 'f'
                            buf = zeros(Int32, 3 * k)
                            n, stat = W.getvecs_status(w, buf, k)
                            push!(got, (n, stat, buf[1:3*max(n, 0)]))
                        elseif op == 'v'
                            for _ in 1:k
                                v = zeros(Int32, 3)
                                push!(got, (W.getvec(w, v), v))
                            end
                        else
                            push!(got, W.isigsettime(w, k))
                        end
                        push!(got, mf_state(w))
                    end
                    W.wfdbquit(w)
                finally
                    W._BULK_ENABLED[] = true
                end
                push!(out, got)
            end
            @test out[1] == out[2]
        end
    end
end

# Descriptions that end (or begin) with white space in the header are given
# without it by the high-level readers, and found by that name; the C-style
# functions keep it, as in C.
@testset "signal names without white space" begin
    with_data() do w
        write("sp.hea", "sp 3 250 4\n" *
                        "fmt16.dat 16 200/mV 16 0 0 0 0 III \n" *
                        "fmt16.dat 16 200/mV 16 0 0 0 0 ABP\t \n" *
                        "fmt16.dat 16 200/mV 16 0 0 0 0 PLETH\n")
        for legacy in (false, true)
            r = W.read_record(w, "sp"; legacy)
            @test String.(W.signal_names(r)) == ["III", "ABP", "PLETH"]
            @test [s.desc for s in r.siginfo] == [b"III", b"ABP", b"PLETH"]
            h = W.read_header(w, "sp"; legacy)
            @test [s.desc for s in h.siginfo] == [b"III", b"ABP", b"PLETH"]
            r2 = W.read_record(w, "sp"; channels=["ABP", "III ", 2], legacy)
            @test String.(W.signal_names(r2)) == ["ABP", "III", "PLETH"]
            @test r2.samples == r.samples[:, [2, 1, 3]]
        end
        si = [Siginfo() for _ in 1:3]
        @test W.isigopen(w, "sp", si, 3) == 3
        @test [s.desc for s in si] == [b"III ", b"ABP\t ", b"PLETH"]
        W.wfdbquit(w)
    end
end

# ---------------------------------------------------------------------------
# WFDB-x: the fast paths of read_record (blocks of frames copied into the
# samples matrix, the tiled bulk decoder), of write_record (bulk frame
# writing) and of rdsamp (integer output), compared with the paths they
# replace.

# The previous read_record: all frames read into one buffer, then
# transposed (the reference for _read_record).
function ref_read_record(w, record, channels, from, to, highres::Bool, pad::Bool)
    rname = W._lossy(record)
    W.wfdbquit(w)
    nsig = W.isigopen(w, record, nothing, 0)
    nsig <= 0 && W._hl_fail(w, "can't read record $rname")
    si = [W.Siginfo() for _ in 1:nsig]
    nsig = W.isigopen(w, record, si, nsig)
    nsig <= 0 && W._hl_fail(w, "can't open signals of record $rname")
    nsig = Int(nsig)
    W.setgvmode(w, (highres ? W.WFDB_HIGHRES : W.WFDB_LOWRES) | (pad ? W.WFDB_GVPAD : Int32(0)))
    fs = W.sampfreq(w, nothing)
    t0 = W._resolve_time(w, from, rname)
    t1 = to === nothing ? nothing : W._resolve_time(w, to, rname)

    W._strip_desc!(si)
    cols = Int[]
    if channels === nothing
        append!(cols, 1:nsig)
    else
        for c in channels
            # (a name: among the names without white space first)
            k = Int32(-1)
            if !(c isa Integer)
                name = W._strip_space(W.cstr(W.bytes(c)))
                for j in 1:nsig
                    if si[j].desc == name
                        k = Int32(j - 1)
                        break
                    end
                end
            end
            k < 0 && (k = W.findsig(w, c isa Integer ? string(c) : c))
            (k < 0 || k >= nsig) && W._hl_fail(w, "record $rname has no signal $c")
            push!(cols, k + 1)
        end
    end
    base_time, base_time_ms, base_date = W._base_info(w, fs)
    W.isigsettime(w, t0) < 0 && W._hl_fail(w, "can't seek to sample $t0 of record $rname")

    # getvec returns one value per signal in either mode. The frames are
    # read straight into `all` (one column per frame), allocated once for
    # the number of frames to read if it is known (to, or the length of the
    # record), and grown only if more are read.
    st = w.sig
    remaining = t1 === nothing ? nothing : max(t1 - t0, Int64(0))
    rlen = (st.in_msrec != 0 ? st.msnsamples : st.nsamples) *
           ((st.gvmode & W.WFDB_HIGHRES) == W.WFDB_HIGHRES ? Int64(st.spfmax) : Int64(1))
    expect = remaining !== nothing ? remaining : rlen > t0 ? rlen - t0 : Int64(W.READ_BLOCK)
    expect = remaining !== nothing && rlen > t0 ? min(expect, rlen - t0) : expect
    # (not more than about 1 GiB at first: a header may overstate the length)
    expect = clamp(expect, Int64(1), max(Int64(1), (Int64(1) << 28) ÷ nsig))
    all = Vector{Int32}(undef, expect * nsig)
    # (a multiple of 6 frames per call, so that formats 212, 310 and 311
    # end each call on a whole packed unit: the frames are then read in
    # bulk)
    unit = 6 * (highres ? max(Int64(st.ispfmax), 1) : Int64(1))
    block = Int64(W.READ_BLOCK) - Int64(W.READ_BLOCK) % unit
    nframes = Int64(0)
    cksum_error = false
    st.cksum_quiet = true
    try
        while remaining === nothing || remaining > 0
            n = remaining === nothing ? block : min(remaining, block)
            nframes + n > length(all) ÷ nsig &&
                resize!(all, max(2 * length(all), (nframes + n) * nsig))
            got, stat = W._getvecs_into(w, all, Int(nframes * nsig), n, true)
            got = max(got, Int64(0))
            nframes += got
            remaining === nothing || (remaining -= got)
            # WFDB-x: -4, a checksum error: the vector is complete, only the
            # sum of the samples does not match the header: a warning (see
            # below), not an error. In high-resolution mode each of the spf
            # vectors of the checksum frame has status -4: read on until -1
            # (the end of the data) or the requested end.
            if stat == -4
                cksum_error = true
                got > 0 && continue
                break
            end
            if got < n
                # WFDB-x: a status below -1 (e.g. -3, unexpected EOF: a
                # signal file shorter than its header says, or a decoder or
                # I/O error) is an error, not the end of the data (-1).
                stat < -1 && W._hl_fail(w, "can't read signal data of record $rname (getvec status $stat)")
                break
            end
        end
    finally
        w.sig.cksum_quiet = false
    end
    samples = ref_frames_to_samples(all, nsig, Int(nframes), cols)
    comments = W._comments(w, record)
    W.wfdbquit(w)
    W.Record(rname, fs, samples, Siginfo[si[k] for k in cols], base_time, base_time_ms,
           base_date, t0, comments, Int[k - 1 for k in cols], !cksum_error)
end

# The samples matrix (one row per frame, one column per element of cols)
# of the first nframes frames stored in v (nsig values per frame).
function ref_frames_to_samples(v::Vector{Int32}, nsig::Int, nframes::Int, cols::Vector{Int})
    frames = reshape(view(v, 1:nsig*nframes), nsig, nframes)
    cols == 1:nsig && return permutedims(frames)
    samples = Matrix{Int32}(undef, nframes, length(cols))
    for (j, c) in enumerate(cols)
        @inbounds for i in 1:nframes
            samples[i, j] = frames[c, i]
        end
    end
    samples
end
# read_record (new) and the reference (bulk reading on or off): the
# samples, checksum_ok, sampfrom and channels, or the exception message.
function hl_result(f)
    try
        r = f()
        return (r.samples, r.checksum_ok, r.sampfrom, r.channels, r.fs, r.base_time)
    catch e
        e isa W.WfdbError || rethrow()
        return e.msg
    end
end
hl_same(w, rec, kw::NamedTuple=(;)) = hl_same_kw(w, rec; kw...)
function hl_same_kw(w, rec; channels=nothing, from=0, to=nothing, highres=false, pad=false)
    W.wfdbquiet(w)
    a = hl_result(() -> W._read_record(w, rec, channels, from, to, highres, pad, false))
    b = hl_result(() -> ref_read_record(w, rec, channels, from, to, highres, pad))
    W._BULK_ENABLED[] = false
    c = try
        hl_result(() -> ref_read_record(w, rec, channels, from, to, highres, pad))
    finally
        W._BULK_ENABLED[] = true
    end
    W.wfdbverbose(w)
    a == b && a == c
end
HL_OPTS = ((;), (; pad=true), (; highres=true), (; highres=true, pad=true), (; from=1234),
           (; from=7, to=15000), (; highres=true, from=3, to=9001), (; channels=[1, 0, 1]),
           (; to=1), (; from=5, to=5))

@testset "read_record equals the previous reader" begin
    with_data() do w
        rng = XorShift(0x5851f42d4c957f2d)
        for fmt in (8, 80, 16, 61, 160, 24, 32, 212, 310, 311)
            for spf in ([1, 1], [4, 1, 1, 1], [2, 3], [1, 2])
                n = rnd(rng, 3000, 9000)
                mf_record(w, "hr", rng, fmt, spf, n)
                for kw in HL_OPTS
                    @test hl_same(w, "hr", kw)
                end
            end
        end
        # the test records
        for h in sort(filter(f -> endswith(f, ".hea"), readdir(".")))
            rec = h[1:end-4]
            rec in ("8", "16") && continue      # (signals on the standard input)
            for kw in ((;), (; pad=true), (; highres=true), (; from=3, to=100))
                @test hl_same(w, rec, kw)
            end
        end
        # multi-segment records: fixed layout, variable layout with a null
        # segment
        names = ["ECG", "ABP", "RESP"]
        segs = mf_segments(w, "fy", rng, 212, [4, 1, 1], [9000, 7001, 12000]; names)
        write("fy.hea", "fy/3 3 250 $(sum(last, segs))\n" * join(("$s $n\n" for (s, n) in segs)))
        write("vm_0.hea", "vm_0 3 250 0\n~ 0x4 400(10)/mV 12 0 0 0 0 ECG\n" *
                          "~ 0 100/mV 16 0 0 0 0 ABP\n~ 0 50/mV 16 0 0 0 0 RESP\n")
        s1 = mf_segments(w, "vma", rng, 16, [4, 1, 1], [5000]; names, gains=[400.0, 100.0, 50.0])
        s2 = mf_segments(w, "vmb", rng, 212, [1], [4000]; names=["ABP"], gains=[100.0])
        segs = [("vm_0", 0); s1; [("~", 2500)]; s2]
        write("vm.hea", "vm/$(length(segs)) 3 250 $(sum(last, segs))\n" *
                        join(("$s $n\n" for (s, n) in segs)))
        for rec in ("fy", "vm"), kw in (HL_OPTS..., (; from=4990, to=9000))
            @test hl_same(w, rec, kw)
        end
        # the length not in the header: shorter and longer than the first
        # allocation (READ_BLOCK frames)
        for n in (5000, W.READ_BLOCK + 1, 2 * W.READ_BLOCK + 7)
            x = mf_record(w, "nl", rng, 212, [1, 1], n)
            write("nl.hea", replace(read("nl.hea", String), r"^nl 2 250 \d+" => "nl 2 250"))
            for kw in ((;), (; channels=[1]), (; from=100), (; to=n + 10), (; highres=true))
                @test hl_same(w, "nl", kw)
            end
            @test W.read_record(w, "nl"; pad=false).samples == x
        end
        # a wrong checksum, a truncated signal file, a header that overstates
        # the length
        mf_record(w, "ck", rng, 16, [1, 1], 7000)
        hea = read("ck.hea", String)
        write("ck.hea", replace(hea, r"(ck\.dat \S+ \S+ \S+ \S+ \S+ )(-?\d+)" => s"\g<1>12345";
                                count=1))
        for kw in ((;), (; highres=true), (; to=7000))
            @test hl_same(w, "ck", kw)
        end
        write("ck.hea", replace(hea, r"^ck 2 250 7000" => "ck 2 250 9000"))
        @test hl_same(w, "ck")
        write("ck.hea", hea)
        open(f -> truncate(f, filesize("ck.dat") - 101), "ck.dat", "r+")
        for kw in ((;), (; to=100), (; from=6000))
            @test hl_same(w, "ck", kw)
        end
    end
end

# The bulk decoder in tiles: many tiles per call (large input buffers),
# with lengths that are not a multiple of the tile.
@testset "bulk reading with large input buffers" begin
    with_data() do w
        rng = XorShift(0x14057b7ef767814f)
        for fmt in (8, 80, 16, 61, 160, 24, 32, 212, 310, 311), spf in ([1, 1, 1], [4, 1], [2, 3])
            n = rnd(rng, 5000, 12000)
            mf_record(w, "tl", rng, fmt, spf, n)
            for mode in (W.WFDB_LOWRES, W.WFDB_LOWRES | W.WFDB_GVPAD, W.WFDB_HIGHRES),
                chunks in ((W._BULK_TILE * 3 + 5,), (7, 2049))
                traces = map((true, false)) do bulk
                    W.wfdbquit(w)
                    W.setibsize(w, 1 << 16)
                    t = bulk_trace(w, "tl", length(spf), bulk; mode, chunks)
                    W.setibsize(w, 0)
                    t
                end
                @test traces[1] == traces[2]
            end
        end
    end
end

# write_record with the bulk writer and with putvec only: the same files,
# messages and errors.
function wr_files(w, bulk, name, x, fs; kw...)
    W._BULK_WRITE[] = bulk
    try
        e = nothing
        err = lib_stderr() do
            e = try
                W.write_record(w, name, x, fs; kw...)
            catch ex
                ex isa W.WfdbError || rethrow()
                ex.msg
            end
        end
        dat = isfile("$name.dat") && !islink("$name.dat") ? read("$name.dat") : UInt8[]
        hea = isfile("$name.hea") ? read("$name.hea") : UInt8[]
        return (e, err, dat, hea)
    finally
        W._BULK_WRITE[] = true
    end
end

@testset "bulk writing equals putvec" begin
    with_data() do w
        rng = XorShift(0x2545f4914f6cdd1d ⊻ 99)
        for fmt in (16, 61, 80, 160, 24, 32, 8, 212, 310, 311)
            lim = MF_RANGES[fmt]
            for spf in ([1], [1, 1], [4, 1, 1, 1], [2, 3], [1, 2]),
                n in (1, 2, 1000, 8191, rnd(rng, 3000, 30000))
                x = reshape(rnd(rng, -lim + 1, lim, n * sum(spf)), n, sum(spf))
                fmt == 8 && (x .= clamp.(x, -100, 100))
                for i in eachindex(x)
                    rnd(rng, 1, 50) == 1 && (x[i] = WFDB_INVALID_SAMPLE)
                end
                x[1, 1] = WFDB_INVALID_SAMPLE
                x[end, end] = WFDB_INVALID_SAMPLE
                kw = (; fmt, gains=200.0, adcres=MF_RES[fmt], units="mV", samps_per_frame=spf)
                a = wr_files(w, true, "bw", x, 250.0; kw...)
                b = wr_files(w, false, "bw", x, 250.0; kw...)
                @test a == b
                @test a[1] === nothing && isempty(a[2])
                # (the samples, in other integer types and a view)
                @test wr_files(w, true, "bw", Int64.(x), 250.0; kw...) == b
                @test wr_files(w, true, "bw", view(x, :, :), 250.0; kw...) == b
            end
        end
        # physical units (NaN: invalid)
        y = randn(5000, 3) .* 2
        y[[1, 77, 5000], [1, 3, 2]] .= NaN
        for bulk in (true, false)
            W._BULK_WRITE[] = bulk
            W.write_record_physical(w, bulk ? "pb" : "pp", y, 360.0; gains=1000.0, adcres=16,
                                    units="mV", fmt=16)
            W._BULK_WRITE[] = true
        end
        @test read("pb.dat") == read("pp.dat")
        # a signal file on which every write fails
        if ispath("/dev/full")
            r = map((true, false)) do bulk
                rm("bf.dat"; force=true)
                symlink("/dev/full", "bf.dat")
                t = wr_files(w, bulk, "bf", zeros(Int32, 20000, 2), 250.0; gains=200.0,
                             adcres=16, units="mV")
                rm("bf.dat")
                t
            end
            @test r[1] == r[2] && r[1][1] == "write error on record bf"
        end
    end
end

# rdsamp's integer formatter (raw units), against printf.
@testset "rdsamp integers as printf" begin
    rng = XorShift(0x6a09e667f3bcc908)
    vals = Int64[0, 1, -1, 9, 10, -10, 99, 100, 999, 1000, -32768, 32767, 9999999, 10000000,
                 typemax(Int32), typemin(Int32), typemax(Int64), typemin(Int64), 10^18, 10^19 - 1,
                 -10^18]
    for _ in 1:2000
        push!(vals, rnd(rng, -10^rnd(rng, 0, 9), 10^rnd(rng, 0, 9)))
    end
    for v in vals, lead in (0x00, UInt8('\t'), UInt8(',')), width in (0, 1, 7, 15, 25)
        buf = fill(0xee, 64)
        p = W._rdsamp_put_integer!(buf, 3, lead, v, width)
        fmt = (lead == 0 ? "" : string(Char(lead))) * "%$(width)ld"
        @test buf[4:p] == W.cformat(fmt, v) && all(==(0xee), buf[[1:3; p+1:end]])
    end
end

# rdsamp in raw units: the lines as printf writes them, over several blocks
# of frames and output buffers.
@testset "rdsamp raw output" begin
    with_data() do w
        rng = XorShift(0x3c6ef372fe94f82b)
        x = mf_record(w, "rr", rng, 16, [1, 1, 1], 3 * W._RDSAMP_CHUNK + 77)
        env = ("WFDBX_INPUT_DIR" => ".",)
        for (args, rows, cols, csv) in ((String[], 1:size(x, 1), 1:3, false),
                                        (["-c"], 1:size(x, 1), 1:3, true),
                                        (["-s", "2", "0"], 1:size(x, 1), [3, 1], false),
                                        (["-f", "s5000", "-t", "s9001", "-c", "-s", "1"],
                                         5001:9001, [2], true))
            st, out, err = W.run_tool("rdsamp", ["-r", "rr", args...]; env=env)
            want = UInt8[]
            for i in rows
                append!(want, W.cformat(csv ? "%ld" : "%15ld", Int64(i - 1)))
                for c in cols
                    append!(want, W.cformat(csv ? ",%d" : "\t%7d", x[i, c]))
                end
                push!(want, UInt8('\n'))
            end
            @test st == 0 && isempty(err) && out == want
        end
    end
end

end

# A signal file or header that cannot be written (a link to /dev/full, on
# which every write fails) throws an error, in both modes, after the
# library's messages.
@testset "write_record write error" begin
    if !ispath("/dev/full")
        @test_skip "no /dev/full on this system"
    else
        with_data() do w
            for target in ("full.dat", "full.hea"), n in (10, 100000), legacy in (false, true)
                rm(target; force=true)
                symlink("/dev/full", target)
                before = W.wfdbx_write_errors()
                local e
                err = lib_stderr() do
                    e = try
                        W.write_record(w, "full", zeros(Int32, n, 2), 250.0; gains=200.0,
                                       adcres=16, units="mV", legacy)
                    catch x
                        x
                    end
                end
                @test e isa W.WfdbError && e.msg == "write error on record full"
                @test W.wfdbx_write_errors() > before
                @test occursin("osigclose: write error", err)
                rm(target)
            end
            # write_record_physical
            rm("full.dat"; force=true)
            symlink("/dev/full", "full.dat")
            local e
            err = lib_stderr() do
                e = try
                    W.write_record_physical(w, "full", zeros(10, 1), 250.0; gains=200.0,
                                            adcres=16, units="mV")
                catch x
                    x
                end
            end
            @test e isa W.WfdbError && e.msg == "write error on record full"
            @test occursin("osigclose: write error in signal group 0", err)
        end
    end
end

# The columns of the samples must add up to a whole frame, and each signal
# has at least one sample per frame; nothing is written otherwise.
@testset "write_record frame checks" begin
    with_data() do w
        x = Int32.(reshape(0:7, 2, 4)')         # 4 frames, 2 columns
        kw = (gains=200.0, adcres=16, units="mV")
        for (spf, msg) in (([1], "write_record: signals has 2 columns, but samps_per_frame adds up to 1"),
                           ([3], "adds up to 3"), ([1, 2], "adds up to 3"), (3, "adds up to 6"),
                           ([0, 2], "integers >= 1"), ([2, 0], "integers >= 1"),
                           ([-1, 3], "integers >= 1"), ([1.5, 0.5], "integers >= 1"),
                           (0, "integers >= 1"))
            for legacy in (false, true), f in (W.write_record, W.write_record_physical)
                e = try
                    f(w, "bad", f === W.write_record ? x : Float64.(x), 250.0;
                      samps_per_frame=spf, legacy, kw...)
                catch err
                    err
                end
                @test e isa W.WfdbError && endswith(e.msg, msg)
                @test !isfile("bad.hea") && !isfile("bad.dat")
            end
        end
        # (checked before the other arguments: no gains, fs 0, a bad dir)
        e = try
            W.write_record(w, "bad", x, 0.0; samps_per_frame=[0, 2], dir="nosuch")
        catch err
            err
        end
        @test e isa W.WfdbError && e.msg == "write_record: samps_per_frame must hold integers >= 1"
        W.write_record(w, "good", x, 250.0; samps_per_frame=[2], kw...)
        @test size(W.read_record(w, "good").samples) == (4, 1)
        W.write_record(w, "good", x, 250.0; samps_per_frame=[1, 1], kw...)
        @test W.read_record(w, "good").samples == x
        W.write_record(w, "good", x, 250.0; samps_per_frame=[1.0, 1.0], kw...)
        @test W.read_record(w, "good").samples == x
    end
end

@testset "write error count" begin
    n = W.wfdbx_write_errors()
    W.wfdbx_note_write_error()
    @test W.wfdbx_write_errors() == n + 1
    # (an input file, and an output file written without error, do not count)
    d = tmpdir("wrcount")
    f = W.wfdb_fopen(joinpath(d, "ok"), "wb")
    W.fwrite(f, b"abc")
    @test W.fclose(f) == 0
    f = W.wfdb_fopen(joinpath(d, "ok"), "rb")
    @test W.fclose(f) == 0
    @test W.wfdbx_write_errors() == n + 1
    if ispath("/dev/full")
        f = W.wfdb_fopen("/dev/full", "wb")
        W.fwrite(f, b"abc")
        @test W.fclose(f) == W.EOF
        @test W.wfdbx_write_errors() == n + 2
        # a file that a tool writes itself: counted by wfdbx_fclose_output
        f = W.cfopen("/dev/full", "wb")
        W.fwrite(f, b"abc")
        err = lib_stderr() do
            @test W.wfdbx_fclose_output(f, "tool", "/dev/full") == W.EOF
        end
        @test err == "tool: write error on /dev/full\n"
        @test W.wfdbx_write_errors() == n + 3
    end
    rm(d; recursive=true, force=true)
end


# Fixes from the second review (WFDB-x 1.1.0).

@testset "read_record restores the getvec mode" begin
    with_data() do w
        # read_record sets the getvec mode for its own reading only: the mode
        # set before the call is in force afterwards, after an error too.
        for mode in (W.WFDB_LOWRES, W.WFDB_HIGHRES | W.WFDB_GVPAD)
            W.setgvmode(w, mode)
            hi = mode == W.WFDB_LOWRES
            r = W.read_record(w, "mfreq"; highres=hi, pad=hi)
            @test r.fs == (hi ? 400.0 : 100.0)
            @test W.getgvmode(w) == mode
            @test hlerr(() -> W.read_record(w, "nosuch"; highres=true, pad=true)) ==
                  "can't read record nosuch"
            @test W.getgvmode(w) == mode
        end
        W.setgvmode(w, W.WFDB_LOWRES)
        W.read_record(w, "mfreq"; highres=true)
        @test isig(w, "mfreq") == 3
        @test W.sampfreq(w, nothing) == 100.0
    end
end

@testset "read_record: negative from" begin
    with_data() do w
        # A negative from is an error (it was taken as an absolute time).
        for from in (-5, -1)
            @test hlerr(() -> W.read_record(w, "fmt16"; from=from, to=3)) ==
                  "read_record: from must not be negative"
        end
        @test size(W.read_record(w, "fmt16"; from=0, to=3).samples, 1) == 3
        n = size(W.read_record(w, "fmt16").samples, 1)
        @test size(W.read_record(w, "fmt16"; from=5, to=typemax(Int64)).samples, 1) == n - 5
        @test size(W.read_record(w, "fmt16"; from=5, to=typemin(Int64)).samples, 1) == 0
    end
end

@testset "segments with skew or a byte offset" begin
    with_data() do w
        # A block read deskews a segment opened during the read (C: 18 rows,
        # the last 114 115).
        write("a.dat", reinterpret(UInt8, htol.(Int16.(0:19))))
        write("b.dat", reinterpret(UInt8, htol.(Int16.(100:119))))
        write("a.hea", "a 2 100 10\na.dat 16 200/mV 12 0 0 0 0 x\na.dat 16 200/mV 12 0 1 0 0 y\n")
        write("b.hea", "b 2 100 10\nb.dat 16 200/mV 12 0 100 0 0 x\n" *
                       "b.dat 16:2 200/mV 12 0 101 0 0 y\n")
        write("m.hea", "m/2 2 100 20\na 10\nb 10\n")
        r = W.read_record(w, "m")
        @test size(r.samples, 1) == 18
        @test r.samples[end, :] == Int32[114, 115]
        @test r.samples[10:11, :] == Int32[18 19; 100 101]
        # A segment with a byte offset (C: one frame, an invalid sample).
        write("o.dat", b"ABCD")
        write("o.hea", "o 1 1000 0\no.dat 16+4 200 16 0 0 0 0 x\n")
        write("p.dat", UInt8.(0:7))
        write("p.hea", "p 1 1000 2\np.dat 16x2 200 16 0 0 0 0 y\n")
        write("ms.hea", "ms/2 1 1000 2\no 0\np 2\n")
        W.wfdbquiet(w)
        @test W.isigopen(w, "ms", nothing, 1) == 1
        v = zeros(Int32, 4)
        @test W.getvecs(w, v, 4) == 1
        @test v[1] == WFDB_INVALID_SAMPLE
        W.wfdbverbose(w)
    end
end

@testset "EDF signals with no samples" begin
    with_data() do w
        # An EDF file whose samples-per-record fields are 0: the signal
        # group is at the end of its data at once.
        d = read("fmt16.edf")
        ns = parse(Int, String(d[253:256]))
        off = 256 + ns * 216
        d[off+1:off+8*ns] .= UInt8(' ')
        d[off+1:8:off+8*ns] .= UInt8('0')
        write("z.edf", d)
        W.wfdbquiet(w)
        @test W.isigopen(w, "z.edf", nothing, ns) == ns
        v = zeros(Int32, 2 * ns)
        @test W.getvec(w, v) == -1
        @test W.getvecs(w, v, 2) == -1
        @test size(W.read_record(w, "z.edf").samples, 1) == 0
        W.wfdbverbose(w)
    end
end

@testset "damaged FLAC files" begin
    with_data() do w
        W.wfdbquiet(w)
        data = read("flac16.dat")
        full = W.read_record(w, "flac16").samples
        # Every sample before a damaged frame is returned (frames start at
        # bytes 86, 16671 and 32883; a truncated last frame).
        write("flac16.dat", data[1:end-1])
        @test W.isigopen(w, "flac16", nothing, 3) == 3
        v = zeros(Int32, 3 * 9000)
        @test W.getvecs(w, v, 9000) == 8192
        @test reshape(v[1:3*8192], 3, :) == permutedims(full[1:8192, :])
        # A trailing byte is ignored.
        write("flac16.dat", [data; 0xff])
        @test W.read_record(w, "flac16").samples == full
        # A bit flipped in frame 0: seeking past it works.
        bad = copy(data)
        bad[87+100] ⊻= 0x01
        write("flac16.dat", bad)
        @test W.isigopen(w, "flac16", nothing, 3) == 3
        @test W.isigsettime(w, 600) < 0
        @test W.isigsettime(w, 5000) == 0
        @test W.getvec(w, v) == 3 && v[1:3] == full[5001, :]
        # Each frame gives its own number of channels (STREAMINFO says 6).
        bad = copy(data)
        bad[21] = (bad[21] & ~0x0e) | UInt8((6 - 1) << 1)
        write("flac16.dat", bad)
        @test W.read_record(w, "flac16").samples == full
        W.wfdbverbose(w)
    end
end

@testset "writers check their arguments first" begin
    with_data() do w
        W.wfdbquiet(w)
        kw = (gains=200.0, adcres=16, units="mV")
        # Samples in ADC units within the range of Int32; physical values
        # finite and within it.
        for (x, physical, msg) in
            ((Int64[2^33 + 5 2^31], false, "write_record: samples in ADC units must be " *
                                           "within the range of a 32-bit integer"),
             (Int64[-2^31 - 1 0], false, "write_record: samples in ADC units must be " *
                                         "within the range of a 32-bit integer"),
             ([Inf 1.0], true, "write_record: signal 0 has a sample that is infinite or " *
                               "beyond the range of 32-bit ADC units"),
             ([1.0 -Inf], true, "write_record: signal 1 has a sample that is infinite or " *
                                "beyond the range of 32-bit ADC units"),
             ([2e7 1.0], true, "write_record: signal 0 has a sample that is infinite or " *
                               "beyond the range of 32-bit ADC units"))
            f = physical ? W.write_record_physical : W.write_record
            @test hlerr(() -> f(w, "x", x, 100.0; fmt=32, kw...)) == msg
            @test !isfile("x.dat") && !isfile("x.hea")
            @test w.sig.nosig == 0
        end
        # Per-signal vectors: one value, or one per signal.
        x = zeros(Int32, 4, 2)
        for (name, v) in ((:gains, [200.0, 200.0, 200.0]), (:adcres, [16, 16, 16]),
                          (:units, ["mV", "mV", "mV"]), (:names, ["a", "b", "c"]),
                          (:baselines, [0, 0, 0]), (:adczeros, [0, 0, 0]))
            @test hlerr(() -> W.write_record(w, "x", x, 100.0; kw..., (name => v,)...)) ==
                  "write_record: $name must have one value per signal"
            @test !isfile("x.dat") && !isfile("x.hea")
        end
        W.write_record(w, "x", Int64[2^31-1 -2^31+1], 100.0; fmt=32, gains=200.0, adcres=32,
                       units="mV")
        @test W.read_record(w, "x").samples == Int32[2^31-1 -2^31+1]
        W.write_record_physical(w, "x", [NaN 1.0], 100.0; kw...)
        @test W.read_record(w, "x").samples == Int32[WFDB_INVALID_SAMPLE 200]
        # Per-annotation fields: empty, or one element per annotation.
        t = [10, 20, 30]
        for (name, a) in
            (("aux", Annotations(samples=t, symbols=[b"N", b"V", b"N"], aux=[b"x"])),
             ("symbols", Annotations(samples=t, symbols=[b"N", b"V"])),
             ("codes", Annotations(samples=t, codes=[1, 1, 1, 1])),
             ("subtypes", Annotations(samples=t, codes=[1, 1, 1], subtypes=[1, 2])),
             ("chans", Annotations(samples=t, codes=[1, 1, 1], chans=[1, 2, 3, 4])),
             ("nums", Annotations(samples=t, codes=[1, 1, 1], nums=[0])))
            @test hlerr(() -> W.write_annotations(w, "100s", "bad", a)) ==
                  "write_annotations: $name must have one entry per annotation (3), or none"
            @test !isfile("100s.bad")
            @test isempty(w.ann.oad)
        end
        # A later call works normally.
        W.write_annotations(w, "100s", "ok", Annotations(samples=t, codes=[1, 5, 1],
                                                         chans=[0, 1, 2]))
        a = W.read_annotations(w, "100s", "ok")
        @test a.samples == t && a.codes == [1, 5, 1] && a.chans == [0, 1, 2]
        W.wfdbverbose(w)
    end
end

@testset "annotation subtypes, channels and numbers are C chars" begin
    if isdefined(W, :getann)    # (annot.jl)
        with_data() do w
            # subtyp and num are signed chars, and chan an unsigned char, in
            # C: a value is wrapped to one byte before it is encoded, giving
            # the bytes that C's putann writes (those of the C wrann for
            # "N 300 0 0", "N 0 300 0", "N 0 0 300", "N -200 0 0" and
            # "N 256 0 0" at samples 1 to 5).
            c_bytes = UInt8[0x01, 0x04, 0x2c, 0xf4, 0x01, 0x04, 0x2c, 0xf8, 0x01, 0x04, 0x00,
                            0xf8, 0x2c, 0xf0, 0x01, 0x04, 0x38, 0xf4, 0x00, 0xf0, 0x01, 0x04,
                            0x00, 0x00]
            sub, chan, num = [300, 0, 0, -200, 256], [0, 300, 0, 0, 0], [0, 0, 300, 0, 0]
            W.write_annotations(w, "100s", "sub", Annotations(samples=1:5, codes=fill(1, 5),
                                                              subtypes=sub, chans=chan, nums=num))
            @test read("100s.sub") == c_bytes
            @test W.annopen(w, "100s", [Anninfo("sub2", WFDB_WRITE)], 1) == 0
            for k in 1:5
                W.putann(w, 0, Annotation(time=k, anntyp=1, subtyp=sub[k] % Int8,
                                          chan=chan[k] % UInt8, num=num[k] % Int8))
            end
            W.wfdbquit(w)
            @test read("100s.sub2") == c_bytes
            a = W.read_annotations(w, "100s", "sub")
            @test a.subtypes == [44, 0, 0, 56, 0]
            @test a.chans == [0, 44, 0, 0, 0]
            @test a.nums == [0, 0, 44, 0, 0]
        end
    else
        @test_skip "annot.jl"
    end
end

# The state of the library after a high-level call: nothing open.
closed(w) = w.sig.nisig == 0 && w.sig.nosig == 0 && isempty(w.ann.iad) && isempty(w.ann.oad)

@testset "high-resolution reads always progress" begin
    with_data() do w
        # Blocks of whole packed units of the largest frame: at least one
        # unit, even when a frame holds more samples than a block (a block
        # of 0 frames read nothing, and the read did not finish).
        spf = vcat([1024], fill(1, 511))
        W.write_record(w, "mixed", zeros(Int32, 1, sum(spf)), 1; samps_per_frame=spf,
                       gains=200, adcres=16, units="mV", names=["s$k" for k in 0:511])
        @test size(W.read_record(w, "mixed"; highres=true, to=1).samples) == (1, 512)
        @test size(W.read_record(w, "mixed"; highres=true).samples) == (1024, 512)
        @test size(W.read_record(w, "mixed").samples) == (1, 512)
        x = Int32.((0:2*16384-1) .% 1000)
        W.write_record(w, "big", permutedims(reshape(x, 16384, 2)), 1;
                       samps_per_frame=[16384], gains=200, adcres=16, units="mV")
        r = W.read_record(w, "big"; highres=true, to=1)
        @test r.samples == reshape(Int32[0], 1, 1)
        r = W.read_record(w, "big"; highres=true)
        @test vec(r.samples) == x
        @test size(W.read_record(w, "big"; highres=true, from=16380, to=16390).samples, 1) == 10
        @test closed(w)
    end
end

@testset "write_record checks its metadata first" begin
    with_data() do w
        W.wfdbquiet(w)
        x = Int32[1 2; 3 4]
        kw = (gains=200.0, adcres=16, units="mV")
        nofiles() = !isfile("x.dat") && !isfile("x.hea") && closed(w)
        for (args, msg) in
            (((x, Inf), "write_record: the sampling frequency must be finite"),
             ((x, NaN), "write_record: the sampling frequency must be > 0"),
             ((x, -Inf), "write_record: the sampling frequency must be > 0"),
             ((zeros(Int32, 3, 0), 100.0), "write_record: at least one signal is required"))
            @test hlerr(() -> W.write_record(w, "x", args...; kw...)) == msg
            @test nofiles()
            @test hlerr(() -> W.write_record_physical(w, "x", Float64.(args[1]), args[2];
                                                      kw...)) == msg
            @test nofiles()
        end
        # (legacy mode: no frequency is required, but it must be finite)
        @test hlerr(() -> W.write_record(w, "x", x, Inf; legacy=true)) ==
              "write_record: the sampling frequency must be finite"
        @test nofiles()
        for g in (NaN, Inf, -Inf, [200.0, NaN], [Inf, 200.0])
            @test hlerr(() -> W.write_record(w, "x", x, 100.0; kw..., gains=g)) ==
                  "write_record: gains must be finite"
            @test nofiles()
            @test hlerr(() -> W.write_record_physical(w, "x", Float64.(x), 100.0; kw...,
                                                      gains=g)) ==
                  "write_record: gains must be finite"
            @test nofiles()
        end
        @test hlerr(() -> W.write_record(w, "", x, 100.0; kw...)) ==
              "write_record: the record name must not be empty"
        @test hlerr(() -> W.write_record_physical(w, b"", Float64.(x), 100.0; kw...)) ==
              "write_record: the record name must not be empty"
        @test !isfile(".dat") && !isfile(".hea") && closed(w)
        for bt in ("garbage", "bad time")
            @test hlerr(() -> W.write_record(w, "x", x, 100.0; kw..., base_time=bt)) ==
                  "write_record: incorrect base time '$bt'"
            @test nofiles()
            @test hlerr(() -> W.write_record_physical(w, "x", Float64.(x), 100.0; kw...,
                                                      base_time=bt)) ==
                  "write_record: incorrect base time '$bt'"
            @test nofiles()
        end
        # Per-signal vectors: one value for all signals, or one per signal
        # (units too, also when a signal is uncalibrated).
        x3 = Int32[1 2 3]
        @test hlerr(() -> W.write_record(w, "x", x3, 100.0; gains=[200.0, 0.0, 0.0], adcres=16,
                                         units=["mV", "mV"])) ==
              "write_record: units must have one value per signal"
        @test nofiles()
        # A gain of 0 is uncalibrated, a negative gain is allowed, and a valid
        # base time is written.
        W.write_record(w, "x", x, 100.0; gains=[0.0, -200.0], adcres=16, units=[nothing, "mV"],
                       base_time="12:30:05 02/03/2020")
        h = W.read_header(w, "x")
        @test [s.gain for s in h.siginfo] == [0.0, -200.0]
        @test h.base_time_ms == (12 * 3600 + 30 * 60 + 5) * 1000
        @test W.read_record(w, "x").samples == x
        @test closed(w)
        W.wfdbverbose(w)
    end
end

@testset "write_annotations checks its arguments first" begin
    with_data() do w
        t = [10, 20, 30]
        for fs in (NaN, Inf, -Inf, -1.0)
            @test hlerr(() -> W.write_annotations(w, "100s", "bad", Annotations(samples=t,
                                                  codes=[1, 1, 1]); fs=fs)) ==
                  "write_annotations: fs must be finite and > 0 (or 0: none)"
            @test !isfile("100s.bad") && closed(w)
        end
        # Times are WFDB_Time values (Int64): others cannot be given.
        for s in ([1.5], [NaN], [Inf], [2.0^70], [big(2)^70])
            @test_throws InexactError Annotations(samples=s)
        end
        # symbols and codes together: they must agree (an empty symbol agrees
        # with any code).
        a = Annotations(samples=t, symbols=[b"N", b"V", b"N"], codes=Int32[1, 1, 1])
        @test hlerr(() -> W.write_annotations(w, "100s", "bad", a)) ==
              "write_annotations: symbols and codes disagree at annotation 1"
        @test !isfile("100s.bad") && closed(w)
        a = Annotations(samples=t, symbols=[b"N", b"", b"V"], codes=Int32[1, 42, W.PVC])
        W.write_annotations(w, "100s", "ok", a)
        r = W.read_annotations(w, "100s", "ok")
        @test r.codes == [1, 42, W.PVC] && r.symbols[[1, 3]] == [b"N", b"V"]
        W.write_annotations(w, "100s", "ok2", r)
        @test W.read_annotations(w, "100s", "ok2").codes == r.codes
        # read_annotations -> write_annotations: a round trip.
        atr = W.read_annotations(w, "100s", "atr")
        @test !any(isempty, atr.symbols)
        W.write_annotations(w, "100s", "cpy", atr)
        cpy = W.read_annotations(w, "100s", "cpy")
        @test cpy.samples == atr.samples && cpy.codes == atr.codes && cpy.aux == atr.aux &&
              cpy.symbols == atr.symbols && cpy.subtypes == atr.subtypes
        @test closed(w)
    end
end

@testset "read_record: whole sample numbers; closed on any error" begin
    with_data() do w
        W.wfdbquiet(w)
        for (kw, msg) in (((from=1.5,), "read_record: from must be a whole number"),
                          ((from=NaN,), "read_record: from must be a whole number"),
                          ((from=Inf,), "read_record: from must be a whole number"),
                          ((to=2.5,), "read_record: to must be a whole number"),
                          ((to=NaN,), "read_record: to must be a whole number"),
                          ((to=-Inf,), "read_record: to must be a whole number"),
                          ((to=Inf,), "read_record: to must be a whole number"),
                          ((from=2.0^63,), "read_record: from is beyond the range of a 64-bit integer"),
                          ((to=big(2)^64,), "read_record: to is beyond the range of a 64-bit integer"),
                          ((from=:x,), "read_record: from must be a sample number or a time string"))
            @test hlerr(() -> W.read_record(w, "fmt16"; kw...)) == msg
            @test closed(w)
        end
        @test W.read_record(w, "fmt16"; from=2.0, to=5.0).samples ==
              W.read_record(w, "fmt16"; from=2, to=5).samples
        @test size(W.read_record(w, "fmt16"; from=2, to=Int32(5)).samples, 1) == 3
        # Any error after the record is opened closes it, and restores the
        # settings.
        W.setgvmode(w, W.WFDB_LOWRES)
        for ch in ([99], ["nosuch"], [:x])
            @test_throws Exception W.read_record(w, "fmt16"; channels=ch, highres=true,
                                                 legacy=true)
            @test closed(w)
            @test W.getgvmode(w) == W.WFDB_LOWRES && W.wfdbx_get_legacy(w) == 0
        end
        @test_throws Exception W.read_annotations(w, "100s", "atr"; from=:x)
        @test closed(w)
        W.wfdbverbose(w)
    end
end

@testset "edf2mit: incomplete EDF header" begin
    d = tmpdir("edf")
    for n in (0, 5, 8, 100, 255)
        write(joinpath(d, "t.edf"), [Vector{UInt8}("0       "); fill(UInt8('x'), 300)][1:n])
        st, out, err = W.run_tool("edf2mit", ["-i", "t.edf", "-r", "o"]; dir=d)
        @test st == 2 && isempty(out)
        @test err == b"edf2mit: incomplete EDF header in t.edf\n"
        @test readdir(d) == ["t.edf"]
    end
    # Another format: the usual message; the header is kept, as in C.
    write(joinpath(d, "t.edf"), b"ABCDEFGH")
    st, out, err = W.run_tool("edf2mit", ["-i", "t.edf", "-r", "o"]; dir=d)
    @test st == 2
    @test err == b"edf2mit: input does not appear to be EDF -- no conversion attempted.\n"
    @test isfile(joinpath(d, "o.hea"))
    rm(d; recursive=true)
end
