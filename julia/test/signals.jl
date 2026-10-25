# Tests of the signal functions (signal.jl) and of the high-level API
# (highlevel.jl): ported from rust/tests/signals.rs (expected values
# produced by the C library).
#
# Part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
    cd(d) do
        try
            f(w)
        finally
            W.wfdbquit(w)
        end
    end
    rm(d; recursive=true, force=true)
end

isig(w, rec) = W.isigopen(w, rec, nothing, 8)

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
        @test W.adumuv(w, 7, 100) == WFDB_INVALID_SAMPLE   # wfdb-x: no default gain
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
        isig(w, "null")     # gain 0 (wfdb-x: no default gain)
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
        h = W.read_header(w, "hw")
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

# wfdb-x: no default sampling frequency or gain (t_nodefaults of
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

# wfdb-x legacy mode (t_legacy of tests/reference/api_expect.c; see
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

hlerr(f) = try
    f()
    nothing
catch e
    e isa W.WfdbError || rethrow()
    e.msg
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
        h = W.read_header(w, "wn")
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
        @test all(s -> s.units === nothing, W.read_header(w, "wn"))
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

# wfdb-x: the legacy option of the high-level functions (the behavior of
# the port before wfdb-x removed the built-in defaults).
@testset "high-level API legacy option" begin
    with_data() do w
        W.wfdbquiet(w)
        write("nf.hea", NF_HEA)
        x = Int32[1 2; 3 4]
        # write_record: gain 200, resolution from the format, no units needed
        W.write_record(w, "wl", x, 100.0; legacy=true)
        h = W.read_header(w, "wl")
        @test all(s -> s.gain == 200.0 && s.adcres == 16 && s.units === nothing, h)
        W.write_record(w, "wl", x, 100.0; fmt=212, legacy=true)
        @test all(s -> s.adcres == 12, W.read_header(w, "wl"))
        @test W.wfdbx_get_legacy(w) == 0            # restored
        # The library's legacy mode also applies (without legacy=true)
        W.wfdbx_set_legacy(w, true)
        W.write_record(w, "wg", x, 100.0)
        W.wfdbx_set_legacy(w, false)
        @test all(s -> s.gain == 200.0 && s.adcres == 16, W.read_header(w, "wg"))
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
        @test all(s -> s.adcres == 12, W.read_header(w, "nr"; legacy=true))
        @test all(s -> s.adcres == 0, W.read_header(w, "nr"))
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
        env = ("WFDB" => ".",)
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
        env = ("WFDB" => ".",)
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
# wfdb-x: the output directory (wfdbx_set_output_dir), the in-process sorting
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

end
