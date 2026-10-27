# Tests of the annotation and calibration functions (annot.jl, calib.jl),
# ported from rust/tests/annotations.rs (themselves ports of the annotation
# parts of cpp/tests/test_api.cpp and cpp/tests/test_api_c.cpp). The
# expected values were produced by the original C library.
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

# Run f(w) in a fresh copy of tests/data (the current directory), with a new
# library state whose WFDB path is ".".
function with_data(f, name)
    data = W.workload_data_source()
    d = tmpdir("ann-" * name)
    for x in readdir(data)
        p = joinpath(data, x)
        isfile(p) && cp(p, joinpath(d, x))
    end
    try
        keeping_wfdb_env() do
            cd(d) do
                w = Wfdb()
                W.setwfdb(w, ".")
                f(w)
            end
        end
    finally
        rm(d; recursive=true, force=true)
    end
end

unhex(h) = (d = replace(h, " " => ""); UInt8[parse(UInt8, d[i:i+1]; base=16) for i in 1:2:length(d)])
hexs(b) = join(string(c; base=16, pad=2) for c in b)

# getann: status, time, anntyp, subtyp, chan, num.
function annv(w, n)
    a = Annotation()
    st = W.getann(w, n, a)
    Int64[st, a.time, a.anntyp, a.subtyp, a.chan, a.num]
end

ai1(name, stat) = [Anninfo(name, stat)]
mkaux(s) = UInt8[length(s) % UInt8; Vector{UInt8}(s)]

@testset "annopen errors" begin
    with_data("errors") do w
        W.wfdbquiet(w)
        @test W.annopen(w, "nosuch", ai1("atr", WFDB_READ), 1) == -3
        @test W.wfdberror(w) == b"annopen: can't read annotator atr for record nosuch\n"
    end
end

@testset "annotations read" begin
    with_data("read") do w
        @test W.annopen(w, "100s", ai1("atr", WFDB_READ), 1) == 0
        a = Annotation()
        v = Annotation[]
        while W.getann(w, 0, a) == 0
            push!(v, copy(a))
        end
        @test length(v) == 75
        @test W.annstr(w, v[1].anntyp) == b"+"
        @test W.annstr(w, v[2].anntyp) == b"N"
        # (the aux string of the file includes its terminating null)
        @test W.cstr(v[1].aux[2:end]) == b"(N"
        W.wfdbquit(w)
    end
end

