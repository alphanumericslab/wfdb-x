function s = seginfo(n)
%SEGINFO A WFDB_Seginfo structure (segment of a multi-segment record).
%   S = wfdbx.seginfo() returns a structure with the fields recname (''),
%   nsamp (0, the number of samples in the segment) and samp0 (0, the
%   sample number of its first sample).  S = wfdbx.seginfo(N) returns a
%   1-by-N array of such structures.
%
%   See also wfdbx.getseginfo.
%
%   Translation of the C structure WFDB_Seginfo (lib/wfdb.h, WFDB 10.7.0):
%   same fields.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdb.h from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/wfdb.h, WFDB Software Package 10.7.0.
%   Copyright (C) 1983-2013 George B. Moody; revised 2010-2020 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    n = 1;
end
s = repmat(struct('recname', '', 'nsamp', 0, 'samp0', 0), 1, n);
end
