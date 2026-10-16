function [chans, bps, md5, nsig_si, block_ends] = flac_decode(data, nsig, datb)
%FLAC_DECODE Decode a complete FLAC stream.
%   [CHANS, BPS, MD5] = wfdbx.internal.flac_decode(DATA) decodes the FLAC
%   stream DATA (a uint8 vector: the whole file) and returns its samples
%   as a matrix CHANS (one row per channel, double values), the number of
%   bits per sample BPS of the stream (from STREAMINFO) and the MD5
%   signature stored in STREAMINFO (16 bytes, uint8).  All features of
%   FLAC are supported: constant, verbatim, fixed and LPC subframes, Rice
%   and Rice2 partitions with escape codes, wasted bits, stereo
%   decorrelation, variable block sizes; header (CRC-8) and frame (CRC-16)
%   checksums are verified.  Zero bytes after the last frame are ignored.
%
%   [...] = wfdbx.internal.flac_decode(DATA, NSIG, DATB) also checks, as
%   the WFDB library does, that each frame has NSIG channels and at most
%   DATB bits per sample (printing "getvec: wrong number of signals ..."
%   or "getvec: wrong sample resolution ..." otherwise).
%
%   Errors are thrown with the identifiers wfdbx:flac:STATUS, where STATUS
%   is 'meta' (invalid stream header or metadata), 'sync' (lost sync),
%   'header' (invalid frame header), 'crc' (CRC mismatch), 'unparseable'
%   (unsupported format), 'eof' (truncated stream) or 'wfdb' (the checks
%   above).
%
%   [CHANS, BPS, MD5, NSIG_SI, BLOCK_ENDS] = ... also returns the number
%   of channels given by STREAMINFO and the end of each frame (FLAC
%   block), in samples per channel.
%
%   This is a port of the decoder of the Python implementation of wfdb-x
%   (python/src/wfdbx/_flac.py), with Rice codes decoded by vector
%   operations.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if nargin < 2
    nsig = [];
    datb = [];
end
data = reshape(data, 1, []);
L = numel(data);
if L < 4 || ~isequal(double(data(1:4)), [102 76 97 67])     % 'fLaC'
    ferr('meta');
end
pos = 4;                                % 0-based
si_bps = 0;
si_ch = 0;
md5 = zeros(1, 16, 'uint8');
while true
    if pos + 4 > L
        ferr('meta');
    end
    hb = double(data(pos+1));
    ln = double(data(pos+2:pos+4)) * [65536; 256; 1];
    if pos + 4 + ln > L
        ferr('meta');
    end
    if mod(hb, 128) == 0                        % STREAMINFO (34 bytes)
        if ln < 34
            ferr('meta');
        end
        b = double(data(pos+17:pos+18));        % bits 96..111 of STREAMINFO
        % channels (3 bits) and bits per sample (5 bits) are at bit 100
        x = b(1) * 256 + b(2);
        si_ch = mod(floor(x / 2^9), 8) + 1;
        si_bps = mod(floor(x / 16), 32) + 1;
        md5 = data(pos+23:pos+38);
    end
    pos = pos + 4 + ln;
    if hb >= 128                                % last metadata block
        break;
    end
end
nsig_si = si_ch;
frames = cell(1, 0);
nf = 0;
W = 4096;                               % window (bytes) for the next frame
while pos < L
    try
        [fr, fbps, newpos] = decode_frame(data, pos, si_bps, W);
    catch err
        if strcmp(err.identifier, 'wfdbx:flac:window')
            W = 4 * W;
            continue;
        end
        if strcmp(err.identifier, 'wfdbx:flac:sync') && ~any(data(pos+1:end))
            break;
        end
        rethrow(err);
    end
    if ~isempty(nsig) && size(fr, 1) ~= nsig
        wfdbx.internal.wfdb_error( ...
            'getvec: wrong number of signals in FLAC signal file\n');
        ferr('wfdb');
    end
    if ~isempty(datb) && fbps > datb
        wfdbx.internal.wfdb_error( ...
            'getvec: wrong sample resolution in FLAC signal file\n');
        ferr('wfdb');
    end
    nf = nf + 1;
    if nf > numel(frames)
        frames{2 * nf} = [];
    end
    frames{nf} = fr;
    W = max(1024, 2 * (newpos - pos) + 64);
    pos = newpos;
end
% the end of each frame (FLAC block), in samples per channel
block_ends = zeros(1, nf);
for k = 1:nf
    block_ends(k) = size(frames{k}, 2);
end
block_ends = cumsum(block_ends);
if nf == 0
    chans = zeros(max(si_ch, 1), 0);
else
    nch = max(si_ch, 1);
    m = 0;
    for k = 1:nf
        m = max(m, size(frames{k}, 1));
    end
    if m ~= nch
        % (frames with another number of channels than STREAMINFO: the
        % Python decoder pairs channels with zip)
        nch = min(nch, m);
        for k = 1:nf
            nch = min(nch, size(frames{k}, 1));
        end
        for k = 1:nf
            frames{k} = frames{k}(1:nch, :);
        end
    end
    chans = [frames{1:nf}];