@testset "API as in C" begin
    with_data("apic") do w
        W.wfdbquiet(w)
        out = IOBuffer()
        times = Int64[0, 5, 5, 5, 300, 70000, 70001, 5000000000, 5000000000, 4000000000, 10,
                      3000000000]
        codes = [W.NOTE, W.NORMAL, W.NORMAL, W.NORMAL, W.PVC, W.ARFCT, W.RHYTHM, W.NORMAL,
                 W.NOISE, W.NORMAL, 0, W.VFON]
        chans = [0, 0, 1, 1, 0, 3, 0, 0, 2, 200, 0, 5]
        nums = [0, 0, 0, 2, 0, -1, 0, 0, 1, 0, 3, -128]
        subs = [0, 0, 0, 0, 3, 0, 0, 0, -1, 0, 0, 7]
        auxes = Dict(1 => mkaux("start"), 7 => mkaux("(AFIB"), 9 => mkaux("x"^200),
                     12 => mkaux("ab"))
        W.csetenv("WFDBANNSORT", "0", true)
        aiw = [Anninfo("mit", WFDB_WRITE), Anninfo("aha", WFDB_AHA_WRITE)]
        @test W.annopen(w, "x", aiw, 2) == 0
        for i in 1:12
            a = Annotation(time=times[i], anntyp=codes[i] % Int8, subtyp=subs[i] % Int8,
                           chan=chans[i] % UInt8, num=nums[i] % Int8, aux=get(auxes, i, nothing))
            s1 = W.putann(w, 1, a)
            s0 = W.putann(w, 0, a)
            print(out, "put $s0 $s1\n")
        end
        W.wfdbquit(w)

        function pr(n)
            a = Annotation()
            s = 0
            while true
                s = W.getann(w, n, a)
                s != 0 && break
                print(out, "$(a.time) $(a.anntyp) $(a.subtyp) $(a.chan) $(a.num)")
                x = a.aux
                x === nothing || print(out, " aux[$(x[1])]=$(hexs(x[2:x[1]+1]))")
                print(out, "\n")
            end
            print(out, "end $s\n")
        end

        air = [Anninfo("mit", WFDB_READ), Anninfo("aha", WFDB_AHA_READ)]
        print(out, "open $(W.annopen(w, "x", air, 2))\n")
        pr(0)
        pr(1)
        a = Annotation()
        print(out, "settime $(W.iannsettime(w, 300))\n")
        W.getann(w, 0, a)
        print(out, "$(a.time) $(a.anntyp)\n")
        W.getann(w, 1, a)
        print(out, "$(a.time) $(a.anntyp)\n")
        print(out, "settime $(W.iannsettime(w, -70000))\n")
        W.getann(w, 0, a)
        print(out, "$(a.time) $(a.anntyp)\n")
        print(out, "settime $(W.iannsettime(w, 6000000000))\n")
        print(out, "settime $(W.iannsettime(w, 0))\n")
        W.getann(w, 0, a)
        print(out, "$(a.time) $(a.anntyp)\n")
        W.wfdbquit(w)

        # read with the wrong stat
        air2 = [Anninfo("mit", W.WFDB_AHA_READ), Anninfo("aha", WFDB_READ)]
        print(out, "open $(W.annopen(w, "x", air2, 2))\n")
        W.getann(w, 0, a)
        print(out, "$(a.time) $(a.anntyp)\n")
        W.getann(w, 1, a)
        print(out, "$(a.time) $(a.anntyp)\n")
        W.wfdbquit(w)
        bad = ai1("bad name", WFDB_WRITE)
        print(out, "open $(W.annopen(w, "x", bad, 1))\n")
        bad[1].stat = 9
        print(out, "open $(W.annopen(w, "x", bad, 1))\n")
        print(out, String(W.wfdberror(w)))
        p = W.putann(w, 0, a)
        g = W.getann(w, 0, a)
        print(out, "getann $g putann $p\n")

        expect = "put 0 0\nput 0 0\nput 0 0\nput 0 0\nput 0 0\nput 0 0\nput 0 0\n" *
                 "put 0 0\nput 0 0\nput 0 0\nput 0 0\nput 0 0\nopen 0\n5 1 0 0 0\n5 1 0 1 0\n" *
                 "5 1 0 1 2\n300 5 3 0 0\n70000 16 0 3 -1\n70001 28 0 0 0 aux[5]=2841464942\n" *
                 "5000000000 1 0 0 0\n5000000000 14 -1 2 1 aux[200]=XXX\n4000000000 1 0 200 0\n" *
                 "10 0 0 0 3\n3000000000 32 7 5 -128 aux[2]=6162\nend -1\n5 1 0 1 0\n5 1 0 1 0\n" *
                 "5 1 0 1 0\n300 5 3 5 0\n70000 22 0 16 0\n70001 22 0 28 0 aux[6]=284146494200\n" *
                 "705032704 1 0 1 0\n705032704 14 -1 14 0 aux[6]=787878787878\n" *
                 "-294967296 1 0 1 0\n10 22 0 0 0\n-1294967296 32 7 32 0 aux[6]=616200000000\n" *
                 "end -1\nsettime 0\n300 5\n300 5\nsettime 0\n70000 16\nsettime -1\nsettime 0\n" *
                 "0 22\nopen 0\n5 1\n5 1\nopen -4\nopen -5\n" *
                 "annopen: illegal stat 9 for annotator bad name, record x\ngetann -2 putann -2\n"
        expect = replace(expect, "XXX" => "78"^200)
        @test String(take!(out)) == expect

        expect_mit = "005805fc7374617274000504000401f8000402f0271503f400f800f000ec01004410004003f8" *
                     "fff3017000f800f005fc28414649420000ecff7fffff00ecff7fffff00ec042a91e000040038" *
                     "fff702f801f0c8fc" * "78"^200 * "00ec65c400360004c8f800f000ec0080010000ec949108d8010000f803" *
                     "f000ecff7fffff00ecd032f75d008007f405f880f302fc61620000"
        @test hexs(read("x.mit")) == expect_mit
        aha = read("x.aha")
        @test length(aha) == 1024
        expect_aha = "004f0000000001000016737461727400004e000005000200000100000000000000" *
                     "4e0000050003000001000000000000004e0000050004000001000000000000005600002c010500" *
                     "0305000000000000004f0100701106000010000000000000004f010071110700001c2841464942" *
                     "00004e052a00f2080000010000000000000055052a00f20900ff0e787878787878004e6bee0028" *
                     "0a000001000000000000004f00000a000b000000000000000000005bd0b2005e0c000720616200" *
                     "000000"
        n = length(expect_aha) ÷ 2
        @test hexs(aha[1:n]) == expect_aha
        @test all(==(0xff), aha[n+1:end])
        W.csetenv("WFDBANNSORT", "1", true)
    end
end

@testset "input annotators" begin
    with_data("input") do w
        @test W.getafreq(w) == 0.0
        @test W.sampfreq(w, "100s") == 360.0
        ais = [Anninfo("atr", WFDB_READ), Anninfo("ooo", WFDB_READ)]
        @test W.annopen(w, "100s", ais, 2) == 0
        @test W.getiafreq(w, 0) == 360.0
        @test W.getiafreq(w, 1) == 360.0
        @test W.getiafreq(w, 2) == -2.0
        @test W.getiaorigfreq(w, 0) == 0.0
        @test W.getiaorigfreq(w, 1) == 360.0
        @test W.getiaorigfreq(w, 2) == -2.0
        @test annv(w, 0) == [0, 18, 28, 0, 0, 0]
        @test annv(w, 0) == [0, 77, 1, 0, 0, 0]
        W.setiafreq(w, 0, 1000.0)
        @test W.getiafreq(w, 0) == 1000.0
        @test W.getiaorigfreq(w, 0) == 0.0
        a = Annotation()
        @test W.getann(w, 0, a) == 0
        @test a.time == 1028 && a.anntyp == 1
        W.wfdbquiet(w)
        @test W.ungetann(w, 0, a) == 0
        @test W.ungetann(w, 0, a) == -1        # the pushback buffer is full
        @test W.ungetann(w, 5, a) == -2
        W.wfdbverbose(w)
        @test annv(w, 0) == [0, 1028, 1, 0, 0, 0]
        @test annv(w, 0) == [0, 1839, 1, 0, 0, 0]
        a.time = 5
        a.anntyp = W.PVC
        @test W.ungetann(w, 0, a) == 0
        @test annv(w, 0) == [0, 5, 5, 0, 0, 0]
        W.setiafreq(w, 0, 0.0)
        @test W.getiafreq(w, 0) == 360.0
        @test annv(w, 0) == [0, 946, 1, 0, 0, 0]
        W.iannclose(w, 0)                      # annotator 1 (ooo) becomes annotator 0
        @test W.getiafreq(w, 0) == 360.0
        @test W.getiafreq(w, 1) == -2.0
        @test annv(w, 0) == [0, 18, 1, 0, 0, 0]
        W.wfdbquiet(w)
        @test annv(w, 1)[1] == -2
        W.iannclose(w, 0)
        @test annv(w, 0)[1] == -2
        W.iannclose(w, 3)
        W.wfdbverbose(w)
    end
