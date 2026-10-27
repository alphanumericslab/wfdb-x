function r = wfdbx_time_needs_freq(string)
%WFDBX_TIME_NEEDS_FREQ True if strtim needs a sampling frequency for a string.
%   R = wfdbx.wfdbx_time_needs_freq(STRING) returns 0 if STRING (after any
%   leading spaces, tabs, newlines and carriage returns) begins with 'e',
%   'i', 'o' or 's' (times that wfdbx.strtim converts without a sampling
%   frequency), or with 'c' while the counter frequency is not specified;
%   it returns 1 otherwise.  This function is a WFDB-x addition (WFDB-x
%   never assumes a sampling frequency; see docs/DIVERGENCES.md).
%
%   Example:
%       wfdbx.wfdbx_time_needs_freq('s100')     % 0
%       wfdbx.wfdbx_time_needs_freq('0:10')     % 1
%
%   See also wfdbx.strtim, wfdbx.sampfreq, wfdbx.getcfreq.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package. WFDB-x never assumes a
% sampling frequency (see docs/DIVERGENCES.md).
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

string = wfdbx.internal.strarg(string);
k = 1;
n = numel(string);
while k <= n && any(string(k) == [' ', char(9), char(10), char(13)])
    k = k + 1;
end
if k > n
    r = 1;
    return;
end
switch string(k)
    case {'e', 'i', 'o', 's'}
        r = 0;
    case 'c'
        S = wfdbx.internal.sig_state();
        r = double(S.cfreq > 0);
    otherwise
        r = 1;
end
end
