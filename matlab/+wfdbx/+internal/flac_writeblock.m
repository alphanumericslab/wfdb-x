function fo = flac_writeblock(og, fo, n)
%FLAC_WRITEBLOCK Encode and write the first N buffered samples of each signal.
%   FO = wfdbx.internal.flac_writeblock(OG, FO, N) encodes one FLAC frame
%   from the first N samples per signal of FO.cbuf, writes it to OG.fp
%   and updates the encoder state FO (frame number, totals, frame sizes,
%   MD5 data).
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

block = fo.cbuf(:, 1:n);
fo.cbuf = fo.cbuf(:, n+1:end);
fo.nbuf = fo.nbuf - n;
if size(fo.cbuf, 2) < 4096 + fo.spf
    fo.cbuf(fo.nsig, 4096 + fo.spf) = 0;
end
nb = floor((fo.bps + 7) / 8);
b = reshape(typecast(int32(reshape(block, 1, [])), 'uint8'), 4, []);
b = reshape(b(1:nb, :), 1, []);
m = fo.md5len + numel(b);
if m > numel(fo.md5data)
    fo.md5data(max(2 * m, 65536)) = 0;
end
fo.md5data(fo.md5len+1:m) = b;
fo.md5len = m;
frame = wfdbx.internal.flac_encode_frame(block, fo.bps, fo.frame_no);
if ~isempty(og.fp)
    og.fp.write(frame);
end
fo.frame_no = fo.frame_no + 1;
fo.total = fo.total + n;
fs = numel(frame);
if isempty(fo.minfs)
    fo.minfs = fs;
else
    fo.minfs = min(fo.minfs, fs);
end
fo.maxfs = max(fo.maxfs, fs);
end
