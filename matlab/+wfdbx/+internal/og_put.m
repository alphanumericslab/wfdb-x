function og_put(og, b)
%OG_PUT Append bytes to the output buffer of a signal group (w8 in signal.c).
%   wfdbx.internal.og_put(OG, B) appends the bytes B (values 0-255) to the
%   buffer of the output group OG; each time the buffer holds OG.obuflen
%   bytes, they are written to the file (or discarded if there is none).
%
%   Part of the translation of lib/signal.c (WFDB 10.7.0).

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

buf = [og.buf, uint8(b)];
L = og.obuflen;
n = numel(buf);
if L > 0
    k = n - mod(n, L);
else
    k = n;
end
if k > 0
    if ~isempty(og.fp)
        og.fp.write(buf(1:k));
    end
    buf = buf(k + 1:end);
end
og.buf = buf;
end
