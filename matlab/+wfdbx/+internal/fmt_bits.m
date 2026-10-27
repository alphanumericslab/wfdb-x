function bits = fmt_bits(fmt)
%FMT_BITS Number of bits of a sample in a signal storage format.
%   BITS = wfdbx.internal.fmt_bits(FMT) returns the width of the samples
%   of the storage format FMT (8 for formats 80 and 508, 10 for 310 and
%   311, 12 for 212, 16 for 16, 61, 160 and 516, 24 for 24 and 524, 32
%   for 32), or 0 for formats without a fixed sample width (0, 8 and
%   unknown formats).  The lowest value of a format, -2^(BITS-1),
%   represents an invalid sample in a signal file.
%
%   Part of the translation of lib/signal.c (WFDB 10.7.0).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
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

switch fmt
    case {80, 508}
        bits = 8;
    case {310, 311}
        bits = 10;
    case 212
        bits = 12;
    case {16, 61, 160, 516}
        bits = 16;
    case {24, 524}
        bits = 24;
    case 32
        bits = 32;
    otherwise
        bits = 0;
end
end
