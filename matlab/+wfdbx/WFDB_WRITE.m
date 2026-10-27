function v = WFDB_WRITE()
%WFDB_WRITE File mode: write an output file or annotator (1).
%   V = wfdbx.WFDB_WRITE() returns 1.  Used as the stat field of a
%   wfdbx.anninfo structure, to open an annotator with wfdbx.annopen.
%
%   See also wfdbx.WFDB_READ, wfdbx.anninfo, wfdbx.annopen.
%
%   Translation of the C constant WFDB_WRITE (lib/wfdb.h, WFDB 10.7.0): same
%   value.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
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

v = 1;
end
