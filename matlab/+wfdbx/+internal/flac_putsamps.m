function stat = flac_putsamps(v, fmt, og)
%FLAC_PUTSAMPS Append many samples to a FLAC output group.
%   STAT = wfdbx.internal.flac_putsamps(V, FMT, OG) has exactly the effect
%   of calling wfdbx.internal.flac_putsamp(V(k), FMT, OG) for each element
%   of V in turn (the samples in WFDB frame order).  Returns 0.
%
%   Part of the translation of the FLAC support of lib/signal.c (WFDB
%   10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
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
v = reshape(v, 1, []);
switch fmt
    case 508
        v = mod(v + 128, 256) - 128;
    case 516
        v = mod(v + 32768, 65536) - 32768;
    case 524
        v = mod(v + 8388608, 16777216) - 8388608;
end
spf = fo.spf;
fl = numel(fo.pend);
s = [fo.pend(1:fo.np), v];
nfr = floor(numel(s) / fl);
if nfr > 0
    X = reshape(s(1:nfr*fl), spf, fo.nsig, nfr);
    X = reshape(permute(X, [2 1 3]), fo.nsig, spf * nfr);
    fo.cbuf = [fo.cbuf(:, 1:fo.nbuf), X];
    fo.nbuf = fo.nbuf + spf * nfr;
    while fo.nbuf >= 4096
        fo = wfdbx.internal.flac_writeblock(og, fo, 4096);
    end
    r = s(nfr*fl+1:end);
else
    r = s;
end
fo.np = numel(r);
fo.pend(1:fo.np) = r;
og.flac = fo;
stat = 0;
end
