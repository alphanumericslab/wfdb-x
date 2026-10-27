function c = flac_crc(data, bits)
%FLAC_CRC The CRC-8 or CRC-16 of a FLAC frame header or frame.
%   C = wfdbx.internal.flac_crc(DATA, 8) is the CRC-8 (polynomial 0x07,
%   initial value 0) of the bytes DATA (a uint8 or double vector), as in
%   FLAC frame headers; C = wfdbx.internal.flac_crc(DATA, 16) is the CRC-16
%   (polynomial 0x8005, initial value 0) that ends each FLAC frame.
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

persistent t8 t16
if isempty(t8)
    t8 = zeros(1, 256);
    t16 = zeros(1, 256);
    for i = 0:255
        x = i;
        for k = 1:8
            if x >= 128
                x = bitxor(mod(2 * x, 256), 7);
            else
                x = mod(2 * x, 256);
            end
        end
        t8(i+1) = x;
        x = i * 256;
        for k = 1:8
            if x >= 32768
                x = bitxor(mod(2 * x, 65536), 32773);
            else
                x = mod(2 * x, 65536);
            end
        end
        t16(i+1) = x;
    end
end
data = double(reshape(data, 1, []));
c = 0;
if bits == 8
    for b = reshape(data, 1, [])
        c = t8(bitxor(c, b) + 1);
    end
elseif numel(data) < 64
    % c = ((c << 8) & 0xFFFF) ^ t16[(c >> 8) ^ b], on the high and low
    % bytes of c (h, l): the new c is (l << 8) ^ t16[h ^ b]
    h = 0;
    l = 0;
    th = floor(t16 / 256);
    tl = mod(t16, 256);
    for b = reshape(data, 1, [])
        k = bitxor(h, b) + 1;
        h = bitxor(l, th(k));
        l = tl(k);
    end
    c = h * 256 + l;
else
    % The CRC (initial value 0) is linear: crc(A B) = S(crc(A)) ^ crc(B),
    % where S shifts a CRC through as many zero bytes as B has.  CRCs of
    % blocks of 1, 2, 4, ... bytes are combined pairwise, with S applied
    % by two tables (high and low byte) that are doubled at each level.
    % Leading zero bytes do not change the CRC.
    n = numel(data);
    m = 2^ceil(log2(n));
    x = t16([zeros(1, m - n), data] + 1);
    H = t16;                            % S_1(h << 8) = t16[h]
    Lo = (0:255) * 256;                 % S_1(l) = l << 8
    while numel(x) > 1
        a = x(1:2:end);
        b = x(2:2:end);
        x = bitxor(bitxor(H(floor(a / 256) + 1), Lo(mod(a, 256) + 1)), b);
        % tables of S applied twice
        H2 = bitxor(H(floor(H / 256) + 1), Lo(mod(H, 256) + 1));
        Lo = bitxor(H(floor(Lo / 256) + 1), Lo(mod(Lo, 256) + 1));
        H = H2;
    end
    c = x;
end
end
