# Tests of the FLAC codec (flac.jl), ported from the tests of
# rust/src/flac.rs. The expected digests of the encoder output were computed
# by the Python implementation of wfdb-x (the C++ and Rust encoders write
# the same bytes).
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

md5_hex(data) = (m = W.Md5(); W.md5_update!(m, data); hexs(W.md5_digest!(m)))

# MD5 of the samples interleaved, each as a 32-bit little-endian integer.
function samples_digest(chans)
    m = W.Md5()
    n = isempty(chans) ? 0 : length(chans[1])
    for i in 1:n, c in chans
        u = c[i] % UInt32
        W.md5_update!(m, UInt8[(u >> (8k)) % UInt8 for k in 0:3])
    end
    hexs(W.md5_digest!(m))
end

const FLAC_RECORDS = [
    (name="flac8", channels=2, bps=8, nsamp=5000, digest="505da209b1473fbc46a21feb7833b00d",
     first=Int32[-31, -42, -13], last=-86),
    (name="flac16", channels=3, bps=16, nsamp=9000, digest="c7031b07326efeaf5de0938839eccfd4",
     first=Int32[-31, -58, -28], last=1335),
    (name="flac24", channels=1, bps=24, nsamp=4500, digest="009556de1b80833f7f1d21d99c817729",
     first=Int32[-17, -4, 29], last=8388435),
    (name="flacmf", channels=2, bps=16, nsamp=8642, digest="76ee297c139a1538a9fd7f43d5398659",
     first=Int32[-300, 700, -297], last=2979)]

# Test signals for the encoder (the same as those of the Python script that
# computed the expected digests).
function flac_gen(vid, nsig, bps, spf, nframes, kinds)
    state = UInt32(12345) + UInt32(vid)
    out = Int32[]
    half = Int64(1) << (bps - 1)
    for f in 0:nframes-1, s in 0:nsig-1, k in 0:spf-1
        state = state * UInt32(1664525) + UInt32(1013904223)
        t = Int64(f) * spf + k
        kind = kinds[s+1]
        v = if kind == 0
            P = 397
            m = t % P - P ÷ 2
            abs(m) * (half ÷ 256) - half ÷ 2 + Int64((state >> 20) % 7) - 3
        elseif kind == 1
            Int64((state >> 8) & ((UInt32(1) << bps) - UInt32(1))) - half
        elseif kind == 2
            t < 5000 ? Int64(17) : (t - 5000) * 3 - 100
        else
            Int64(reinterpret(Int32, state))
        end
        push!(out, v % UInt32 % Int32)
    end
    out
end

const FLAC_ENCODER_CASES = [
    (vid=0, nsig=2, bps=16, spf=1, nframes=10000, kinds=[0, 1], size=26203,
     digest="5495badb24f7c490c5484be5441c2f76", sum=UInt32(4257896572)),
    (vid=1, nsig=1, bps=24, spf=2, nframes=6000, kinds=[0], size=11846,
     digest="40596f848ca112518ce4d7c573aa9622", sum=UInt32(1739685865)),
    (vid=2, nsig=3, bps=8, spf=1, nframes=7000, kinds=[2, 0, 1], size=11704,
     digest="0efb1695c22420deb64837c433e39c61", sum=UInt32(5422484)),
    (vid=3, nsig=1, bps=16, spf=1, nframes=100, kinds=[0], size=130,
     digest="109b65398fce5e82b3817c267a879467", sum=UInt32(262406)),
    (vid=4, nsig=1, bps=16, spf=1, nframes=300, kinds=[3], size=671,
     digest="459bc9a342c66d4d1c720002dd7670e2", sum=UInt32(3379252398)),
    (vid=5, nsig=2, bps=24, spf=3, nframes=3000, kinds=[1, 2], size=27782,
     digest="25779b07efedeaadef4350bbb5148b01", sum=UInt32(4163323067))]

# Encode a complete stream as the WFDB library writes it (the final
# STREAMINFO block replaces the provisional one at offset 8).
function flac_encode(nsig, bps, spf, x)
    enc = FlacEncoder(nsig, bps, spf)
    out = flac_header!(enc)
    for v in x
        flac_put!(enc, v, out)
    end
    flac_finish!(enc, out)
    si = flac_streaminfo(enc)
    out[9:8+length(si)] = si
    out
end

flac_wrap(v, bps) = (Int64(((v % UInt32) + (UInt32(1) << (bps - 1))) & ((UInt32(1) << bps) - UInt32(1))) -
                     (Int64(1) << (bps - 1))) % Int32

