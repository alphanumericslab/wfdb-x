function stat = putframes(m)
%PUTFRAMES Write many frames of samples at once (fast).
%   STAT = wfdbx.putframes(M) writes the rows of the matrix M to the open
%   output signals, with exactly the same results as calling
%   wfdbx.putvec(M(r, :)) for each row r in turn (each row holds a sample
%   of each output signal, or spf samples for signals with spf samples
%   per frame), but much faster, as the samples are encoded with vector
%   operations.  STAT is the smallest value that those putvec calls would
%   have returned: the number of output signals, 0 if a format 8
%   difference was out of range (and clipped), or -1 on a write error.
%
%   Example (the example writes the record rec, rec.hea and rec.dat, in the
%   current folder):
%       si = wfdbx.siginfo(2);
%       [si.fname] = deal('rec.dat'); [si.fmt] = deal(212);
%       [si.gain] = deal(200);
%       wfdbx.osigfopen(si);
%       wfdbx.setsampfreq(360);
%       wfdbx.putframes(x);          % x: n-by-2 matrix of samples
%       wfdbx.newheader('rec');
%       wfdbx.wfdbquit();
%
%   See also wfdbx.putvec, wfdbx.osigfopen, wfdbx.getframes.
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: this function is a wfdb-x addition: it writes
% many sample vectors at once, with the results of repeated putvec() calls.
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

WFDB_INVALID_SAMPLE = -32768;

S = wfdbx.internal.sig_state();
nosig = S.nosig;
stat = nosig;
nrows = size(m, 1);
if nrows == 0
    return;
end
m = double(m);
osd = S.osd;
ogd = S.ogd;
vi = 0;
s = 1;
while s <= nosig
    % the signals of one group (consecutive)
    g = osd(s).info.group;
    s2 = s;
    while s2 < nosig && osd(s2 + 1).info.group == g
        s2 = s2 + 1;
    end
    og = ogd{g + 1};
    fmt = osd(s).info.fmt;
    gs = cell(s2 - s + 1, 1);       % the samples of each signal (spf-by-n)
    for k = s:s2
        info = osd(k).info;
        spf = info.spf;
        x = m(:, vi + 1:vi + spf).';     % spf-by-nrows, time order
        if info.nsamp == 0
            info.initval = m(1, vi + 1);
            osd(k).samp = m(1, vi + 1);
        end
        vi = vi + spf;
        info.nsamp = info.nsamp + nrows;
        % WFDB_INVALID_SAMPLE is written as the lowest value of the format
        inv = x == WFDB_INVALID_SAMPLE;
        if any(inv(:))
            bits = wfdbx.internal.fmt_bits(info.fmt);
            if bits > 0
                x(inv) = -2^(bits - 1);
            end
        end
        if fmt == 8 || ~any(fmt == [0 16 61 80 160 212 310 311 24 32 508 516 524])
            % first differences, clipped to [-128, 127]
            [x, osamp, clipped] = diffs(x(:), osd(k).samp);
            x = reshape(x, spf, nrows);
            if clipped
                stat = min(stat, 0);
            end
            cks = sum(osamp);
            osd(k).samp = osamp(end);
        else
            cks = sum(x(:));
            osd(k).samp = x(end);
        end
        c = info.cksum + cks;
        info.cksum = c - 4294967296 * floor((c + 2147483648) / 4294967296);   % (int)
        osd(k).info = info;
        gs{k - s + 1} = x;
    end
    % the samples of the group in file order
    if s2 == s
        seq = gs{1}(:)';
    else
        seq = reshape(vertcat(gs{:}), 1, []);
    end
    switch fmt
        case 0
            bytes = [];
        case {508, 516, 524}
            if wfdbx.internal.flac_putsamps(seq, fmt, og) < 0
                stat = -1;
            end
            bytes = [];
        case {212, 310, 311}
            [bytes, count, data, datb] = packed(fmt, seq, og.count, og.data, ...
                og.datb);
            og.count = count;
            og.data = data;
            og.datb = datb;
        otherwise
            bytes = encode(fmt, seq);
    end
    if ~isempty(bytes)
        wfdbx.internal.og_put(og, bytes);
        if ~isempty(og.fp) && og.fp.ferror()
            for k = s:s2
                wfdbx.internal.wfdb_error('putvec: write error in signal %d\n', k - 1);
            end
            stat = -1;
        end
    end
    s = s2 + 1;
end
S.osd = osd;
S.ostime = S.ostime + nrows;
end

