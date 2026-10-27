function e = flac_block_end(fi, n)
%FLAC_BLOCK_END End of the FLAC block that contains a sample.
%   E = wfdbx.internal.flac_block_end(FI, N) is the end of the FLAC block
%   (frame) that contains sample N - 1 (N > 0) of the input FI: the number
%   of samples (per channel) that the C library has decoded once sample
%   N - 1 is.
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

k = find(fi.block_ends >= n, 1);
if isempty(k)
    e = fi.total;
else
    e = fi.block_ends(k);
end
end