@testset "MD5 vectors" begin
    @test md5_hex(UInt8[]) == "d41d8cd98f00b204e9800998ecf8427e"
    @test md5_hex(b"abc") == "900150983cd24fb0d6963f7d28e17f72"
    v = repeat(collect(0x00:0xff), 5)
    @test md5_hex(v) == "82829f1f3f2bb0f18b25f278e5bba8bd"
    # the same data in pieces of various sizes
    m = W.Md5()
    pos, step = 0, 1
    while pos < length(v)
        k = min(step, length(v) - pos)
        W.md5_update!(m, view(v, pos+1:pos+k))
        pos += k
        step = step * 3 + 1
    end
    @test hexs(W.md5_digest!(m)) == "82829f1f3f2bb0f18b25f278e5bba8bd"
end

@testset "FLAC decoder" begin
    data_dir = W.workload_data_source()
    for rc in FLAC_RECORDS
        data = read(joinpath(data_dir, rc.name * ".dat"))
        d = flac_decode(data, 0, 0)
        @test d.status == FLAC_OK
        @test d.channels == rc.channels
        @test d.bps == rc.bps
        @test length(d.chans) == rc.channels
        @test length(d.chans[1]) == rc.nsamp
        @test samples_digest(d.chans) == rc.digest
        @test d.chans[1][1:3] == rc.first
        @test d.chans[end][end] == rc.last
        # The MD5 signature in STREAMINFO matches the decoded samples.
        @test d.has_md5
        @test flac_samples_md5(d.chans, d.bps) == d.md5
        # Decoding with the expected numbers of signals and bits
        d2 = flac_decode(data, rc.channels, rc.bps)
        @test d2.status == FLAC_OK && d2.chans == d.chans
        # Trailing zero bytes are ignored.
        d3 = flac_decode([data; zeros(UInt8, 100)], 0, 0)
        @test d3.status == FLAC_OK && d3.chans == d.chans
        # A truncated stream cannot be decoded.
        @test flac_decode(data[1:end-3], 0, 0).status != FLAC_OK
        # Neither can a stream with a corrupted frame,
        bad = copy(data)
        mid = length(bad) ÷ 2
        bad[mid+1] ⊻= 0x10
        @test flac_decode(bad, 0, 0).status != FLAC_OK
        # nor something that is not a FLAC stream.
        @test flac_decode(data[2:end], 0, 0).status == FLAC_META
    end
end

@testset "FLAC encoder (same bytes as the other implementations)" begin
    for ec in FLAC_ENCODER_CASES
        x = flac_gen(ec.vid, ec.nsig, ec.bps, ec.spf, ec.nframes, ec.kinds)
        @test reduce(+, (v % UInt32 for v in x); init=UInt32(0)) == ec.sum
        bytes = flac_encode(ec.nsig, ec.bps, ec.spf, x)
        @test length(bytes) == ec.size
        @test md5_hex(bytes) == ec.digest
        @test occursin("wfdb-x", String(copy(bytes)))
        # Round trip
        d = flac_decode(bytes, ec.nsig, ec.bps)
        @test d.status == FLAC_OK
        @test d.channels == ec.nsig && d.bps == ec.bps && length(d.chans) == ec.nsig
        ok = true
        for s in 0:ec.nsig-1
            ok &= length(d.chans[s+1]) == ec.nframes * ec.spf
            for f in 0:ec.nframes-1, k in 0:ec.spf-1
                i = (f * ec.nsig + s) * ec.spf + k
                ok &= d.chans[s+1][f*ec.spf+k+1] == flac_wrap(x[i+1], ec.bps)
            end
        end
        @test ok
        @test d.has_md5 && flac_samples_md5(d.chans, d.bps) == d.md5
    end
end

@testset "FLAC encoder: incomplete frame" begin
    # Samples of an incomplete frame (fewer than nsig*spf) are not written.
    enc = FlacEncoder(2, 16, 1)
    out = flac_header!(enc)
    for i in 0:8
        flac_put!(enc, Int32(i * 100), out)
    end
    flac_finish!(enc, out)
    si = flac_streaminfo(enc)
    out[9:8+length(si)] = si
    d = flac_decode(out, 0, 0)
    @test d.status == FLAC_OK
    @test length(d.chans) == 2
    @test length(d.chans[1]) == 4
    @test d.chans[2][4] == 700
    # The wrong number of signals is detected when expected.
    d2 = flac_decode(out, 3, 16)
    @test d2.status == FLAC_WFDB
    @test d2.error_message == b"getvec: wrong number of signals in FLAC signal file\n"
    d3 = flac_decode(out, 2, 8)
    @test d3.status == FLAC_WFDB
    @test d3.error_message == b"getvec: wrong sample resolution in FLAC signal file\n"
    @test FLAC_MAX_CHANNELS == 8 && FLAC_BLOCKSIZE == 4096
end
