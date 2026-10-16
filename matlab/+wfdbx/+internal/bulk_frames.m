function [out, ok] = bulk_frames(n)
%BULK_FRAMES Read many sample vectors at once with vector operations.
%   [OUT, OK] = wfdbx.internal.bulk_frames(N) reads up to N sample vectors
%   (as returned by getvec: one row per vector, one column per signal),
%   exactly as N calls of getvec would, decoding whole frames with vector
%   operations.  Multi-frequency records are handled in WFDB_LOWRES mode
%   (frame averages, as meansamp) and WFDB_HIGHRES mode (ispfmax vectors
%   per frame), and FLAC groups through wfdbx.internal.flac_getsamps.
%   Fewer vectors (possibly none) are read when a frame would require
%   special handling (end of file, a frame at which a checksum is
%   verified, a partial bit-packed group, a partial frame in WFDB_HIGHRES
%   mode, ...), so that the caller can use getvec for the next one.  OK is
%   false (and OUT empty) if the bulk path cannot be used at all (skew,
%   variable-layout multi-segment records, resampling with setifreq,
%   signals without files, a FLAC decoding error, a prolog not yet
%   skipped, ...).

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
out = [];
ok = false;
nisig = S.nisig;
if n <= 0 || nisig == 0 || S.need_sigmap || S.has_dsbuf || ...
        S.nvsig ~= nisig || ~(S.ifreq == 0 || S.ifreq == S.sfreq)
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
if ~all(ismember(fmts, [8 80 16 61 160 24 32 212 310 311 508 516 524]))
    return;
end
for g = 1:S.nigroup
    ig = igd{g};
    if isempty(ig.flac)
        if ig.seek ~= 1 || isempty(ig.fp) || ig.initial_skip || ig.count
            return;
        end
    elseif ig.initial_skip || ig.count
        return;
    end
end
% FLAC groups: decode them now (as the first flac_getsamp would)
for g = 1:S.nigroup
    ig = igd{g};
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
    n = floor(n / ispfmax);
end
grp = [info.group];
ng = S.nigroup;
% bytes (nb) per ns samples of each format; nn samples per frame
nbv = zeros(1, ng);
nsv = zeros(1, ng);
nnv = zeros(1, ng);
period = 1;
for g = 1:ng
    sl = find(grp == g - 1);
    nnv(g) = sum(spfs(sl));
    switch fmts(sl(1))
        case {8, 80}
            nbv(g) = 1; nsv(g) = 1;
        case {16, 61, 160}
            nbv(g) = 2; nsv(g) = 1;
        case 24
            nbv(g) = 3; nsv(g) = 1;
        case 32
            nbv(g) = 4; nsv(g) = 1;
        case 212
            nbv(g) = 3; nsv(g) = 2;
        case {310, 311}
            nbv(g) = 4; nsv(g) = 3;
        otherwise   % FLAC: samples, not bytes
            nbv(g) = 1; nsv(g) = 1;
    end
    if nsv(g) == 2 && mod(nnv(g), 2)
        period = lcm(period, 2);
    elseif nsv(g) == 3 && mod(nnv(g), 3)
        period = lcm(period, 3);
    end
end
% Do not include a frame at which a checksum would be verified.
nsamp = [info.nsamp];
k = nsamp > 0 & n >= nsamp;
if any(k)
    n = min(nsamp(k)) - 1;
end
n = n - mod(n, period);
if n <= 0
    out = zeros(0, nisig);
    return;
end
bufs = cell(1, ng);
for g = 1:ng
    ig = igd{g};
    if ~isempty(ig.flac)
        fi = ig.flac;
        avail = floor((numel(fi.samples) - fi.pos) / nnv(g));
        if avail < n
            n = avail;
        end
        continue;
    end
    need = n * nnv(g) * nbv(g) / nsv(g);
    bp = ig.bp;
    be = ig.be;
    have = be - bp;
    if have >= need
        data = ig.buf(bp + 1:be);
    else
        more = ig.fp.read(need - have);
        data = [ig.buf(bp + 1:be), more];
    end
    bufs{g} = data;
    unit = period * nnv(g) * nbv(g) / nsv(g);
    avail = floor(numel(data) / unit) * period;
    if avail < n
        n = avail;
    end
end
frames = cell(1, nisig);    % samples of each signal: n-by-spf
pad = bitand(S.gvmode, 2) ~= 0;      % WFDB_GVPAD
if S.istime == 0
    for s = 1:nisig
        isd(s).samp = isd(s).info.initval;
    end