end

@testset "annotation time resolution" begin
    with_data("tres") do w
        W.setafreq(w, 1000.0)
        @test W.getafreq(w) == 1000.0
        a1 = ai1("hf", WFDB_WRITE)
        W.annopen(w, "100s", a1, 1)
        a = Annotation(anntyp=W.NORMAL, time=1000)
        W.putann(w, 0, a)
        a.time = 2500
        W.putann(w, 0, a)
        W.wfdbquit(w)
        @test W.getafreq(w) == 1000.0
        W.setafreq(w, 0.0)
        a1[1].stat = WFDB_READ
        W.annopen(w, "100s", a1, 1)
        @test W.getiafreq(w, 0) == 1000.0
        @test W.getiaorigfreq(w, 0) == 1000.0
        @test annv(w, 0) == [0, 1000, 1, 0, 0, 0]
        W.setiafreq(w, 0, 360.0)
        @test W.getiafreq(w, 0) == 360.0
        @test annv(w, 0) == [0, 900, 1, 0, 0, 0]
        W.wfdbquit(w)
    end
end

@testset "output annotations flush" begin
    with_data("flush") do w
        @test W.annopen(w, "out", ai1("tst", WFDB_WRITE), 1) == 0
        a = Annotation(time=3, anntyp=W.NORMAL)
        W.putann(w, 0, a)
        a.time = 4
        a.anntyp = W.PVC
        W.putann(w, 0, a)
        W.wfdb_oaflush(w)
        @test filesize("out.tst") == 4
        W.wfdbquit(w)
        @test read("out.tst") == unhex("0304 0114 0000")
    end
end

@testset "ecgstr functions" begin
    w = Wfdb()
    @test W.ecgstr(w, 1) == b"N"
    @test W.ecgstr(w, 0) == b" "
    @test W.ecgstr(w, 15) == b"[15]"
    @test W.ecgstr(w, 22) == b"\""
    @test W.ecgstr(w, 50) == b"[50]"
    @test W.ecgstr(w, -1) == b"[-1]"
    @test W.strecg(w, "V") == 5
    @test W.strecg(w, "xx") == 0
    @test W.strecg(w, "") == 0
    @test W.strecg(w, "[15]") == 15
    @test W.setecgstr(w, 5, "PVC") == 0
    @test W.ecgstr(w, 5) == b"PVC"
    @test W.annstr(w, 5) == b"V"
    @test W.strecg(w, "PVC") == 5
    @test W.strecg(w, "V") == 0
    W.wfdbquiet(w)
    @test W.setecgstr(w, 50, "x") == -1
    @test W.setecgstr(w, -1, "x") == -1
    W.wfdbverbose(w)
    @test W.setecgstr(w, 0, "Z") == 0
    @test W.ecgstr(w, 0) == b"Z"
end

@testset "annstr and anndesc" begin
    with_data("annstr") do w
        @test W.setannstr(w, 5, "pvc") == 0
        @test W.annstr(w, 5) == b"pvc"
        @test W.ecgstr(w, 5) == b"V"
        @test W.strann(w, "pvc") == 5
        @test W.strann(w, "V") == 0
        @test W.setannstr(w, -6, "fus") == 0
        @test W.annstr(w, 6) == b"fus"
        W.wfdbquiet(w)
        @test W.setannstr(w, 60, "x") == -1
        @test W.setannstr(w, -60, "x") == -1
        W.wfdbverbose(w)
        @test W.setannstr(w, 0, "zero") == 0
        @test W.annstr(w, 0) == b"zero"
        @test W.annstr(w, 60) == b"[60]"
        @test W.setannstr(w, 42, "new") == 0
        @test W.strann(w, "new") == 42
        @test W.anndesc(w, 1) == b"Normal beat"
        @test W.anndesc(w, 15) === nothing
        @test W.anndesc(w, 60) == b"illegal annotation code"
        @test W.anndesc(w, -1) == b"illegal annotation code"
        @test W.setanndesc(w, 15, "my description") == 0
        @test W.anndesc(w, 15) == b"my description"
        @test W.setanndesc(w, -43, "negative") == 0
        @test W.anndesc(w, 43) == b"negative"
        W.wfdbquiet(w)
        @test W.setanndesc(w, 50, "x") == -1
        W.wfdbverbose(w)

        # Modified mnemonics (but not those set with a negative code) are
        # written into output annotation files ...
        a1 = ai1("mod", WFDB_WRITE)
        W.annopen(w, "100s", a1, 1)
        W.putann(w, 0, Annotation(time=10, anntyp=W.PVC))
        W.wfdbquit(w)
        expect = [unhex("0058 1efc"); b"## annotation type definitions"; unhex("0058 27fc");
                  b"5 pvc Premature ventricular contraction"; unhex("00 0058 16fc");
                  b"15 [15] my description"; unhex("0058 07fc"); b"42 new ";
                  unhex("00 0058 15fc"); b"## end of definitions";
                  unhex("00 00ec ffff ffff 0100 0a14 0000")]
        @test read("100s.mod") == expect
        W.setannstr(w, 5, "V")
        W.setannstr(w, -6, "F")
        W.setannstr(w, 0, " ")
        W.setannstr(w, -42, "[42]")
        W.setanndesc(w, -15, "")
        W.setanndesc(w, -43, "")
        # ... and reading the file defines them again.
        a1[1].stat = WFDB_READ
        W.annopen(w, "100s", a1, 1)
        @test annv(w, 0) == [0, 10, 5, 0, 0, 0]
        @test W.annstr(w, 5) == b"pvc"
        @test W.anndesc(w, 15) == b"my description"
        @test W.anndesc(w, 42) == b""
        W.wfdbquit(w)
    end
