function v = WFDB_APPEND()
%WFDB_APPEND File mode: open an output file for appending (4).
%   V = wfdbx.WFDB_APPEND() returns 4, the value of WFDB_APPEND in
%   lib/wfdb.h.  The library uses this mode internally (e.g. wfdbx.setinfo
%   appends to an existing .info file); it is not a valid annotator mode
%   for wfdbx.annopen.
%
%   See also wfdbx.WFDB_WRITE, wfdbx.setinfo.
%
%   Translation of the C constant WFDB_APPEND (lib/wfdb.h, WFDB 10.7.0):
%   same value.

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

v = 4;
end