function [d, osamp, clipped] = diffs(x, prev)
% Format 8: the differences written and the samples they represent.  Runs
% without clipping are handled with vector operations; after a clipped
% difference, samples are processed one by one until the output catches
% up with the input.
n = numel(x);
d = zeros(n, 1);
osamp = zeros(n, 1);
clipped = false;
i = 1;
while i <= n
    % (in windows, so that the work stays proportional to n)
    e = min(n, i + 4095);
    dd = diff([prev; x(i:e)]);
    bad = find(dd < -128 | dd > 127, 1);
    if isempty(bad)
        d(i:e) = dd;
        osamp(i:e) = x(i:e);
        prev = x(e);
        i = e + 1;
        continue;
    end
    j = i + bad - 2;            % last sample before the clipped one
    if j >= i
        d(i:j) = dd(1:bad - 1);
        osamp(i:j) = x(i:j);
        prev = x(j);
    end
    i = j + 1;
    % one by one until the output equals the input again
    while i <= n
        dif = x(i) - prev;
        dif = dif - 4294967296 * floor((dif + 2147483648) / 4294967296);   % (int)
        if dif < -128
            dif = -128;
            clipped = true;
        elseif dif > 127
            dif = 127;
            clipped = true;
        end
        prev = prev + dif;
        prev = prev - 4294967296 * floor((prev + 2147483648) / 4294967296);   % (int)
        d(i) = dif;
        osamp(i) = prev;
        i = i + 1;
        if prev == x(i - 1)
            break;
        end
    end
end
d = mod(d, 256);
end

function b = encode(fmt, v)
% Bytes of the samples V (row) in a byte-aligned format (as putvec).
switch fmt
    case 8
        b = v;      % (already reduced modulo 256)
    case 16
        x = mod(v, 65536);
        b = [mod(x, 256); floor(x / 256)];
    case 61
        x = mod(v, 65536);
        b = [floor(x / 256); mod(x, 256)];
    case 80
        b = mod(mod(v, 256) + 128, 256);
    case 160
        x = mod(mod(v, 65536) + 32768, 65536);
        b = [mod(x, 256); floor(x / 256)];
    case 24
        x = mod(v, 16777216);
        b = [mod(x, 256); mod(floor(x / 256), 256); floor(x / 65536)];
    case 32
        x = mod(v, 4294967296);
        b = [mod(x, 256); mod(floor(x / 256), 256); ...
            mod(floor(x / 65536), 256); floor(x / 16777216)];
    otherwise
        b = mod(v, 256);
end
b = reshape(b, 1, []);
end

function [b, count, data, datb] = packed(fmt, v, count, data, datb)
% Bytes of the samples V in a bit-packed format, continuing from the
% state (count, data, datb) of the group, as successive putvec calls
% (bit masks as in putvec: 61440 = 0xf000, 2046 = 0x7fe, 1023 = 0x3ff).
pre = [];
i = 1;
n = numel(v);
% complete a pending group sample by sample
while count ~= 0 && i <= n
    [bb, count, data, datb] = one(fmt, v(i), count, data, datb);
    pre = [pre bb]; %#ok<AGROW>
    i = i + 1;
end
if fmt == 212
    k = 2;
else
    k = 3;
end
ng = floor((n - i + 1) / k);
w = reshape(v(i:i + ng * k - 1), k, ng);
i = i + ng * k;
switch fmt
    case 212
        a = mod(w(1, :), 4096);
        d = a + bitand(mod(w(2, :) * 16, 65536), 61440);
        mid = [mod(d, 256); floor(d / 256); mod(w(2, :), 256)];
    case 310
        d = bitand(mod(w(1, :) * 2, 65536), 2046);
        d = mod(d + w(3, :) * 2048, 65536);
        e = bitand(mod(w(2, :) * 2, 65536), 2046);
        u = mod(w(3, :) * 64, 65536);
        e = mod(e + u - bitand(u, 2046), 65536);
        mid = [mod(d, 256); floor(d / 256); mod(e, 256); floor(e / 256)];
    otherwise   % 311
        d = mod(bitand(mod(w(1, :), 65536), 1023) + w(2, :) * 1024, 65536);
        e = mod(mod(floor(w(2, :) / 64), 16) + w(3, :) * 16, 16384);
        mid = [mod(d, 256); floor(d / 256); mod(e, 256); floor(e / 256)];
end
b = [pre reshape(mid, 1, [])];
while i <= n
    [bb, count, data, datb] = one(fmt, v(i), count, data, datb);
    b = [b bb]; %#ok<AGROW>
    i = i + 1;
end
end

function [b, count, data, datb] = one(fmt, samp, count, data, datb)
% One sample of a bit-packed format (as in putvec).
b = [];
switch fmt
    case 212
        if count == 0
            data = mod(samp, 4096);
            count = 1;
        else
            count = 0;
            data = data + bitand(mod(samp * 16, 65536), 61440);
            b = [mod(data, 256), floor(data / 256), mod(samp, 256)];
        end
    case 310
        if count == 0
            data = bitand(mod(samp * 2, 65536), 2046);
            count = 1;
        elseif count == 1
            datb = bitand(mod(samp * 2, 65536), 2046);
            count = 2;
        else
            count = 0;
            data = mod(data + samp * 2048, 65536);
            u = mod(samp * 64, 65536);
            datb = mod(datb + u - bitand(u, 2046), 65536);
            b = [mod(data, 256), floor(data / 256), mod(datb, 256), floor(datb / 256)];
        end
    otherwise   % 311
        if count == 0
            data = bitand(mod(samp, 65536), 1023);
            count = 1;
        elseif count == 1
            data = mod(data + samp * 1024, 65536);
            b = [mod(data, 256), floor(data / 256)];
            datb = mod(floor(samp / 64), 16);
            count = 2;
        else
            count = 0;
            datb = mod(datb + samp * 16, 16384);
            b = [mod(datb, 256), floor(datb / 256)];
        end
end
end