end

@testset "mnemonics (default instance)" begin
    @test annstr(W.NORMAL) == b"N"
    @test strann("V") == W.PVC
    @test anndesc(W.PVC) == b"Premature ventricular contraction"
    @test ecgstr(99) == b"[99]"
    @test isqrs(W.NORMAL) != 0 && isqrs(W.NOTE) == 0
    @test map1(W.APC) == W.NORMAL && map2(W.APC) == W.SVPB
end

function calv(w, desc, units)
    c = Calinfo()
    st = W.getcal(w, desc, units, c)
    st != 0 && return (st, 0.0, 0.0, 0.0, 0, "", "")
    s(x) = x === nothing ? "(null)" : String(copy(x))
    (st, c.low, c.high, c.scale, c.caltype, s(c.sigtype), s(c.units))
end

calinfo(low, high, scale, sigtype, units, caltype) =
    Calinfo(low=low, high=high, scale=scale, sigtype=Vector{UInt8}(sigtype),
            units=Vector{UInt8}(units), caltype=caltype)

@testset "calibration" begin
    with_data("cal") do w
        @test W.calopen(w, "wfdbcal") == 0
        @test calv(w, "ECG lead II", "mV") == (0, 0.0, 1.0, 1.0, 4, "ECG", "mV")
        @test calv(w, "ECG", "uV") == (0, 0.0, 1.0, 1000.0, 4, "ECG", "uV")
        @test calv(w, "ABP", "mmHg") == (0, 0.0, 0.0, 100.0, 3, "ABP", "mmHg")
        @test calv(w, "BP", nothing) == (0, 0.0, 100.0, 100.0, 3, "BP", "mmHg")
        @test calv(w, nothing, nothing) == (0, 0.0, 1.0, 1.0, 4, "ECG", "mV")
        @test calv(w, "nosuch", "x")[1] == -1
        test = calinfo(-1.5, 2.5, 3.0, "TEST", "xu", WFDB_DC_COUPLED | W.WFDB_CAL_SINE)
        ac = calinfo(0.0, 0.0, 7.0, "AC", "yu", WFDB_AC_COUPLED | W.WFDB_CAL_UNDEF)
        @test W.putcal(w, test) == 0
        @test W.putcal(w, ac) == 0
        @test calv(w, "TEST signal", "xu") == (0, -1.5, 2.5, 3.0, 5, "TEST", "xu")
        W.flushcal(w)
        @test calv(w, "ECG", "mV")[1] == -1
        W.putcal(w, test)
        W.putcal(w, ac)
        W.putcal(w, calinfo(1.0, 2.0, 0.25, "SQ", "zu", WFDB_DC_COUPLED | W.WFDB_CAL_SQUARE))
        W.putcal(w, calinfo(1.0, 2.0, 0.25, "SAW", "zu", WFDB_AC_COUPLED | W.WFDB_CAL_SAWTOOTH))
        W.wfdbquiet(w)
        @test W.newcal(w, "my.cal") == -1      # illegal name
        W.wfdbverbose(w)
        @test W.newcal(w, "mycal") == 0
        @test String(read("mycal")) == "TEST\t-1.5 2.5 sine 3 xu\r\nAC\t- - undefined 7 yu\r\n" *
                                       "SQ\t1 2 square 0.25 zu\r\nSAW\t- 2 sawtooth 0.25 zu\r\n"
        @test W.calopen(w, "mycal") == 0
        @test calv(w, "AC", "yu") == (0, 0.0, 0.0, 7.0, 0, "AC", "yu")
        @test calv(w, "ECG", "mV")[1] == -1
        @test W.calopen(w, "+wfdbcal") == 0
        @test calv(w, "ECG", "mV") == (0, 0.0, 1.0, 1.0, 4, "ECG", "mV")
        @test calv(w, "SAW", nothing) == (0, 0.0, 2.0, 0.25, 6, "SAW", "zu")
        W.wfdbquiet(w)
        @test W.calopen(w, "nosuch.cal") == -2
        W.wfdbverbose(w)
        W.flushcal(w)
    end
end

