function v = WFDB_DEFGAIN()
%WFDB_DEFGAIN Default gain (ADC units per physical unit).
%   V = wfdbx.WFDB_DEFGAIN() returns 200, the value of WFDB_DEFGAIN in
%   lib/wfdb.h.  wfdb-x keeps it for compatibility but never assumes a
%   default gain (see docs/DIVERGENCES.md).
%
%   See also wfdbx.aduphys, wfdbx.physadu.
%
%   Translation of the C constant WFDB_DEFGAIN (lib/wfdb.h, WFDB 10.7.0):
%   same value. Differences: wfdb-x does not use it as a default; see
%   docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdb.h from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language; wfdb-x keeps the
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

v = 200;
end
