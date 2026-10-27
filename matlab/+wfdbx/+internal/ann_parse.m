function P = ann_parse(D, aha)
%ANN_PARSE Decode a complete annotation file (one pass of getann).
%   P = wfdbx.internal.ann_parse(D, AHA) decodes the bytes D (a uint8 row:
%   the whole annotation file) as getann reads them in one pass from the
%   start of the file, in MIT format (AHA false) or AHA format (AHA true).
%   The result describes the annotations in file order, as the successive
%   values of the "current annotation" (ia->ann) of the C library:
%
%     N          number of annotations read
%     tt         their times in the file's time units (ann_tt, before
%                scaling by tmul)
%     typ, sub, chan, num   anntyp, subtyp, chan and num (chan and num
%                carry over from one annotation to the next, as in C)
%     eofend     true if the file ends inside annotation N (no end of file
%                marker): reading annotation N then sets ateof = -1, and
%                getann reports "unexpected EOF" instead of returning it;
%                false if the file ends normally after annotation N
%     tokfirst, tokcnt   (MIT) the aux fields of each annotation: indices
%                into tokln (aux length byte), tokoff (0-based offset of
%                the data in D) and tokav (number of bytes of data
%                available: (ln+1)&~1, fewer at the end of the file)
%     auxoff, auxav, badseq   (AHA) offset and number of available bytes
%                of the 6 aux bytes; true if the annotation number is <= 0
%     D          the file bytes
%
%   The aux ring buffer of the C library is not simulated here (see
%   wfdbx.internal.ann_next and wfdbx.internal.getann_bulk), since its
%   contents carry over from one pass to the next.  The words read beyond
%   the end of the file are emulated as in wfdbx.internal.WFDBFile (missing
%   bytes read as 255).
%
%   Part of the translation of lib/annot.c (WFDB 10.7.0).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/annot.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/annot.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

D = reshape(D, 1, []);
L = numel(D);
P.D = D;
P.aha = aha;
if aha
    P = parse_aha(P, D, L);
else
    P = parse_mit(P, D, L);
end
end

function P = parse_aha(P, D, L)
% AHA format: 16-byte records (see wfdbx.putann); a record whose first
% byte is EOAF ends the file.
EOAF = 255;
RECLEN = 16;
AUXLEN = 6;
Dp = [double(D), EOAF * ones(1, RECLEN + 2)];
R = floor(L / RECLEN) + 1;
b = RECLEN * (0:R-1);                   % 0-based offset of each record
lb = Dp(b + 1);                         % low byte of the record's word
stop = find(lb == EOAF | RECLEN * (1:R) + 2 > L, 1);
% stop always exists: for r = R, 16R + 2 > L.
if lb(stop) == EOAF
    N = stop - 1;
    P.eofend = false;
else
    N = stop;
    P.eofend = true;
end
b = b(1:N);
hi = Dp(b + 2);
typ = wfdbx.ammap(hi);
x = Dp(b + 3) + 256 * Dp(b + 4);
x = x - 65536 * (x >= 32768);
y = Dp(b + 5) + 256 * Dp(b + 6);
P.tt = x * 65536 + y;
q = Dp(b + 7) + 256 * Dp(b + 8);
q = q - 65536 * (q >= 32768);
P.badseq = q <= 0;
sub = Dp(b + 9);
sub = sub - 256 * (sub >= 128);
sub(hi == 'U' & sub == 0) = -1;
P.N = N;
P.typ = typ;
P.sub = sub;
P.chan = Dp(b + 10);
P.num = zeros(1, N);
P.auxoff = b + 10;
P.auxav = max(0, min(AUXLEN, L - (b + 10)));
end

function P = parse_mit(P, D, L)
% MIT format: see wfdbx.putann.  Codes above ACMAX are pseudo-annotations.
CODE1 = 1024;           % 1 << CS: code 1 in the code field
SKIP = 59;
NUM = 60;
SUB = 61;
CHN = 62;
AUX = 63;
EOFW = 65535;           % a word read entirely beyond the end of the file
nW = floor(L / 2);
Wd = double(D(1:2:2*nW)) + 256 * double(D(2:2:2*nW));
if mod(L, 2)
    weof = 255 * 256 + double(D(L));
else
    weof = EOFW;
end
Wx = [Wd, weof, EOFW, EOFW, EOFW];      % words as read by g16 (unsigned)
code = floor(Wd / CODE1);
% The skip words at the start of the file (read by annopen/iannsettime).
i = 1;
tt0 = 0;
while true
    w = wat(Wx, nW, i);
    if floor(w / CODE1) ~= SKIP
        break;
    end
    tt0 = tt0 + g32(Wx, nW, i + 1);
    i = i + 3;
end
s0 = i;
P.eofend = false;
if s0 > nW
    % The first annotation word is read at the end of the file.
    w = wat(Wx, nW, s0);
    P.N = 1;
    P.tt = tt0 + mod(w, CODE1);
    P.typ = floor(w / CODE1);
    P.sub = 0;
    P.chan = 0;
    P.num = 0;
    P.tokfirst = 1;
    P.tokcnt = 0;
    P.tokln = zeros(1, 0);
    P.tokoff = zeros(1, 0);
    P.tokav = zeros(1, 0);
    P.eofend = true;
    return;
