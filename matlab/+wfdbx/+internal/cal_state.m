function st = cal_state()
%CAL_STATE The calibration list (a wfdbx.internal.CalState handle object).
%   ST = wfdbx.internal.cal_state() returns the object whose property list
%   is the calibration list (a 1-by-N struct array of wfdbx.calinfo
%   structures) used by wfdbx.calopen, wfdbx.getcal, wfdbx.putcal,
%   wfdbx.newcal and wfdbx.flushcal.
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

persistent s
if isempty(s)
    s = wfdbx.internal.CalState();
end
st = s;
end
