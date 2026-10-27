function frame = flac_encode_frame(block, bps, frame_no)
%FLAC_ENCODE_FRAME Encode one FLAC frame.
%   FRAME = wfdbx.internal.flac_encode_frame(BLOCK, BPS, FRAME_NO) returns
%   the bytes (uint8 row) of FLAC frame number FRAME_NO (0-based) holding
%   the samples BLOCK (one row per channel, integers that fit in BPS bits;
%   BPS is 8, 16 or 24), exactly as the encoder of the Python
%   implementation of WFDB-x writes it: independent channels, each coded as
%   a constant, fixed-predictor (order 0 to 4, the cheapest) or verbatim
%   subframe, with Rice partitions (partition order 0 to 6) whose
%   parameters are chosen near the mean of the folded residuals; a 96 kHz
%   sample rate is recorded.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
% has no counterpart in the original package: it is WFDB-x's own implementation
% of the FLAC format, which the original package reads and writes with libFLAC.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

[nch, n] = size(block);
% frame header (fields as in the FLAC format specification, RFC 9639):
% sync code 0xfff8, block size code, sample rate code 11 (96 kHz),
% channels, sample size code, the frame number (UTF-8 coded), CRC-8
if n == 4096
    bsc = 12;
elseif n <= 256
    bsc = 6;
else
    bsc = 7;
end
switch bps
    case 8
        ssc = 1;
    case 16
        ssc = 4;
    case 24
        ssc = 6;
    otherwise
        ssc = 0;
end
head = [255, 248, bsc * 16 + 11, (nch - 1) * 16 + ssc * 2, utf8(frame_no)];
if bsc == 6
    head = [head, n - 1];
elseif bsc == 7
    head = [head, floor((n - 1) / 256), mod(n - 1, 256)];
end
head = [head, wfdbx.internal.flac_crc(head, 8)];
% subframes: fields (values and widths), then bits
V = cell(1, nch);
Wd = cell(1, nch);
for c = 1:nch
    [V{c}, Wd{c}] = subframe(block(c, :), bps);
end
bytes = packbits([V{:}], [Wd{:}]);
frame = [head, bytes];
c16 = wfdbx.internal.flac_crc(frame, 16);
frame = uint8([frame, floor(c16 / 256), mod(c16, 256)]);
end

function b = utf8(v)
% The "UTF-8" coding of FLAC (up to 36 bits): a lead byte and n
% continuation bytes of 6 bits each.
if v < 128
    b = v;
    return;
end
lead = [192 224 240 248 252 254];
mx = [2047 65535 2097151 67108863 2147483647 68719476735];
for n = 1:6
    if v <= mx(n)
        b = zeros(1, n + 1);
        for k = n+1:-1:2
            b(k) = 128 + mod(v, 64);
            v = floor(v / 64);
        end
        b(1) = lead(n) + v;
        return;
    end
end
error('wfdbx:flac:utf8', 'frame number too large');
end

function bytes = packbits(v, w)
% The bits of the fields (value v(i) on w(i) bits, MSB first), padded
% with zeros to a whole number of bytes.
w = double(w);
k = w > 0;
v = v(k);
w = w(k);
T = sum(w);
nb = ceil(T / 8);
bits = zeros(1, 8 * nb);
if T > 0
    ends = cumsum(w);                   % position of the last bit of each
    bits(ends(v == 1)) = 1;             % (all unary codes)
    gen = find(v > 1);
    maxw = max([0, w(gen)]);
    for j = 0:maxw-1
        sel = gen(w(gen) > j);
        bits(ends(sel) - j) = mod(floor(v(sel) / 2^j), 2);
    end
end
bytes = [128 64 32 16 8 4 2 1] * reshape(bits, 8, nb);
end

function [V, W] = subframe(x, bps)
n = numel(x);
mb = 2^bps;
% subframe header: zero bit, type (6 bits: 0 constant, 1 verbatim, 8 +
% order fixed), no wasted bits
if all(x == x(1))
    V = [0, 0, 0, mod(x(1), mb)];
    W = [1, 6, 1, bps];
    return;