end
if Wd(s0) == 0
    P = empty_mit(P);
    return;
end
% Follow the chain of words actually read: words other than SKIP (which
% has a 2-word operand) and AUX (followed by its data) are single words,
% so the walk only stops at those, and at a zero word (end of file).
spec = find(code == SKIP | code == AUX);
zer = find(Wd == 0);
ns = numel(spec);
nz = numel(zer);
rs = zeros(1, 64);
re = zeros(1, 64);
nr = 0;
pos = s0 + 1;
js = 1;
jz = 1;
eofhit = false;
while true
    if pos > nW
        eofhit = true;
        break;
    end
    while js <= ns && spec(js) < pos
        js = js + 1;
    end
    while jz <= nz && zer(jz) < pos
        jz = jz + 1;
    end
    if js <= ns
        q = spec(js);
    else
        q = inf;
    end
    if jz <= nz
        z = zer(jz);
    else
        z = inf;
    end
    nr = nr + 1;
    if nr > numel(rs)
        rs(2 * nr) = 0;
        re(2 * nr) = 0;
    end
    if z < q
        rs(nr) = pos;
        re(nr) = z - 1;
        break;
    end
    if isinf(q)
        rs(nr) = pos;
        re(nr) = nW;
        eofhit = true;
        break;
    end
    rs(nr) = pos;
    re(nr) = q;
    if code(q) == SKIP
        pos = q + 3;
    else
        pos = q + 1 + ceil(mod(Wd(q), 256) / 2);
    end
end
rs = rs(1:nr);
re = re(1:nr);
k = re >= rs;
rs = rs(k);
re = re(k);
% Chain positions: s0, then the ranges.
len = re - rs + 1;
T = sum(len);
C = ones(1, T + 1);
C(1) = s0;
if T > 0
    st = cumsum([2, len(1:end-1)]);     % index in C of each range start
    C(st) = rs;
    C(st(2:end)) = rs(2:end) - re(1:end-1);
    C(2:end) = cumsum(C(2:end));
end
w = Wd(C);
cd = floor(w / CODE1);
isstart = cd < SKIP;
isstart(1) = true;
aid = cumsum(isstart);
N = aid(end);
contrib = zeros(1, T + 1);
contrib(isstart) = mod(w(isstart), CODE1);
ks = find(cd == SKIP & ~isstart);
if ~isempty(ks)
    x = Wx(min(C(ks) + 1, nW + 4));
    x(C(ks) + 1 > nW + 1) = EOFW;
    y = Wx(min(C(ks) + 2, nW + 4));
    y(C(ks) + 2 > nW + 1) = EOFW;
    x = x - 65536 * (x >= 32768);
    contrib(ks) = x * 65536 + y;
end
ttall = cumsum([tt0, contrib]);
ttall = ttall(2:end);
P.N = N;
P.tt = ttall(isstart);
P.typ = cd(isstart);
sub = zeros(1, N);
kk = find(cd == SUB & ~isstart);
if ~isempty(kk)
    v = mod(w(kk), CODE1);
    v = mod(v + 128, 256) - 128;
    sub(aid(kk)) = v;
end
P.sub = sub;
P.chan = carry(N, aid, w, cd == CHN & ~isstart, 0);
P.num = carry(N, aid, w, cd == NUM & ~isstart, 1);
ka = find(cd == AUX & ~isstart);
P.tokln = mod(w(ka), 256);
P.tokoff = 2 * C(ka);
P.tokav = max(0, min(2 * ceil(P.tokln / 2), L - P.tokoff));
P.tokcnt = accumarray(aid(ka)', 1, [N, 1])';
P.tokfirst = cumsum([1, P.tokcnt(1:end-1)]);
P.eofend = eofhit;
end

function v = carry(N, aid, w, sel, signed)
% Values of chan (or num) for each annotation: the last CHN (NUM) word
% read so far in the pass (0 at the start).
k = find(sel);
if isempty(k)
    v = zeros(1, N);
    return;
end
x = mod(w(k), 1024);                    % the data field
if signed
    x = mod(x + 128, 256) - 128;
else
    x = mod(x, 256);
end
cv = nan(1, N);
cv(aid(k)) = x;
f = ~isnan(cv);
vals = [0, cv(f)];
v = vals(cumsum(f) + 1);
end

function P = empty_mit(P)
P.N = 0;
P.tt = zeros(1, 0);
P.typ = zeros(1, 0);
P.sub = zeros(1, 0);
P.chan = zeros(1, 0);
P.num = zeros(1, 0);
P.tokfirst = zeros(1, 0);
P.tokcnt = zeros(1, 0);
P.tokln = zeros(1, 0);
P.tokoff = zeros(1, 0);
P.tokav = zeros(1, 0);
end

function w = wat(Wx, nW, i)
% Word i as read by g16 (0xffff beyond the end of the file).
if i <= nW + 1
    w = Wx(i);
else
    w = 65535;
end
end

function v = g32(Wx, nW, i)
% The 32-bit value (high word first, signed) at word i, as read by g32.
x = wat(Wx, nW, i);
y = wat(Wx, nW, i + 1);
if x >= 32768
    x = x - 65536;
end
v = x * 65536 + y;
end
