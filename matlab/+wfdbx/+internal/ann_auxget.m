function a = ann_auxget(buf, pos)
%ANN_AUXGET The aux string at a position of the aux ring buffer.
%   A = wfdbx.internal.ann_auxget(BUF, POS) returns, as a uint8 row, what
%   a C program finds at annot->aux when it points to position POS
%   (0-based) of the buffer BUF (AUXBUFLEN = 771 bytes): the length byte, the data, and
%   any further bytes up to a null (the buffer may contain stale data).
%
%   Part of the translation of lib/annot.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/annot.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/annot.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

AUXBUFLEN = numel(buf);
e = pos + 1 + buf(pos+1);       % 0-based end of the data
if e >= AUXBUFLEN
    e = AUXBUFLEN;
else
    z = find(buf(e+1:AUXBUFLEN) == 0, 1);
    if isempty(z)
        e = AUXBUFLEN;
    else
        e = e + z - 1;
    end
end
a = uint8(buf(pos+1:e));
end