@testset "annotation tools in-process" begin
    with_data("tools") do w
        env = ("WFDBX_INPUT_DIR" => ".",)
        st, out, err = W.run_tool("rdann", ["-r", "100s", "-a", "atr", "-t", "0:01"]; env=env)
        @test st == 0 && isempty(err)
        @test startswith(String(copy(out)), "    0:00.050       18     +    0    0    0\t(N\n")
        st, out, err = W.run_tool("wrann", ["-r", "100s", "-a", "cpy"]; env=env,
                                  stdin=read("100s.atr.txt"))
        @test st == 0 && isempty(out) && isempty(err)
        # (read back: the same as the text, the time resolution label aside)
        st, out, err = W.run_tool("rdann", ["-r", "100s", "-a", "cpy"]; env=env)
        @test st == 0 && out == read("100s.atr.txt")
        st, out, err = W.run_tool("ann2rr", ["-r", "100s", "-a", "atr", "-t", "0:02"]; env=env)
        @test st == 0 && String(copy(out)) == "77\n293\n292\n"
        st, out, err = W.run_tool("sortann", ["-r", "100s", "-a", "atr"]; env=env)
        @test st == 0 && err == b"sortann: input is already ordered -- no output written\n"
        # (wfdb-x: -F is required without a header; the C program assumed 250 Hz)
        st, out, err = W.run_tool("rr2ann", ["-r", "newrec", "-a", "rr"]; env=env,
                                  stdin="100\n50\n")
        @test st == 1 && err == b"rr2ann: sampling frequency of record newrec is not specified (use -F)\n"
        st, out, err = W.run_tool("rr2ann", ["-r", "newrec", "-a", "rr", "-F", "250"]; env=env,
                                  stdin="100\n50\n")
        @test st == 0 && read("newrec.rr") == unhex("6404 3204 0000")
    end
end

# ---------------------------------------------------------------------------
# Out-of-order output annotations: sorted when the file is closed (wfdb-x: in
# the same process; in legacy mode, by running sortann, as the C library)

# ties in time, num and chan, duplicates (the last one is kept), NOTQRS
# (dropped), aux strings, and a time 0 annotation that precedes the others
# (dropped by sortann; see docs/KNOWN_C_BEHAVIORS.md)
TRICKY = [    # time, code, subtype, chan, num, aux
    (100, W.NORMAL, 0, 0, 0, nothing), (50, W.PVC, 0, 0, 0, "(VT"),
    (100, W.APC, 0, 1, 0, nothing), (100, W.NORMAL, 0, 0, 1, "num 1"),
    (100, W.PVC, 0, 0, 0, "replaces N"), (75, W.NOTQRS, 0, 2, 0, nothing),
    (75, W.NORMAL, 1, 2, 0, "odd"), (10, W.NOTQRS, 0, 0, 0, nothing),
    (200, W.RHYTHM, 0, 0, 0, "(AFIB"), (150, W.NOISE, 0, 3, -1, nothing),
    (150, W.NOISE, 0, 3, 0, nothing), (20, W.NORMAL, 0, 0, 0, "x"^101),
    (0, W.NORMAL, 0, 0, 0, nothing), (5, W.NORMAL, 0, 1, 0, nothing),
    (5000, W.NORMAL, 0, 0, 0, nothing)]

tricky_annotations() = W.Annotations(
    samples=[t[1] for t in TRICKY], codes=[t[2] for t in TRICKY],
    subtypes=[t[3] for t in TRICKY], chans=[t[4] for t in TRICKY],
    nums=[t[5] for t in TRICKY],
    aux=Union{Nothing,Vector{UInt8}}[t[6] === nothing ? nothing : Vector{UInt8}(t[6])
                                     for t in TRICKY])

# Run f() with the standard output and error of the library captured (as
# run_tool does; a sortann run by oannclose would then run in this process,
# and its messages would be captured too); return what f wrote on the
# standard error.
function capture_stderr(f)
    p = W.cproc()
    p.out_capture = UInt8[]
    p.err_capture = UInt8[]
    try
        f()
        return String(copy(p.err_capture))
    finally
        p.out_capture = nothing
        p.err_capture = nothing
    end
end

rearranged(name) = "Rearranging annotations for output annotator $name ...done!\n"

# (time in ticks of 1000 Hz, anntyp, chan, num) of the annotations of
# 100s.NAME, read with a fresh library state.
function read_ticks(name)
    r = Wfdb()
    W.setwfdb(r, ".")
    @test W.annopen(r, "100s", ai1(name, WFDB_READ), 1) == 0
    @test W.annstr(r, 42) == b"Z"   # (the definition table was kept)
    W.setiafreq(r, 0, 1000.0)       # (times in ticks of the time resolution)
    got = Tuple{Int64,Int32,Int32,Int32}[]
    a = Annotation()
    while W.getann(r, 0, a) == 0
        push!(got, (a.time, a.anntyp, a.chan, a.num))
    end
    W.wfdbquit(r)
    got
end

