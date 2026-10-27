function c = calinfo()
%CALINFO A WFDB_Calinfo structure (calibration information).
%   C = wfdbx.calinfo() returns a structure with the fields of the C
%   WFDB_Calinfo structure, with their initial values:
%
%     low      0    low level of the calibration pulse (physical units)
%     high     0    high level of the calibration pulse
%     scale    0    customary plotting scale (physical units per cm)
%     sigtype  []   signal type (NULL)
%     units    []   physical units (NULL)
%     caltype  0    calibration pulse type: 0 (AC coupled) or 1 (DC
%                   coupled), plus 2 (square), 4 (sine), 6 (sawtooth)
%                   or 8 (undefined shape); these are WFDB_AC_COUPLED,
%                   WFDB_DC_COUPLED, WFDB_CAL_SQUARE, ... of lib/wfdb.h
%
%   See also wfdbx.getcal, wfdbx.putcal.
%
%   Translation of the C structure WFDB_Calinfo (lib/wfdb.h, WFDB 10.7.0):
%   same fields.

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

c = struct('low', 0, 'high', 0, 'scale', 0, 'sigtype', [], 'units', [], ...
    'caltype', 0);
end
