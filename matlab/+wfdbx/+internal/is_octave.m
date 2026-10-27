function tf = is_octave()
%IS_OCTAVE True when running in GNU Octave (false in MATLAB).
%   TF = wfdbx.internal.is_octave() is cached after the first call.
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

persistent v
if isempty(v)
    v = exist('OCTAVE_VERSION', 'builtin') ~= 0;
end
tf = v;
end