@testset "in-process sort" begin
    with_data("sort") do w
        W.setannstr(w, 42, "Z")     # (a definition table in the file)
        # legacy mode: the sortann program (a separate process, with --legacy)
        W.write_annotations(w, "100s", "leg", tricky_annotations(); fs=1000.0, legacy=true)
        # modern mode: in this process, without any sortann (one would print
        # "init: can't open header for record nohdr")
        err = capture_stderr() do
            W.write_annotations(w, "100s", "mod", tricky_annotations(); fs=1000.0)
            cp("100s.hea", "nohdr.hea")
            W.write_annotations(w, "nohdr", "mod", tricky_annotations(); fs=1000.0)
            rm("nohdr.hea")
            W.write_annotations(w, "nohdr", "mod", tricky_annotations(); fs=1000.0)
        end
        @test err == rearranged("mod")^3
        modern = read("100s.mod")
        @test read("nohdr.mod") == modern
        # (the library's settings and tables are unchanged)
        @test W.getafreq(w) == 0.0 && W.annstr(w, 42) == b"Z"
        @test findall(w.ann.modified) == [43]
        # the in-process sort and the sortann tool give the same bytes (and
        # so do the legacy sort and the legacy tool)
        withenv("WFDBANNSORT" => "0") do
            W.wfdbquiet(w)
            W.write_annotations(w, "100s", "uns", tricky_annotations(); fs=1000.0)
            W.wfdbverbose(w)
        end
        cp("100s.uns", "100s.unl")
        env = ("WFDBX_INPUT_DIR" => ".",)
        st, out, err = W.run_tool("sortann", ["-r", "100s", "-a", "uns"]; env=env)
        @test st == 0 && isempty(err) && read("100s.uns") == modern
        st, out, err = W.run_tool("sortann", ["--legacy", "-r", "100s", "-a", "unl"]; env=env)
        @test st == 0 && isempty(err) && read("100s.unl") == read("100s.leg")
        # legacy mode (the original sortann): the annotation at time 0 is
        # lost, and so is the one at time 5 inserted after it
        rest = [(20, W.NORMAL, 0, 0), (50, W.PVC, 0, 0), (75, W.NORMAL, 2, 0),
                (100, W.PVC, 0, 0), (100, W.APC, 1, 0), (100, W.NORMAL, 0, 1),
                (150, W.NOISE, 3, -1), (150, W.NOISE, 3, 0), (200, W.RHYTHM, 0, 0),
                (5000, W.NORMAL, 0, 0)]
        @test read_ticks("leg") == rest
        # wfdb-x: nothing is lost
        got = read_ticks("mod")
        @test got == vcat([(0, W.NORMAL, 0, 0), (5, W.NORMAL, 1, 0)], rest)
        # NOTQRS annotations are dropped (by sortann too; wrann cannot write
        # them)
        @test !any(t -> t[2] == W.NOTQRS, got)
    end
end

# wfdb-x: write_annotations(sort=...) decides for its call whatever
# WFDBANNSORT says (the environment is not changed); unset: WFDBANNSORT.
@testset "write_annotations sort option" begin
    with_data("sortopt") do w
        ann = W.Annotations(samples=[300, 100, 200], codes=Int32[1, 5, 1])
        times(name) = W.read_annotations(w, "100s", name).samples
        for legacy in (false, true)
            withenv("WFDBANNSORT" => nothing) do
                err = capture_stderr() do
                    W.write_annotations(w, "100s", "nos", ann; sort=false, legacy=legacy)
                end
                # (the file is left as written; the caller chose the order,
                # so the library does not advise running sortann)
                @test err == ""
                @test times("nos") == [300, 100, 200]
                err = capture_stderr(() -> W.write_annotations(w, "100s", "dfl", ann;
                                                                legacy=legacy))
                @test err == rearranged("dfl") && times("dfl") == [100, 200, 300]
            end
            withenv("WFDBANNSORT" => "0") do
                err = capture_stderr() do
                    W.write_annotations(w, "100s", "srt", ann; sort=true, legacy=legacy)
                end
                @test err == rearranged("srt") && times("srt") == [100, 200, 300]
                @test ENV["WFDBANNSORT"] == "0"
                W.wfdbquiet(w)
                W.write_annotations(w, "100s", "uns", ann; legacy=legacy)
                W.wfdbverbose(w)
                @test times("uns") == [300, 100, 200]
            end
            withenv("WFDBANNSORT" => "1") do
                err = capture_stderr() do
                    W.write_annotations(w, "100s", "nos", ann; sort=false, legacy=legacy)
                end
                @test err == "" && times("nos") == [300, 100, 200]
            end
            withenv("WFDBANNSORT" => "0") do
                err = capture_stderr() do
                    W.write_annotations(w, "100s", "nos", ann; sort=false, legacy=legacy)
                end
                @test err == ""
                # WFDBANNSORT=0 without the option, and the C-style API, give
                # the advice
                err = capture_stderr(() -> W.write_annotations(w, "100s", "env0", ann;
                                                                legacy=legacy))
                @test err == "Use the command:\n  sortann -r 100s -a env0\n" *
                             "to rearrange annotations in the correct order.\n"
                err = capture_stderr() do
                    @test W.annopen(w, "100s", [Anninfo("low", WFDB_WRITE)], 1) == 0
                    for t in (300, 100, 200)
                        W.putann(w, 0, Annotation(time=t, anntyp=Int8(1)))
                    end
                    W.wfdbquit(w)
                end
                @test err == "Use the command:\n  sortann -r 100s -a low\n" *
                             "to rearrange annotations in the correct order.\n"
            end
            @test w.ann.sort_override === nothing      # (restored)
        end
        # an in-order file is the same whatever the option
        ok = W.Annotations(samples=[100, 200], codes=Int32[1, 1])
        for (name, opt) in (("o1", nothing), ("o2", true), ("o3", false))
            W.write_annotations(w, "100s", name, ok; sort=opt)
        end
        @test read("100s.o1") == read("100s.o2") == read("100s.o3")
    end
end

