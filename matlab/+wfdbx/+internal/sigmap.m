function out = sigmap(ivec)
%SIGMAP Map a frame of a variable-layout segment to the record layout.
%   OUT = wfdbx.internal.sigmap(IVEC) returns the tspf samples of the
%   record's layout computed from the frame IVEC of the current segment
%   (sigmap in signal.c), rescaling them with the rounding rule of C.
%
%   Translation of the C function sigmap() (lib/signal.c, WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
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

WFDB_INVALID_SAMPLE = -32768;
WFDB_SAMPLE_MIN = -2147483648;  % INT_MIN
WFDB_SAMPLE_MAX = 2147483647;   % INT_MAX

S = wfdbx.internal.sig_state();
smi = S.smi;
tspf = S.tspf;
idx = [smi(1:tspf).index] + 1;
scale = [smi(1:tspf).scale];
offset = [smi(1:tspf).offset];
so = [smi(1:tspf).sample_offset];
x = ivec(idx);
v = x .* scale + offset;
out = zeros(1, tspf);
for i = 1:tspf
    if x(i) == WFDB_INVALID_SAMPLE
        out(i) = WFDB_INVALID_SAMPLE;
    elseif so(i) ~= 0
        r = fix(v(i)) + so(i);
        out(i) = r - 4294967296 * floor((r + 2147483648) / 4294967296);   % (int)
    elseif v(i) >= 0
        if v(i) <= WFDB_SAMPLE_MAX
            out(i) = fix(v(i));
        else
            out(i) = WFDB_SAMPLE_MAX;
        end
    elseif v(i) >= WFDB_SAMPLE_MIN
        out(i) = floor(v(i));
    else
        out(i) = WFDB_SAMPLE_MIN;
    end
end
end
