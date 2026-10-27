function fi = flac_pack(fi, base)
%FLAC_PACK Arrange decoded FLAC samples in WFDB frame order.
%   FI = wfdbx.internal.flac_pack(FI, BASE) sets FI.samples to the samples
%   from sample number BASE (0-based, per signal) onward in frame order
%   (for each frame: FI.spf samples of each signal in turn), as the C
%   library reads them after a seek to that sample; FI.leftover is the
%   number of samples at the end that do not fill a frame, and FI.pos 0.
%
%   Part of the translation of the FLAC support of lib/signal.c (WFDB
%   10.7.0).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of the FLAC support of lib/signal.c (the
% code that connects FLAC to the signal functions) from the WFDB Software
% Package 10.7.0, by Benjamin Moody (2020). The translation follows the logic
% and behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c (FLAC support), WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by
%   Benjamin Moody, including FLAC support (2020).
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

spf = fi.spf;
nch = size(fi.arr, 1);
nfr = floor((fi.total - base) / spf);
fi.leftover = (fi.total - base) - nfr * spf;
X = fi.arr(:, base+1:base+nfr*spf);
Y = reshape(X', spf, nfr, nch);
Z = permute(Y, [1 3 2]);
fi.samples = reshape(Z, 1, []);
fi.pos = 0;
fi.base = base;
end
