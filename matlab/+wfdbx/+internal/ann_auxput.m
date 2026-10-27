function [buf, index, auxpos] = ann_auxput(buf, index, P, m)
%ANN_AUXPUT Store the aux string of an AUX word in the aux ring buffer.
%   [BUF, INDEX, AUXPOS] = wfdbx.internal.ann_auxput(BUF, INDEX, P, M)
%   does what getann does for the M-th AUX word of the decoded MIT file P
%   (wfdbx.internal.ann_parse): it stores the length byte and the data
%   read (with a null after the data) in the ring buffer BUF (AUXBUFLEN = 771 bytes)
%   (positions 0-based; the buffer wraps when the string would not fit).
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

ln = P.tokln(m);
if index >= numel(buf) - 2 - ln  % AUXBUFLEN - 2 - ln
    index = 0;
end
auxpos = index;
buf(index+1) = ln;
index = index + 1;
av = P.tokav(m);
if av > 0
    o = P.tokoff(m);
    buf(index+1:index+av) = double(P.D(o+1:o+av));
end
buf(index+ln+1) = 0;
index = index + ln + 1;
end
