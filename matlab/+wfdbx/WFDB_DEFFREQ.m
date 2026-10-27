function v = WFDB_DEFFREQ()
%WFDB_DEFFREQ Default sampling frequency (Hz).
%   V = wfdbx.WFDB_DEFFREQ() returns 250, the value of WFDB_DEFFREQ in
%   lib/wfdb.h.  WFDB-x keeps it for compatibility but never assumes a
%   default sampling frequency (see docs/DIVERGENCES.md).
%
%   See also wfdbx.sampfreq, wfdbx.setsampfreq.
%
%   Translation of the C constant WFDB_DEFFREQ (lib/wfdb.h, WFDB 10.7.0):
%   same value. Differences: WFDB-x does not use it as a default; see
%   docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdb.h from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language; WFDB-x keeps the
% value but does not use it as a default (see docs/DIVERGENCES.md).
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

v = 250;
end