end
bps = si_bps;
end

function ferr(status)
error(['wfdbx:flac:' status], 'FLAC decoding error: %s', status);
end

function [chans, bps, newpos] = decode_frame(data, pos, si_bps, W)
% Decode one frame at byte offset pos (0-based).
L = numel(data);
% (frame header fields as in the FLAC format specification, RFC 9639)
if pos + 2 > L || data(pos+1) ~= 255 || bitand(double(data(pos+2)), 254) ~= 248  % sync 0xfff8
    ferr('sync');
end
e = min(L, pos + W);
br.atend = e == L;
br.B = tobits(data(pos+1:e));
br.p = 0;
[~, br] = rd(br, 16);
[bsc, br] = rd(br, 4);
[src, br] = rd(br, 4);
[chc, br] = rd(br, 4);
[ssc, br] = rd(br, 3);
[x, br] = rd(br, 1);
if x
    ferr('header');
end
% UTF-8 coded frame or sample number (lead byte: number of extra bytes)
[x, br] = rd(br, 8);
if x >= 128
    if x >= 192 && x < 224
        n = 1;
    elseif x >= 224 && x < 240
        n = 2;
    elseif x >= 240 && x < 248
        n = 3;
    elseif x >= 248 && x < 252
        n = 4;
    elseif x >= 252 && x < 254
        n = 5;
    elseif x == 254
        n = 6;
    else
        ferr('header');
    end
    for k = 1:n
        [y, br] = rd(br, 8);
        if y < 128 || y >= 192
            ferr('header');
        end
    end
end
switch bsc          % block size code
    case 0
        ferr('header');
    case 6
        [x, br] = rd(br, 8);
        blocksize = x + 1;
    case 7
        [x, br] = rd(br, 16);
        blocksize = x + 1;
    otherwise
        bs = [192 576 1152 2304 4608 0 0 256 512 1024 2048 4096 8192 16384 32768];
        blocksize = bs(bsc);
end
if src == 12        % sample rate code: rate in the 8 or 16 bits that follow
    [~, br] = rd(br, 8);
elseif src == 13 || src == 14
    [~, br] = rd(br, 16);
elseif src == 15
    ferr('header');
end
switch ssc          % sample size code
    case 0
        bps = si_bps;
    case 1
        bps = 8;
    case 2
        bps = 12;
    case 4
        bps = 16;
    case 5
        bps = 20;
    case 6
        bps = 24;
    case 7
        bps = 32;
    otherwise
        ferr('header');
end
hend = br.p / 8;
[crc, br] = rd(br, 8);
if wfdbx.internal.flac_crc(data(pos+1:pos+hend), 8) ~= crc
    ferr('header');
end
if chc < 8
    nch = chc + 1;
    chans = zeros(nch, blocksize);
    for c = 1:nch
        [chans(c, :), br] = subframe(br, blocksize, bps);
    end
elseif chc <= 10
    if chc == 8                         % left/side
        [a, br] = subframe(br, blocksize, bps);
        [sd, br] = subframe(br, blocksize, bps + 1);
        chans = [a; a - sd];
    elseif chc == 9                     % side/right
        [sd, br] = subframe(br, blocksize, bps + 1);
        [b, br] = subframe(br, blocksize, bps);
        chans = [sd + b; b];
    else                                % mid/side
        [m, br] = subframe(br, blocksize, bps);
        [sd, br] = subframe(br, blocksize, bps + 1);
        m = 2 * m + mod(sd, 2);
        chans = [floor((m + sd) / 2); floor((m - sd) / 2)];
    end
else
    ferr('header');
end
br.p = 8 * ceil(br.p / 8);
fend = br.p / 8;
[crc, br] = rd(br, 16);
if wfdbx.internal.flac_crc(data(pos+1:pos+fend), 16) ~= crc
    ferr('crc');
end
newpos = pos + br.p / 8;
end

function B = tobits(bytes)
B = reshape(mod(floor(double(bytes) ./ [128; 64; 32; 16; 8; 4; 2; 1]), 2), 1, []);
end

function overrun(br)
if br.atend
    ferr('eof');
end
error('wfdbx:flac:window', 'window');
end

function [v, br] = rd(br, n)
% read n bits (unsigned)
if n == 0
    v = 0;
    return;
end
p = br.p;
if p + n > numel(br.B)
    overrun(br);
end
v = br.B(p+1:p+n) * pow2(n-1:-1:0)';
br.p = p + n;
end

function [v, br] = rds(br, n)
% read n bits (signed)
[v, br] = rd(br, n);
if n && v >= 2^(n-1)
    v = v - 2^n;
end
end

function [v, br] = rdvec(br, cnt, n)
% read cnt values of n bits (signed)
if n == 0 || cnt == 0
    v = zeros(1, cnt);
    return;
end
p = br.p;
if p + cnt * n > numel(br.B)
    overrun(br);
end
M = reshape(br.B(p+1:p+cnt*n), n, cnt);
v = pow2(n-1:-1:0) * M;
v = v - (v >= 2^(n-1)) * 2^n;
br.p = p + cnt * n;
end

