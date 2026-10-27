function flushcal()
%FLUSHCAL Empty the calibration list.
%   wfdbx.flushcal() removes all entries from the calibration list.
%
%   See also wfdbx.calopen, wfdbx.putcal.
%
%   Translation of the C function flushcal() (lib/calib.c, WFDB 10.7.0):
%   same arguments and results.

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
st.list = repmat(wfdbx.calinfo(), 1, 0);
end
