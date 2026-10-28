function [out, ok] = bulk_frames(n, minstat)
%BULK_FRAMES Read many sample vectors at once with vector operations.
%   [OUT, OK] = wfdbx.internal.bulk_frames(N) reads up to N sample vectors
%   (as returned by getvec: one row per vector, one column per signal of
%   getvec's vector, nvsig), exactly as N calls of getvec would, decoding
%   whole frames with vector operations.  Multi-frequency records are
%   handled in WFDB_LOWRES mode (frame averages, as meansamp) and
%   WFDB_HIGHRES mode (ispfmax vectors per frame), FLAC groups through
%   wfdbx.internal.flac_getsamps, null signals (format 0), and the
%   segments of multi-segment records (mapped to the layout signals, as
%   sigmap, when the layout varies).  Fewer vectors (possibly none) are
%   read when a frame would require special handling (end of file, a
%   frame at which a checksum is verified or after which a segment ends,
%   a partial bit-packed group, a partial frame in WFDB_HIGHRES mode,
%   ...), so that the caller can use getvec for the next one.  OK is
%   false (and OUT empty) if the bulk path cannot be used at all (skew,
%   resampling with setifreq, a FLAC decoding error, a prolog not yet
%   skipped, ...).
%
%   [OUT, OK] = wfdbx.internal.bulk_frames(N, MINSTAT) also declines (OK
%   false) if getvec would return less than MINSTAT for these vectors (the
%   number of signals of the current segment).
%
%   The property bulk_read of wfdbx.internal.sig_state() (true by default)
%   turns this path off when false (for the tests); bulk_vectors counts
%   the vectors read by it.
%
%   Part of the translation of lib/signal.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 2
    minstat = 0;
end
S = wfdbx.internal.sig_state();
out = [];
ok = false;
nisig = S.nisig;
need_sigmap = S.need_sigmap;
if n <= 0 || nisig == 0 || ~S.bulk_read || S.has_dsbuf || ...
        ~(S.ifreq == 0 || S.ifreq == S.sfreq) || ...
        (S.nvsig ~= nisig && ~need_sigmap) || nisig > S.nvsig || ...
        nisig < minstat
    return;
end
ispfmax = S.ispfmax;
highres = ispfmax > 1 && bitand(S.gvmode, 1) == 1;  % WFDB_HIGHRES
if highres && S.gvc < ispfmax
    return;     % in the middle of a frame
end
igd = S.igd;
isd = S.isd;
info = [isd.info];
fmts = [info.fmt];
spfs = [info.spf];
grp = [info.group];
nsamp = [info.nsamp];
if ~all(ismember(fmts, [0 8 80 16 61 160 24 32 212 310 311 508 516 524]))
    return;
end
% (null signals, format 0: no file; their length must be known)
isnull = fmts == 0;
if any(isnull & nsamp <= 0)
    return;
end
% the groups with a file (one format per group), and those of null signals
fgrp = reshape(unique(grp(~isnull)), 1, []);
for g = fgrp
    sl = grp == g;
    if any(fmts(sl) ~= fmts(find(sl, 1)))
        return;
    end
    ig = igd{g + 1};
    if isempty(ig.flac)
        if ig.seek ~= 1 || isempty(ig.fp) || ig.initial_skip || ig.count
            return;
        end
    elseif ig.initial_skip || ig.count
        return;
    end
end
for g = reshape(unique(grp(isnull)), 1, [])
    if any(fgrp == g) || igd{g + 1}.stat <= 0
        return;
    end
end
% FLAC groups: decode them now (as the first flac_getsamp would)
for g = fgrp
    ig = igd{g + 1};
    if ~isempty(ig.flac)
        fi = ig.flac;
        if ~fi.decoded
            fi = wfdbx.internal.flac_ensure(ig);
            ig.flac = fi;
        end
        if ~isempty(fi.error) || fi.aborted || fi.discarded || ig.stat < 0
            return;     % (errors, and reads after a failed seek: getvec)
        end
    end
end
ok = true;
% the number of frames to read (n is a number of getvec vectors)
if highres
    per = ispfmax;      % vectors per frame
else
    per = 1;
end
n = floor(n / per);
ng = numel(fgrp);
% bytes (nb) per ns samples of each group's format; nn samples per frame;
% the alignment period (in frames) that keeps each group on a whole
% packed unit
nbv = zeros(1, ng);
nsv = zeros(1, ng);
nnv = zeros(1, ng);
period = 1;
for k = 1:ng
    sl = find(grp == fgrp(k));
    nnv(k) = sum(spfs(sl));
    switch fmts(sl(1))
        case {8, 80}
            nbv(k) = 1; nsv(k) = 1;
        case {16, 61, 160}
            nbv(k) = 2; nsv(k) = 1;
        case 24
            nbv(k) = 3; nsv(k) = 1;
        case 32
            nbv(k) = 4; nsv(k) = 1;
        case 212
            nbv(k) = 3; nsv(k) = 2;
        case {310, 311}
            nbv(k) = 4; nsv(k) = 3;
        otherwise   % FLAC: samples, not bytes
            nbv(k) = 1; nsv(k) = 1;
    end
    period = lcm(period, nsv(k) / gcd(nnv(k), nsv(k)));
end
% Stop at the frame at which a checksum is verified (it is included only
% if the checksums are found correct below; with FLAC or format 8 groups,
% not at all).
k = nsamp > 0 & n >= nsamp;
if any(k)
    n = min(nsamp(k));
    if any(fmts(~isnull) == 8) || any(cellfun(@(g) ~isempty(g.flac), igd(fgrp + 1)))
        n = n - 1;
    end
end
n = n - mod(n, period);
if n <= 0
    out = zeros(0, S.nvsig);
    return;
end
bufs = cell(1, ng);
haves = zeros(1, ng);
for k = 1:ng
    ig = igd{fgrp(k) + 1};
    if ~isempty(ig.flac)
        fi = ig.flac;
        avail = floor((numel(fi.samples) - fi.pos) / nnv(k));
        if avail < n
            n = avail;
        end
        continue;
    end
    [data, haves(k)] = bulk_read(S, ig, n * nnv(k) * nbv(k) / nsv(k));
    bufs{k} = data;
    unit = period * nnv(k) * nbv(k) / nsv(k);
    avail = floor(numel(data) / unit) * period;
    if avail < n
        n = avail;
    end
end
% Decode the frames of each group (C: n-by-nn; the sums and invalid
% samples of its columns).
Cs = cell(1, ng);
csums = cell(1, ng);
cinvs = cell(1, ng);
for k = 1:ng
    if n == 0
        break;
    end
    ig = igd{fgrp(k) + 1};
    fmt = fmts(find(grp == fgrp(k), 1));
    inval = -2^(wfdbx.internal.fmt_bits(fmt) - 1);   % the invalid value
    if isempty(ig.flac)
        [Cs{k}, csums{k}, cinvs{k}] = decode_frames(fmt, bufs{k}, nnv(k), n, ...
            period, inval, S.bulk_block);
    else
        C = reshape(wfdbx.internal.flac_getsamps(ig, n * nnv(k)), nnv(k), n).';
        Cs{k} = C;
        csums{k} = mod(sum(C, 1), 4294967296);
        cinvs{k} = any(C == inval, 1);
    end
end
% At the frame at which they are verified, the checksums must be correct
% (else getvec gives that frame, with an error).
chk = nsamp == n & ~isnull & fmts ~= 8;
if n > 0 && any(chk) && ~S.in_msrec && ~S.isedf
    bad = false;
    for k = 1:ng
        sl = find(grp == fgrp(k));
        off = 0;
        for s = sl
            cols = off + 1:off + spfs(s);
            off = off + spfs(s);
            if chk(s)
                c = cks_wrap(isd(s).info.cksum - sum(csums{k}(cols)));
                bad = bad || mod(c, 65536) ~= 0;
            end
        end
    end
    if bad
        m = n - 1;
        m = m - mod(m, period);
        for k = 1:ng
            C = Cs{k};
            csums{k} = mod(csums{k} - sum(C(m + 1:n, :), 1), 4294967296);
            C = C(1:m, :);
            Cs{k} = C;
            cinvs{k} = any(C == -2^(wfdbx.internal.fmt_bits(fmts(find(grp == fgrp(k), 1))) - 1), 1);
        end
        n = m;
    end
end
pad = bitand(S.gvmode, 2) ~= 0;      % WFDB_GVPAD
if S.istime == 0
    for s = 1:nisig
        isd(s).samp = isd(s).info.initval;
    end
end
% F: the frames (n-by-sum(spfs)); a single group's frames when it has
% every signal
coff = cumsum([0, spfs]);
whole = ng == 1 && ~any(isnull);
if ~whole
    F = zeros(n, coff(end));
end
for k = 1:ng
    ig = igd{fgrp(k) + 1};
    sl = find(grp == fgrp(k));
    fmt = fmts(sl(1));
    nn = nnv(k);
    if isempty(ig.flac)
        % (leave the unused bytes buffered, as the C library would)
        bulk_consume(S, ig, bufs{k}, haves(k), n * nn * nbv(k) / nsv(k));
    end
    if n == 0
        continue;
    end
    inval = -2^(wfdbx.internal.fmt_bits(fmt) - 1);
    C = Cs{k};
    Cs{k} = [];
    csum = csums{k};
    cinv = cinvs{k};
    off = 0;
    for kk = 1:numel(sl)
        s = sl(kk);
        spf = spfs(s);
        cols = off + 1:off + spf;
        off = off + spf;
        if fmt ~= 8
            isd(s).info.cksum = cks_wrap(isd(s).info.cksum - sum(csum(cols)));
            if ~any(cinv(cols))
                isd(s).samp = C(n, cols(end));
                continue;
            end
        end
        % the samples of signal s in time order
        col = reshape(C(:, cols).', [], 1);
        if fmt == 8
            % (the differences)
            v = cumsum(col) + isd(s).samp;
            v = v - 4294967296 * floor((v + 2147483648) / 4294967296);
            isd(s).samp = v(end);
            isd(s).info.cksum = cks_sub(isd(s).info.cksum, v);
        else
            inv = col == inval;
            if pad
                idx = (1:numel(col))';
                idx(inv) = 0;
                idx = cummax(idx);
                v = zeros(numel(col), 1) + isd(s).samp;
                m = idx > 0;
                v(m) = col(idx(m));
            else
                v = col;
                v(inv) = -32768;
            end
            valid = find(~inv, 1, 'last');
            if ~isempty(valid)
                isd(s).samp = col(valid);
            end
        end
        C(:, cols) = reshape(v, spf, n).';
    end
    if whole
        F = C;
    else
        F(:, coff(sl(1)) + 1:coff(sl(end) + 1)) = C;
    end
end
if n == 0
    S.isd = isd;
    out = zeros(0, S.nvsig);
    return;
end
for s = 1:nisig
    if isnull(s)
        % every sample: the previous one with WFDB_GVPAD, else invalid
        if pad
            v = isd(s).samp;
        else
            v = -32768;
        end
        F(:, coff(s) + 1:coff(s + 1)) = v;
        isd(s).info.cksum = cks_null(isd(s).info.cksum, v, n * spfs(s));
    end
    if isd(s).info.nsamp > 0
        isd(s).info.nsamp = isd(s).info.nsamp - n;
    elseif isd(s).info.nsamp == 0
        isd(s).info.nsamp = -1;
    end
end
S.isd = isd;
S.istime = S.istime + n;
% The frames as getframe gives them: mapped to the layout of a
% variable-layout record, or padded with invalid samples.
tspf = S.tspf;
if need_sigmap
    ov = S.ovec;
    ov(1:size(F, 2)) = F(end, :);
    S.ovec = ov;
    F = sigmap_rows(S, F);
elseif size(F, 2) < tspf
    F = [F, zeros(n, tspf - size(F, 2)) - 32768];
end
% The sample vectors, as getvec gives them.
nvsig = S.nvsig;
if ispfmax < 2
    out = F(:, 1:nvsig);
else
    vsd = S.vsd;
    tv = S.tvector;
    tv(1:tspf) = F(end, 1:tspf);
    S.tvector = tv;
    S.rgetvec_stat = nisig;
    if highres
        % per vectors per frame: signal s gives sample index of the frame
        % at each step (as rgetvec's gvindex and gvcount)
        out = zeros(n * per, nvsig);
        tp = 0;
        for s = 1:nvsig
            sf = vsd(s).info.spf;
            idx = zeros(1, per);
            index = 0;
            count = -per;
            for k = 2:per
                count = count + sf;
                if count >= 0
                    index = index + 1;
                    count = count - per;
                end
                idx(k) = index;
            end
            f = F(:, tp + idx + 1);
            out(:, s) = reshape(f.', [], 1);
            vsd(s).gvindex = index;
            vsd(s).gvcount = count;
            tp = tp + sf;
        end
        S.vsd = vsd;
        S.gvc = per;
    else
        % WFDB_LOWRES: the mean of the samples of each frame (meansamp)
        out = zeros(n, nvsig);
        tp = 0;
        for s = 1:nvsig
            sf = vsd(s).info.spf;
            out(:, s) = meansamp(F(:, tp + 1:tp + sf), sf);
            tp = tp + sf;
        end
    end
end
S.bulk_vectors = S.bulk_vectors + size(out, 1);
end

function [data, have] = bulk_read(S, ig, need)
% The next NEED bytes of input group IG (fewer at the end of the file): the
% bytes left in its buffer, then those of the blocks read ahead, then bytes
% read from its file, in whole blocks (as a refill reads them).  HAVE is
% the number of bytes of DATA that come from the buffer (the blocks begin
% there).  See bulk_consume.
have = max(ig.be - ig.bp, 0);     % (bp > be after a refill at the end)
if have >= need
    data = ig.buf(ig.bp + 1:ig.be);
    return;
end
bsize = ig.bsize;
if bsize <= 0
    bsize = S.ibsize;
end
ahead = numel(ig.ahead);
if need > have + ahead
    more = ig.fp.read(ceil((need - have - ahead) / bsize) * bsize);
else
    more = zeros(1, 0, 'uint8');
end
data = [ig.buf(ig.bp + 1:ig.bp + have), ig.ahead, more];
end

function bulk_consume(S, ig, data, have, used)
% Leave input group IG as the refills and the r* routines would after
% consuming the first USED bytes of DATA (from bulk_read: its buffered
% bytes, then whole blocks): the buffer is the block holding the last
% byte consumed (its stale bytes matter when a later refill finds the end
% of the file), and the blocks after it are kept for the refills
% (ig.ahead).
if used <= have
    % (still in the buffer; DATA begins at ig.bp)
    ig.bp = ig.bp + used;
    if numel(data) > have
        ig.ahead = data(have + 1:end);
    end
    return;
end
bsize = ig.bsize;
if bsize <= 0
    bsize = S.ibsize;
end
start = have + floor((used - have - 1) / bsize) * bsize;
block = data(start + 1:min(start + bsize, numel(data)));
ig.buf = block;
ig.bp = used - start;
ig.be = numel(block);
ig.stat = numel(block);
ig.ahead = data(min(start + bsize, numel(data)) + 1:end);
end

function c = cks_sub(c, x)
% The checksum C minus the sum of the samples X, wrapped to int (exact for
% any number of samples of at most 32 bits).
if numel(x) <= 4194304      % (the sum is below 2^53)
    t = sum(x);
else
    lo = mod(x, 65536);
    t = mod(sum((x - lo) / 65536), 65536) * 65536 + sum(lo);
end
c = c - t;
c = c - 4294967296 * floor((c + 2147483648) / 4294967296);     % (int)
end

function c = cks_wrap(c)
% C wrapped to int
c = c - 4294967296 * floor((c + 2147483648) / 4294967296);
end

function c = cks_null(c, v, cnt)
% The checksum C minus CNT times the sample V, wrapped to int.
u = mod(v, 4294967296);
t = mod(u * mod(cnt, 65536), 4294967296) + ...
    mod(u * floor(cnt / 65536), 65536) * 65536;
c = c - t;
c = c - 4294967296 * floor((c + 2147483648) / 4294967296);     % (int)
end

function out = sigmap_rows(S, F)
% wfdbx.internal.sigmap for each row of F.
WFDB_SAMPLE_MIN = -2147483648;  % INT_MIN
WFDB_SAMPLE_MAX = 2147483647;   % INT_MAX
smi = S.smi;
tspf = S.tspf;
idx = [smi(1:tspf).index] + 1;
scale = [smi(1:tspf).scale];
offset = [smi(1:tspf).offset];
so = [smi(1:tspf).sample_offset];
X = F(:, idx);
nr = size(X, 1);
V = X .* repmat(scale, nr, 1) + repmat(offset, nr, 1);
out = zeros(size(V)) + WFDB_SAMPLE_MIN;     % (NaN)
k = V >= 0;
out(k) = min(fix(V(k)), WFDB_SAMPLE_MAX);
k = V < 0;
out(k) = max(floor(V(k)), WFDB_SAMPLE_MIN);
c = find(so ~= 0);
if ~isempty(c)
    r = fix(V(:, c)) + repmat(so(c), nr, 1);
    out(:, c) = r - 4294967296 * floor((r + 2147483648) / 4294967296);   % (int)
end
out(X == -32768) = -32768;  % WFDB_INVALID_SAMPLE
end

function total = meansamp(sv, n)
% meansamp() of signal.c for each row of SV (N samples per row).
bad = any(sv == -32768, 2);
total = fix(n / 2) + sum(sv, 2);
if bitand(n, n - 1)
    neg = double(total < 0);
    total = fix((total + neg) / n) - neg;
else
    while true
        n = fix(n / 2);
        if n == 0
            break;
        end
        total = fix((total - double(total < 0)) / 2);
    end
end
total(bad) = -32768;
end

function [C, csum, cinv] = decode_frames(fmt, data, nn, n, period, inval, block)
% The N frames of NN samples each of a group in format FMT, at the start of
% the bytes DATA: an N-by-NN matrix (N is a multiple of PERIOD frames,
% which fill whole packed units).  CSUM: the sums of the columns modulo
% 2^32; CINV: true for the columns holding the invalid value INVAL.  The
% frames are decoded in blocks of about BLOCK samples (whose temporary
% arrays stay in the processor's cache), except those of formats 16 and 61.
if fmt == 16 || fmt == 61
    % (at once: the statistics from the 16-bit values; -32768, the invalid
    % value, is their minimum)
    X = reshape(typecast(data(1:2 * nn * n), 'int16'), nn, n);
    if fmt == 61
        X = swapbytes(X);
    end
    csum = mod(sum(X, 2, 'double'), 4294967296).';
    cinv = (min(X, [], 2) == inval).';
    C = double(X.');
    return;
end
[nb, ns] = fmt_unit(fmt);
ch = max(1, floor(block / (nn * period))) * period;
C = zeros(n, nn);
csum = zeros(1, nn);
cinv = false(1, nn);
for f = 0:ch:n - 1
    m = min(ch, n - f);
    b = f * nn * nb / ns;
    X = decode_block(fmt, data(b + 1:b + m * nn * nb / ns), nn, m);
    C(f + 1:f + m, :) = X;
    csum = mod(csum + sum(X, 1), 4294967296);
    cinv = cinv | any(X == inval, 1);
end
end

function [nb, ns] = fmt_unit(fmt)
% NB bytes per NS samples of format FMT (FLAC: samples, not bytes)
switch fmt
    case {16, 61, 160}
        nb = 2; ns = 1;
    case 24
        nb = 3; ns = 1;
    case 32
        nb = 4; ns = 1;
    case 212
        nb = 3; ns = 2;
    case {310, 311}
        nb = 4; ns = 3;
    otherwise   % 8, 80, FLAC
        nb = 1; ns = 1;
end
end

function C = decode_block(fmt, data, nn, n)
% The N-by-NN frames of format FMT in the bytes DATA (whole packed units).
ns = nn * n;
switch fmt
    case 16
        X = typecast(data, 'int16');
    case 61
        X = swapbytes(typecast(data, 'int16'));
    case 80
        C = double(reshape(data, nn, n).') - 128;
        return;
    case 160
        C = double(reshape(typecast(data, 'uint16'), nn, n).') - 32768;
        return;
    case 8
        X = typecast(data, 'int8');
    case 32
        X = typecast(data, 'int32');
    case 24
        b = reshape(data, 3, ns);
        x = 0:255;
        v = double(b(1, :)) + 256 * double(b(2, :)) + ...
            lut(65536 * (x - 256 * (x >= 128)), b(3, :));
        C = reshape(v, nn, n).';
        return;
    case 212
        % two samples in 3 bytes: the low byte of each, and the high
        % nibbles in the middle byte (tables give the signed values)
        b = reshape(data, 3, ns / 2);
        x = 0:255;
        lo = mod(x, 16);
        hi = (x - lo) / 16;
        b2 = double(b(2, :)) + 1;
        L = 256 * lo - 4096 * (lo >= 8);
        H = 256 * hi - 4096 * (hi >= 8);
        C = lanes_frames({double(b(1, :)) + L(b2), double(b(3, :)) + H(b2)}, ...
            nn, n);
        return;
    otherwise   % 310, 311: three samples in 4 bytes
        b = reshape(data, 4, ns / 3);
        x = 0:255;
        if fmt == 310
            % bits 1-10 of each 16-bit word, then bits 11-15 of both
            m8 = mod(x, 8);
            L1 = floor(x / 2);
            L2 = 128 * m8 - 1024 * (m8 >= 4);
            P = {lut(L1, b(1, :)) + lut(L2, b(2, :)), ...
                lut(L1, b(3, :)) + lut(L2, b(4, :)), ...
                lut(floor(x / 8), b(2, :)) + ...
                lut(32 * floor(x / 8) - 1024 * (x >= 128), b(4, :))};
        else
            % bits 0-9, 10-19, 20-29 of the 32-bit word
            m4 = mod(x, 4);
            m16 = mod(x, 16);
            m64 = mod(x, 64);
            P = {double(b(1, :)) + lut(256 * m4 - 1024 * (m4 >= 2), b(2, :)), ...
                lut(floor(x / 4), b(2, :)) + ...
                lut(64 * m16 - 1024 * (m16 >= 8), b(3, :)), ...
                lut(floor(x / 16), b(3, :)) + ...
                lut(16 * m64 - 1024 * (m64 >= 32), b(4, :))};
        end
        C = lanes_frames(P, nn, n);
        return;
end
C = double(reshape(X, nn, n).');
end

function v = lut(T, b)
% T(b + 1) for the bytes b
v = T(double(b) + 1);
end

function C = lanes_frames(P, nn, n)
% The N-by-NN frames of a bit-packed format of K = numel(P) samples per
% unit: sample j (from 0) of the frames is P{mod(j, K) + 1}(floor(j / K) + 1).
k = numel(P);
if nn == k
    C = zeros(n, nn);
    for j = 1:k
        C(:, j) = P{j};
    end
    return;
end
V = zeros(k, numel(P{1}));
for j = 1:k
    V(j, :) = P{j};
end
C = reshape(V, nn, n).';
end