end
for g = 1:ng
    ig = igd{g};
    data = bufs{g};
    sl = find(grp == g - 1);
    fmt = fmts(sl(1));
    nn = nnv(g);
    if n == 0
        if isempty(ig.flac)
            ig.buf = data;
            ig.bp = 0;
            ig.be = numel(data);
            ig.stat = max(ig.stat, 1);
        end
        continue;
    end
    if isempty(ig.flac)
        used = n * nn * nbv(g) / nsv(g);
        ig.buf = data;
        ig.bp = used;
        ig.be = numel(data);
        ig.stat = max(ig.stat, 1);
        raw = reshape(decode(fmt, data, n * nn), nn, n);
    else
        raw = reshape(wfdbx.internal.flac_getsamps(ig, n * nn), nn, n);
    end
    off = 0;
    for kk = 1:numel(sl)
        s = sl(kk);
        spf = spfs(s);
        % the samples of signal s in time order
        col = reshape(raw(off + 1:off + spf, :), [], 1);
        off = off + spf;
        if fmt == 8
            v = cumsum(col) + isd(s).samp;
            v = v - 4294967296 * floor((v + 2147483648) / 4294967296);
            isd(s).samp = v(end);
            cks = sum(v);
        else
            inval = -2^(wfdbx.internal.fmt_bits(fmt) - 1);   % the invalid value
            inv = col == inval;
            cks = sum(col);
            if any(inv)
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
            else
                v = col;
                isd(s).samp = col(end);
            end
        end
        frames{s} = reshape(v, spf, n).';
        c = isd(s).info.cksum - cks;
        isd(s).info.cksum = c - 4294967296 * floor((c + 2147483648) / 4294967296);
        if isd(s).info.nsamp > 0
            isd(s).info.nsamp = isd(s).info.nsamp - n;
        elseif isd(s).info.nsamp == 0
            isd(s).info.nsamp = -1;
        end
    end
end
S.isd = isd;
S.istime = S.istime + n;
if n == 0
    out = zeros(0, nisig);
elseif ispfmax == 1
    out = [frames{:}];
elseif highres
    % ispfmax vectors per frame; signal s gives sample floor(c*spf/ispfmax)
    % of the frame at step c (as rgetvec's gvindex/gvcount)
    out = zeros(n * ispfmax, nisig);
    c = (0:ispfmax - 1)';
    for s = 1:nisig
        idx = floor(c * spfs(s) / ispfmax) + 1;
        f = frames{s};
        out(:, s) = reshape(f(:, idx).', [], 1);
    end
    S.gvc = ispfmax;
    S.rgetvec_stat = nisig;
    S.tvector = cell2mat(cellfun(@(f) f(end, :), frames, 'UniformOutput', false));
else
    % WFDB_LOWRES: the mean of the samples of each frame (meansamp)
    out = zeros(n, nisig);
    for s = 1:nisig
        out(:, s) = meansamp(frames{s}, spfs(s));
    end
end
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

function v = decode(fmt, data, nsamp)
% Decode NSAMP samples of format FMT from the bytes DATA (aligned).
switch fmt
    case 16
        v = double(typecast(data(1:2 * nsamp), 'int16'));
    case 61
        b = reshape(data(1:2 * nsamp), 2, nsamp);
        v = double(typecast(reshape(b([2 1], :), 1, []), 'int16'));
    case 80
        v = double(data(1:nsamp)) - 128;
    case 160
        v = double(typecast(data(1:2 * nsamp), 'uint16')) - 32768;
    case 8
        v = double(typecast(data(1:nsamp), 'int8'));
    case 32
        v = double(typecast(data(1:4 * nsamp), 'int32'));
    case 24
        b = double(reshape(data(1:3 * nsamp), 3, nsamp));
        v = b(1, :) + 256 * b(2, :) + 65536 * b(3, :);
        v = v - 16777216 * (v >= 8388608);
    case 212
        npair = ceil(nsamp / 2);
        b = double(reshape(data(1:3 * npair), 3, npair));
        v = zeros(1, 2 * npair);
        h = mod(b(2, :), 16);
        v(1:2:end) = b(1, :) + 256 * h;
        v(2:2:end) = b(3, :) + 16 * (b(2, :) - h);
        v = v(1:nsamp);
        v = v - 4096 * (v >= 2048);
    otherwise   % 310, 311
        ntrip = ceil(nsamp / 3);
        b = double(reshape(data(1:4 * ntrip), 4, ntrip));
        v = zeros(1, 3 * ntrip);
        w0 = b(1, :) + 256 * b(2, :);
        if fmt == 310
            w1 = b(3, :) + 256 * b(4, :);
            v(1:3:end) = mod(floor(w0 / 2), 1024);
            v(2:3:end) = mod(floor(w1 / 2), 1024);
            v(3:3:end) = floor(w0 / 2048) + 32 * floor(w1 / 2048);
        else
            v(1:3:end) = mod(w0, 1024);
            v(2:3:end) = floor(w0 / 1024) + 64 * mod(b(3, :), 16);
            v(3:3:end) = mod(floor((b(3, :) + 256 * b(4, :)) / 16), 1024);
        end
        v = v(1:nsamp);
        v = v - 1024 * (v >= 512);
end
v = reshape(v, 1, []);
end
