function [v, st] = ig_read(ig, fmt, n, reset)
%IG_READ Read N samples from an input signal group (r8, r16, r212, ... in signal.c).
%   [V, ST] = wfdbx.internal.ig_read(IG, FMT, N, RESET) reads N successive
%   samples of format FMT from the input group IG (a
%   wfdbx.internal.IGData), exactly as N calls of the C function for the
%   format would (including refills of the input buffer and the values
%   returned at the end of the file).  V(k) is the k-th sample and ST(k)
%   the value of IG.stat after it was read.  If RESET is true, IG.count
%   is set to 0 after each sample read with IG.stat <= 0 (as getvec does).
%   For the FLAC formats, wfdbx.internal.flac_getsamps is called.  (When
%   the samples are read from the buffer without a refill, ST is 1, as
%   IG.stat is then positive and unchanged.)

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

% The decoders combine bytes (little-endian, but for format 61) and
% sign-extend B-bit values with x - 2^B * (x >= 2^(B-1)).
v = zeros(1, n);
st = zeros(1, n);
if fmt >= 500       % FLAC formats 508, 516, 524
    [v, st] = wfdbx.internal.flac_getsamps(ig, n);
    if reset && any(st <= 0)
        ig.count = 0;
    end
    return;
end
bp = ig.bp;
be = ig.be;
packed = fmt == 212 || fmt == 310 || fmt == 311;
if packed
    count = ig.count;
    data = ig.data;
    datb = ig.datb;
else
    count = 0;
    data = 0;
    datb = 0;
end
% Fast path: the bytes needed are in the buffer (no refill, so that
% ig.stat, which is then > 0, does not change).
switch fmt
    case {8, 80}
        need = n;
    case {16, 61, 160}
        need = 2 * n;
    case 24
        need = 3 * n;
    case 32
        need = 4 * n;
    otherwise
        need = 2 * n + 2;       % an upper bound for 212, 310, 311
end
fast = bp + need <= be;
if fast
    buf = ig.buf;
    if ~packed
        b = double(buf(bp + 1:bp + need));
        ig.bp = bp + need;
        switch fmt
            case 16
                x = b(1:2:end) + 256 * b(2:2:end);
                v = x - 65536 * (x >= 32768);
            case 8
                v = b - 256 * (b > 127);
            case 61
                x = b(2:2:end) + 256 * b(1:2:end);
                v = x - 65536 * (x >= 32768);
            case 80
                v = b - 128;
            case 160
                v = b(1:2:end) + 256 * b(2:2:end) - 32768;
            case 24
                x = b(1:3:end) + 256 * b(2:3:end) + 65536 * b(3:3:end);
                v = x - 16777216 * (x >= 8388608);
            case 32
                x = b(1:4:end) + 256 * b(2:4:end) + 65536 * b(3:4:end) + ...
                    16777216 * b(4:4:end);
                v = x - 4294967296 * (x >= 2147483648);
        end
        st = ones(1, n);
        return;
    end
    stat = 1;
    nbuf = numel(buf);
else
    buf = ig.buf;
    stat = ig.stat;
    nbuf = numel(buf);
end
for k = 1:n
    % number of bytes needed by this sample
    switch fmt
        case {8, 80}
            nb = 1;
        case {16, 61, 160}
            nb = 2;
        case 24
            nb = 3;
        case 32
            nb = 4;
        case 212
            nb = 2 - count;
        case 310
            nb = 2 * (count < 2);
        case 311
            nb = 1 + (count == 0);
        otherwise
            nb = 1;
    end
    if bp + nb <= be
        b = double(buf(bp + 1:bp + nb));
        bp = bp + nb;
    else
        b = zeros(1, nb);
        for j = 1:nb
            if bp >= be
                [buf, bp, be, stat] = fill(ig, buf);
                nbuf = numel(buf);
            end
            if bp < nbuf
                b(j) = double(buf(bp + 1));
            end
            bp = bp + 1;
        end
    end
    switch fmt
        case 16
            x = b(1) + 256 * b(2);
            x = x - 65536 * (x >= 32768);
        case 212
            if count == 0
                data = b(1) + 256 * b(2);
                x = mod(data, 4096);
                count = 1;
            else
                x = bitand(floor(data / 16), 3840) + b(1);    % 0xf00
                count = 0;
            end
            x = x - 4096 * (x >= 2048);
        case 8
            x = b - 256 * (b > 127);
        case 61
            x = b(2) + 256 * b(1);
            x = x - 65536 * (x >= 32768);
        case 80
            x = b - 128;
        case 160
            x = b(1) + 256 * b(2) - 32768;
        case 24
            x = b(1) + 256 * b(2) + 65536 * b(3);
            x = x - 16777216 * (x >= 8388608);
        case 32
            x = b(1) + 256 * b(2) + 65536 * b(3) + 16777216 * b(4);
            x = x - 4294967296 * (x >= 2147483648);
        case 310
            if count == 0
                data = b(1) + 256 * b(2);
                x = mod(floor(data / 2), 1024);
                count = 1;
            elseif count == 1
                datb = b(1) + 256 * b(2);
                x = mod(floor(datb / 2), 1024);
                count = 2;
            else
                x = floor(data / 2048) + 32 * floor(datb / 2048);
                count = 0;
            end
            x = x - 1024 * (x >= 512);
        case 311
            if count == 0
                data = b(1) + 256 * b(2);
                x = mod(data, 1024);
                count = 1;
            elseif count == 1
                datb = b(1);
                x = floor(data / 1024) + 64 * mod(datb, 16);
                count = 2;
            else
                datb = datb + 256 * b(1);
                x = mod(floor(datb / 16), 1024);
                count = 0;
            end
            x = x - 1024 * (x >= 512);
        otherwise
            x = b - 256 * (b > 127);
    end
    v(k) = x;
    st(k) = stat;
    if reset && stat <= 0
        count = 0;
    end
end
ig.bp = bp;
if ~fast
    ig.buf = buf;
    ig.be = be;
    ig.stat = stat;
end
if packed
    ig.count = count;
    ig.data = data;
    ig.datb = datb;
end
end

function [buf, bp, be, stat] = fill(ig, buf)
% Refill the input buffer (as fill() in the Python port).
n = ig.bsize;
if n <= 0
    S = wfdbx.internal.sigstate();
    n = S.ibsize;
end
if isempty(ig.fp)
    b = zeros(1, 0, 'uint8');
else
    b = ig.fp.read(n);
end
stat = numel(b);
if stat > 0
    buf = b;
end
bp = 0;
be = stat;
end
