function b = flac_streaminfo(fo, total, md5)
%FLAC_STREAMINFO The STREAMINFO block of a FLAC stream being written.
%   B = wfdbx.internal.flac_streaminfo(FO, TOTAL, MD5) returns the 34 bytes
%   of STREAMINFO (as the Python implementation of wfdb-x writes it) for
%   the encoder state FO (see wfdbx.internal.flac_osinit), with TOTAL
%   samples per channel and the 16-byte signature MD5: block sizes 4096,
%   frame sizes FO.minfs (0 if none) and FO.maxfs, sample rate 96000.
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
% has no counterpart in the original package: it is wfdb-x's own implementation
% of the FLAC format, which the original package reads and writes with libFLAC.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if isempty(fo.minfs)
    minfs = 0;
else
    minfs = fo.minfs;
end
% the fields (min/max block size, min/max frame size, sample rate,
% channels - 1, bits per sample - 1, total samples) and their widths
v = [4096, 4096, minfs, fo.maxfs, 96000, fo.nsig - 1, fo.bps - 1, total];
w = [16, 16, 24, 24, 20, 3, 5, 36];
bits = zeros(1, 144);
p = 0;
for k = 1:numel(v)
    x = v(k);
    for j = w(k)-1:-1:0
        p = p + 1;
        bits(p) = mod(floor(x / 2^j), 2);
    end
end
b = uint8([[128 64 32 16 8 4 2 1] * reshape(bits, 8, 18), double(md5)]);
end