end
maxk = 30;                              % largest Rice parameter (31 is an escape code)
bestcost = inf;
for order = 0:min(4, n - 1)
    if order == 0
        r = x;
    else
        r = diff(x, order);
    end
    u = 2 * abs(r) - (r < 0);           % folded residuals
    [pc, porder, params] = best_partition(u, order, n, maxk);
    cost = order * bps + 2 + pc;
    if cost < bestcost
        bestcost = cost;
        border = order;
        bu = u;
        bporder = porder;
        bparams = params;
    end
end
if bestcost >= n * bps
    V = [0, 1, 0, mod(x, mb)];          % verbatim
    W = [1, 6, 1, bps * ones(1, n)];
    return;
end
order = border;
u = bu;
porder = bporder;
params = bparams;
if max(params) < 15                     % 4-bit parameters (RICE), else 5-bit (RICE2)
    method = 0;
    pbits = 4;
else
    method = 1;
    pbits = 5;
end
nparts = 2^porder;
psize = n / nparts;
% header, warm-up samples, residual coding parameters
V = [0, 8 + order, 0, mod(x(1:order), mb), method, porder];
W = [1, 6, 1, bps * ones(1, order), 2, 4];
% partitions: parameter, then the codes (q zeros and a one, then k bits)
cnt = psize * ones(1, nparts);
cnt(1) = psize - order;
m = numel(u);
kk = repelem(params, cnt);              % parameter of each residual
q = floor(u ./ 2.^kk);
low = u - q .* 2.^kk;
% fields per partition: [k] then per residual [1 (q+1 bits), low (k bits)]
nf = nparts + 2 * m;
PV = zeros(1, nf);
PW = zeros(1, nf);
start = cumsum([0, cnt(1:end-1)]);      % residuals before each partition
ppos = start * 2 + (0:nparts-1) + 1;    % field index of each parameter
PV(ppos) = params;
PW(ppos) = pbits;
part = repelem(1:nparts, cnt);
ridx = 1:m;
fpos = ppos(part) + 2 * (ridx - start(part)) - 1;   % field of the unary code
PV(fpos) = 1;
PW(fpos) = q + 1;
PV(fpos + 1) = low;
PW(fpos + 1) = kk;
V = [V, PV];
W = [W, PW];
end

function [best, bporder, bparams] = best_partition(u, order, n, maxk)
best = inf;
bporder = 0;
bparams = 0;
for porder = 0:6
    nparts = 2^porder;
    if mod(n, nparts)
        break;
    end
    psize = n / nparts;
    if porder > 0 && psize <= order
        break;
    end
    U = reshape([zeros(1, order), u], psize, nparts);
    cnt = psize * ones(1, nparts);
    cnt(1) = psize - order;
    sums = sum(U, 1);
    params = zeros(1, nparts);
    cost = 6 + 4 * nparts;
    nz = cnt > 0;
    mean = zeros(1, nparts);
    mean(nz) = floor(sums(nz) ./ cnt(nz));
    [~, e] = log2(mean);                % bit length of mean (mean > 0)
    k0 = zeros(1, nparts);
    k0(mean > 0) = e(mean > 0) - 1;
    lo = min(max(k0 - 1, 0), maxk);
    hi = min(k0 + 2, maxk);
    bc = inf(1, nparts);
    for d = 0:3
        k = lo + d;
        ok = k <= hi & nz;
        if ~any(ok)
            continue;
        end
        c = sum(floor(U(:, ok) ./ 2.^k(ok)), 1) + cnt(ok) .* (k(ok) + 1);
        better = false(1, nparts);
        better(ok) = c < bc(ok);
        cc = inf(1, nparts);
        cc(ok) = c;
        bc(better) = cc(better);
        params(better) = k(better);
    end
    cost = cost + sum(bc(nz));
    if cost < best
        best = cost;
        bporder = porder;
        bparams = params;
    end
end
end
