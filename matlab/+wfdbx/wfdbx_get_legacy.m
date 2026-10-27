function on = wfdbx_get_legacy()
%WFDBX_GET_LEGACY True if legacy mode is on.
%   ON = wfdbx.wfdbx_get_legacy() returns 1 if legacy mode is on (see
%   wfdbx.wfdbx_set_legacy), 0 otherwise.
%
%   See also wfdbx.wfdbx_set_legacy.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

S = wfdbx.internal.sig_state();
on = S.legacy_mode;
end
