function tf = is_url(name)
%IS_URL True if a name is an http:// or https:// URL.
%   TF = wfdbx.internal.is_url(NAME) (wfdb-x; case-sensitive, as in the C
%   reference).
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

tf = strncmp(name, 'http://', 7) || strncmp(name, 'https://', 8);
end
