function [stat, cal] = getcal(desc, units)
%GETCAL Find calibration information for a signal type.
%   [STAT, CAL] = wfdbx.getcal(DESC, UNITS) searches the calibration list
%   (see wfdbx.calopen) for the first entry whose signal type is a prefix
%   of DESC and whose units are UNITS ([] matches anything).  STAT is 0
%   and CAL a wfdbx.calinfo structure if one is found; otherwise STAT is
%   -1 and CAL is an empty calinfo structure.
%
%   Example:
%       wfdbx.calopen('wfdbcal');
%       [stat, cal] = wfdbx.getcal('ECG lead II', 'mV');
%
%   See also wfdbx.calopen, wfdbx.putcal.
%
%   Translation of the C function getcal() (lib/calib.c, WFDB 10.7.0): same
%   arguments and results.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/calib.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/calib.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1991-2013 George B. Moody; revised 2019-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

st = wfdbx.internal.cal_state();
L = st.list;
for k = 1:numel(L)
    c = L(k);
    nt = numel(c.sigtype);
    if (~ischar(desc) || nt == 0 || strncmp(desc, c.sigtype, nt)) && ...
            (~ischar(units) || strcmp(units, c.units))
        cal = c;
        stat = 0;
        return;
    end
end
cal = wfdbx.calinfo();
stat = -1;
end