@testset "sort list: time 0" begin
    for (legacy, want) in ((false, [0, 3, 5]), (true, [5]))
        l = W._SortList(legacy)
        for t in (5, 0, 3)
            W._sortann_insert!(l, Annotation(time=t, anntyp=W.NORMAL % Int8))
        end
        times = Int64[]
        ap = l.next[1]
        while ap != -1
            push!(times, l.ann[ap+1].time)
            ap = l.next[ap+1]
        end
        @test times == want && !l.in_order
    end
    # a later annotation at time 0 replaces a real one (both modes), and an
    # annotation at time 0 on another channel is kept (both modes)
    for legacy in (false, true)
        l = W._SortList(legacy)
        for (t, c, typ) in ((0, 0, W.NORMAL), (7, 0, W.NORMAL), (0, 1, W.APC), (0, 0, W.PVC))
            W._sortann_insert!(l, Annotation(time=t, anntyp=typ % Int8, chan=c % UInt8))
        end
        got = Tuple{Int64,Int,Int}[]
        ap = l.next[1]
        while ap != -1
            x = l.ann[ap+1]
            push!(got, (x.time, x.chan, x.anntyp))
            ap = l.next[ap+1]
        end
        @test got == [(0, 0, W.PVC), (0, 1, W.APC), (7, 0, W.NORMAL)]
    end
end

@testset "legacy sort in the output directory" begin
    # legacy mode: the sortann program runs in the output directory (where
    # the file is), with --legacy; the result is that of the modern sort
    with_data("legdir") do w
        mkdir("out")
        ann = W.Annotations(samples=[300, 100, 200, 100, 50],
                            symbols=[b"N", b"V", b"N", b"A", b"N"])
        W.write_annotations(w, "rec", "leg", ann; dir="out", legacy=true)
        W.write_annotations(w, "rec", "mod", ann; dir="out")
        @test sort(readdir("out")) == ["rec.leg", "rec.mod"]
        @test read("out/rec.leg") == read("out/rec.mod")
        W.wfdbquiet(w)
        a = W.read_annotations(w, "out/rec", "leg"; fs=360)
        W.wfdbverbose(w)
        @test a.samples == [50, 100, 200, 300] && a.symbols[2] == b"A"
        # (the same with the captured output of run_tool, where sortann runs
        # in this process)
        err = capture_stderr() do
            W.write_annotations(w, "rec", "cap", ann; dir="out", legacy=true)
        end
        @test err == "Rearranging annotations for output annotator cap ..." *
                     "init: can't open header for record rec\ndone!\n"
        @test read("out/rec.cap") == read("out/rec.mod")
    end
end

@testset "write_annotations: dir checks first" begin
    with_data("dirfirst") do w
        mkdir("out")
        ann = W.Annotations(samples=[1], symbols=[b"N"])
        e = try
            W.write_annotations(w, "x/rec", "atr", ann; dir="out")
        catch err
            err
        end
        @test e isa W.WfdbError && e.msg == "record name must not contain a directory when dir is given"
        e = try
            W.write_annotations(w, "rec", "atr", ann; dir="nosuch")
        catch err
            err
        end
        @test e isa W.WfdbError && e.msg == "directory nosuch does not exist"
        # (then the other checks: an illegal annotator name)
        W.wfdbquiet(w)
        @test_throws W.WfdbError W.write_annotations(w, "rec", "a.b", ann; dir="out")
        W.wfdbverbose(w)
    end
end

@testset "sort disabled, read errors" begin
    with_data("nosort") do w
        withenv("WFDBANNSORT" => "0") do
            err = capture_stderr() do
                W.write_annotations(w, "100s", "ns", tricky_annotations())
            end
            @test err == "Use the command:\n  sortann -r 100s -a ns\n" *
                         "to rearrange annotations in the correct order.\n"
        end
        @test W.annopen(w, "100s", ai1("ns", WFDB_READ), 1) == 0
        times = Int64[]
        a = Annotation()
        while W.getann(w, 0, a) == 0
            push!(times, a.time)
        end
        W.wfdbquit(w)
        @test times == [t[1] for t in TRICKY]   # (as written)
        # a truncated file (no end mark) cannot be sorted, and is not changed
        data = read("100s.ns")
        write("100s.tr", data[1:end-2])
        W.wfdbquiet(w)
        @test W._sort_ann_file(w, Vector{UInt8}("100s.tr"), Vector{UInt8}("tr")) == -1
        W.wfdbverbose(w)
        @test read("100s.tr") == data[1:end-2]
        @test W._sort_ann_file(w, Vector{UInt8}("nosuch.tr"), Vector{UInt8}("tr")) == -1
        # an ordered file is not rewritten
        @test W._sort_ann_file(w, Vector{UInt8}("100s.atr"), Vector{UInt8}("atr")) == 0
    end
end