function [u, br] = unary(br)
k = find(br.B(br.p+1:end), 1);
if isempty(k)
    overrun(br);
end
u = k - 1;
br.p = br.p + k;
end

function [s, br] = subframe(br, blocksize, bps)
[x, br] = rd(br, 1);
if x
    ferr('unparseable');
end
[t, br] = rd(br, 6);
wasted = 0;
[x, br] = rd(br, 1);
if x
    [u, br] = unary(br);
    wasted = u + 1;
    bps = bps - wasted;
end
if t == 0
    [v, br] = rds(br, bps);
    s = v * ones(1, blocksize);
elseif t == 1
    [s, br] = rdvec(br, blocksize, bps);
elseif t >= 8 && t <= 12
    order = t - 8;
    [w, br] = rdvec(br, order, bps);
    [r, br] = residual(br, blocksize, order);
    s = [w, zeros(1, blocksize - order)];
    if order == 0
        s = r;
    elseif ~isempty(r)
        % s = order-fold cumulative sums of the residuals, starting from
        % the differences of the warm-up samples
        d = w;
        last = zeros(1, order);
        for m = 0:order-1
            last(m+1) = d(end);
            d = diff(d);
        end
        x = r;
        for m = order-1:-1:0
            x = last(m+1) + cumsum(x);
        end
        s(order+1:end) = x;
    end
elseif t >= 32
    order = t - 31;
    [w, br] = rdvec(br, order, bps);
    [prec, br] = rd(br, 4);
    prec = prec + 1;
    if prec == 16
        ferr('unparseable');
    end
    [shift, br] = rds(br, 5);
    [coefs, br] = rdvec(br, order, prec);
    [r, br] = residual(br, blocksize, order);
    if shift < 0
        ferr('unparseable');
    end
    s = lpc_restore(w, r, fliplr(coefs), shift);
else
    ferr('unparseable');
end
if wasted
    s = s * 2^wasted;
end
end

function s = lpc_restore(w, r, c, shift)
% s(i) = r(i) + floor(sum(c .* s(i-order:i-1)) / 2^shift)
order = numel(w);
n = order + numel(r);
s = zeros(1, n);
s(1:order) = w;
c = c(:);
d = 2^shift;
for i = order+1:n
    s(i) = r(i-order) + floor(s(i-order:i-1) * c / d);
end
end

function [out, br] = residual(br, blocksize, order)
[method, br] = rd(br, 2);
if method > 1
    ferr('unparseable');
end
if method == 0
    pbits = 4;
    esc = 15;
else
    pbits = 5;
    esc = 31;
end
[porder, br] = rd(br, 4);
nparts = 2^porder;
if mod(blocksize, nparts)
    ferr('unparseable');
end
psize = blocksize / nparts;
if porder > 0 && psize < order
    ferr('unparseable');
end
out = zeros(1, blocksize - order);
o = 0;
for part = 1:nparts
    if part == 1
        n = psize - order;
    else
        n = psize;
    end
    [k, br] = rd(br, pbits);
    if k == esc
        [nb, br] = rd(br, 5);
        [v, br] = rdvec(br, n, nb);
    else
        [u, br] = rice(br, n, k);
        v = floor(u / 2);
        odd = u - 2 * v;
        v(odd == 1) = -v(odd == 1) - 1;
    end
    out(o+1:o+n) = v;
    o = o + n;
end
end

function [u, br] = rice(br, n, k)
% Decode n Rice codes with parameter k (unary quotient, then k bits).
if n == 0
    u = zeros(1, 0);
    return;
end
B = br.B;
p0 = br.p;
NB = numel(B);
win = n * (k + 4) + 256;
while true
    e = min(NB, p0 + win);
    seg = B(p0+1:e);
    O = find(seg);                      % 1-based positions of the ones
    full = e == NB;
    if k == 0
        if numel(O) >= n
            T = O(1:n);
            u = T - [0, T(1:end-1)] - 1;
            br.p = p0 + T(n);
            return;
        end
    else
        M = numel(O);
        if M > 0
            len = numel(seg);
            % index (into O) of the first one at or after each position
            cnt = [0, cumsum(seg)];     % cnt(p) = ones before position p
            q = O + 1 + k;              % start of the next code
            J = M + 1 + zeros(1, M + 1);
            ok = q <= len;
            J(ok) = cnt(q(ok)) + 1;
            J(J > M) = M + 1;
            % the n codes: idx(i) = J^(i-1)(1), by pointer doubling
            idx = ones(1, n);
            ii = 0:n-1;
            Jp = J;
            b = 1;
            while b <= n - 1
                sel = bitand(ii, b) ~= 0;
                idx(sel) = Jp(idx(sel));
                Jp = Jp(Jp);
                b = 2 * b;
            end
            if all(idx <= M) && O(idx(n)) + k <= len
                T = O(idx);
                st = [1, T(1:end-1) + 1 + k];
                low = zeros(1, n);
                for j = 1:k
                    low = 2 * low + seg(T + j);
                end
                u = (T - st) * 2^k + low;
                br.p = p0 + T(n) + k;
                return;
            end
        end
    end
    if full
        overrun(br);
    end
    win = 4 * win;
end
end
