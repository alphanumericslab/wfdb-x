function d = md5_pure(data)
%MD5_PURE The MD5 message digest (RFC 1321), in MATLAB code.
%   D = wfdbx.internal.md5_pure(DATA) returns the 16-byte MD5 digest
%   (uint8 row) of the bytes DATA (a uint8 or char vector).  The 32-bit
%   unsigned arithmetic of MD5 is emulated with doubles (exact below
%   2^53); bitwise operations use bitand/bitor/bitxor on doubles.  The
%   64 steps of each 512-bit block are sequential, so this takes about a
%   millisecond per block; wfdbx.internal.md5 uses a built-in
%   implementation when one is available.
%
%   See also wfdbx.internal.md5.
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

persistent K S
if isempty(K)
    K = floor(abs(sin(1:64)) * 2^32);
    S = [repmat([7 12 17 22], 1, 4), repmat([5 9 14 20], 1, 4), ...
        repmat([4 11 16 23], 1, 4), repmat([6 10 15 21], 1, 4)];
end
data = double(reshape(data, 1, []));
n = numel(data);
% padding: 0x80, zeros, then the length in bits (64-bit little-endian)
npad = mod(55 - n, 64);
bitlen = 8 * n;
lenb = zeros(1, 8);
for i = 1:8
    lenb(i) = mod(bitlen, 256);
    bitlen = floor(bitlen / 256);
end
msg = [data, 128, zeros(1, npad), lenb];
% 32-bit little-endian words, 16 per block
Wd = reshape(msg, 4, []);
Wd = [1 256 65536 16777216] * Wd;
nblk = numel(Wd) / 16;
Wd = reshape(Wd, 16, nblk);
M = 4294967296;
a0 = 1732584193;    % 0x67452301
b0 = 4023233417;    % 0xefcdab89
c0 = 2562383102;    % 0x98badcfe
d0 = 271733878;     % 0x10325476
% message word index of each step
g = zeros(1, 64);
for i = 0:63
    if i < 16
        g(i+1) = i;
    elseif i < 32
        g(i+1) = mod(5 * i + 1, 16);
    elseif i < 48
        g(i+1) = mod(3 * i + 5, 16);
    else
        g(i+1) = mod(7 * i, 16);
    end
end
g = g + 1;
for blk = 1:nblk
    X = Wd(:, blk);
    A = a0;
    B = b0;
    C = c0;
    D = d0;
    for i = 1:64
        if i <= 16
            F = bitor(bitand(B, C), bitand(M - 1 - B, D));
        elseif i <= 32
            F = bitor(bitand(D, B), bitand(M - 1 - D, C));
        elseif i <= 48
            F = bitxor(bitxor(B, C), D);
        else
            F = bitxor(C, bitor(B, M - 1 - D));
        end
        F = mod(F + A + K(i) + X(g(i)), M);
        A = D;
        D = C;
        C = B;
        s = S(i);
        hi = floor(F / 2^(32 - s));
        B = mod(B + mod(F * 2^s, M) + hi, M);
    end
    a0 = mod(a0 + A, M);
    b0 = mod(b0 + B, M);
    c0 = mod(c0 + C, M);
    d0 = mod(d0 + D, M);
end
w = [a0 b0 c0 d0];
d = zeros(1, 16);
for i = 1:4
    x = w(i);
    for j = 1:4
        d(4 * (i - 1) + j) = mod(x, 256);
        x = floor(x / 256);
    end
end
d = uint8(d);
end