@testset "sort keeps other annotators" begin
    # an input annotator and the signals stay open while an output annotator
    # is closed and sorted
    with_data("keep") do w
        @test W.isigopen(w, "100s", nothing, 2) == 2
        ai = [Anninfo("atr", WFDB_READ), Anninfo("o1", WFDB_WRITE), Anninfo("o2", WFDB_WRITE)]
        @test W.annopen(w, "100s", ai, 3) == 0
        first = Annotation()
        W.getann(w, 0, first)
        for t in (30, 10, 20)
            W.putann(w, 0, Annotation(time=t, anntyp=W.NORMAL % Int8))
            W.putann(w, 1, Annotation(time=t, anntyp=W.PVC % Int8))
        end
        W.wfdbquiet(w)
        W.oannclose(w, 0)       # sorted now; o2 becomes output annotator 0
        W.wfdbverbose(w)
        @test annv(w, 0)[1:2] == [0, 77] && first.time == 18
        v = zeros(Int32, 2)
        @test W.getvec(w, v) == 2 && v == [995, 1011]
        W.putann(w, 0, Annotation(time=40, anntyp=W.PVC % Int8))
        W.wfdbquiet(w)
        W.wfdbquit(w)
        W.wfdbverbose(w)
        o1 = W.read_annotations(w, "100s", "o1")
        o2 = W.read_annotations(w, "100s", "o2")
        @test o1.samples == [10, 20, 30] && all(==(b"N"), o1.symbols)
        @test o2.samples == [10, 20, 30, 40]
    end
end

@testset "write_annotations dir" begin
    with_data("dir") do w
        mkdir("out")
        ann = W.Annotations(samples=[30, 10, 20], symbols=[b"N", b"V", b"N"])
        W.wfdbquiet(w)
        W.write_annotations(w, "rec", "atr", ann; dir="out")
        @test readdir("out") == ["rec.atr"]
        @test W.wfdbx_get_output_dir(w) === nothing
        a = W.read_annotations(w, "out/rec", "atr")     # sorted in place
        W.wfdbverbose(w)
        @test a.samples == [10, 20, 30] && a.symbols[1] == b"V"
        @test_throws W.WfdbError W.write_annotations(w, "rec", "atr", ann; dir="nosuch")
        @test_throws W.WfdbError W.write_annotations(w, "x/rec", "atr", ann; dir="out")
        @test readdir("out") == ["rec.atr"]
    end
end

# wfdb-x: read_annotations throws when reading ends with a getann status
# other than 0 and -1 (a truncated file: -3); the library's message is
# still printed. Each truncation of a small file is compared with getann.
@testset "read_annotations: truncated file" begin
    with_data("trunc") do w
        W.write_record(w, "ann", fill(Int32(1), 3000, 1), 100.0; gains=100.0, adcres=16,
                       units="mV")
        # an aux string, and a SKIP (the interval 30 -> 2500 exceeds 1023)
        src = W.Annotations(samples=[10, 20, 30, 2500, 2510], codes=Int32[1, 5, 1, 1, 1],
                            aux=[nothing, b"(N", nothing, nothing, b"x"])
        W.write_annotations(w, "ann", "atr", src)
        full = read("ann.atr")
        @test any(i -> full[i] == 0x00 && full[i+1] == 0xec, 1:2:length(full)-1)   # SKIP
        msg(s) = "can't read annotation file cut of record ann (getann status $s)"
        # a complete file reads as before
        a = W.read_annotations(w, "ann", "atr")
        @test a.samples == src.samples && a.codes == src.codes && a.aux == src.aux
        nerr = 0
        for legacy in (false, true), cut in 0:length(full)
            write("ann.cut", full[1:cut])
            W.wfdbquiet(w)
            # getann
            got = Int64[]
            gaux = Any[]
            st = Int32(-1)
            ok = W.annopen(w, "ann", ai1("cut", WFDB_READ), 1) == 0
            if ok
                x = Annotation()
                while (st = W.getann(w, 0, x)) == 0
                    push!(got, x.time)
                    push!(gaux, x.aux === nothing || isempty(x.aux) ? nothing :
                                copy(W.cstr(x.aux[2:min(1 + Int(x.aux[1]), end)])))
                end
            end
            W.wfdbquit(w)
            if !ok
                @test_throws W.WfdbError W.read_annotations(w, "ann", "cut"; legacy=legacy)
            elseif st == 0 || st == -1
                r = W.read_annotations(w, "ann", "cut"; legacy=legacy)
                @test r.samples == got && r.aux == gaux
            else
                @test cut < length(full)
                e = try
                    W.read_annotations(w, "ann", "cut"; legacy=legacy)
                    nothing
                catch err
                    err
                end
                nerr += 1
                @test e isa W.WfdbError && e.msg == msg(st)
                @test isempty(w.ann.iad)        # (closed by wfdbquit)
                # a read ending before the truncation point is not an error
                if !isempty(got)
                    r = W.read_annotations(w, "ann", "cut"; to=got[end], legacy=legacy)
                    @test r.samples == got[1:end-1]
                end
            end
            W.wfdbverbose(w)
        end
        @test nerr > length(full)      # (most truncations are errors)
        # the exact message, with the library's own message printed too
        write("ann.cut", full[1:end-2])
        local e
        err = lib_stderr() do
            e = try
                W.read_annotations(w, "ann", "cut")
            catch x
                x
            end
        end
        @test e isa W.WfdbError && e.msg == msg(-3)
        @test sprint(showerror, e) == "WfdbError: " * msg(-3)
        @test occursin("getann: unexpected EOF in annotator cut", err)
        # (getann returns -3 after 2500: the annotation at 2510 is lost)
        r = W.read_annotations(w, "ann", "cut"; to=2500)
        @test r.samples == [10, 20, 30]
        r = W.read_annotations(w, "ann", "cut"; from=20, to=2500)
        @test r.samples == [20, 30]
        W.wfdbquiet(w)
        @test_throws W.WfdbError W.read_annotations(w, "ann", "cut"; to=2501)
        @test_throws W.WfdbError W.read_annotations(w, "ann", "cut"; legacy=true)
        W.wfdbverbose(w)
    end
end
