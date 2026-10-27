function [t, ok] = hl_time(t, fs)
%HL_TIME Convert a time argument of the high-level API.
%   T = wfdbx.internal.hl_time(T) returns a sample number: T itself if it
%   is a number, or wfdbx.strtim(T) (made non-negative) for a time string;
%   [] stays [].
%
%   [T, OK] = wfdbx.internal.hl_time(T, FS), where FS is the sampling
%   frequency in use (wfdbx.getifreq()), returns OK = false (and T = [])
%   without calling strtim if FS <= 0 and T is a time string that needs a
%   sampling frequency (wfdbx.wfdbx_time_needs_freq); the caller then
%   reports the error.  wfdb-x: there is no default sampling frequency
%   (see docs/DIVERGENCES.md); in legacy mode (wfdbx.wfdbx_get_legacy),
%   strtim is always called, as before.
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

ok = true;
if ischar(t)
    if nargin > 1 && fs <= 0 && ~wfdbx.wfdbx_get_legacy() && ...
            wfdbx.wfdbx_time_needs_freq(t)
        ok = false;
        t = [];
        return;
    end
    t = wfdbx.strtim(t);
    if t < 0
        t = -t;
    end
elseif ~isempty(t)
    t = fix(double(t));
end
end
