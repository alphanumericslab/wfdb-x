function stat = flac_putsamp(v, fmt, og)
%FLAC_PUTSAMP Append a sample to a FLAC output group (flac_putsamp).
%   STAT = wfdbx.internal.flac_putsamp(V, FMT, OG) adds the sample V
%   (wrapped to 8, 16 or 24 bits for format FMT 508, 516 or 524) to the
%   output group OG.  Samples come in WFDB frame order (for each frame,
%   spf samples of each signal of the group in turn); frames of 4096
%   samples per signal are encoded and written as they fill.  Returns 0.
%
%   See also wfdbx.internal.flac_putsamps (many samples at once).
%
%   Translation of the C function flac_putsamp() (lib/signal.c, WFDB
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

fo = og.flac;
switch fmt
    case 508
        v = mod(v + 128, 256) - 128;
    case 516
        v = mod(v + 32768, 65536) - 32768;
    case 524
        v = mod(v + 8388608, 16777216) - 8388608;
end
np = fo.np + 1;
fo.pend(np) = v;
if np == numel(fo.pend)
    spf = fo.spf;
    fo.cbuf(:, fo.nbuf+1:fo.nbuf+spf) = reshape(fo.pend, spf, fo.nsig)';
    fo.nbuf = fo.nbuf + spf;
    np = 0;
    if fo.nbuf >= 4096
        fo = wfdbx.internal.flac_writeblock(og, fo, 4096);
    end
end
fo.np = np;
og.flac = fo;
stat = 0;
end
