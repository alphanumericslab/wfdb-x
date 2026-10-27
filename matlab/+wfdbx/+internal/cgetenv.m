function v = cgetenv(name)
%CGETENV C getenv(): the value of an environment variable, or [] if unset.
%   V = wfdbx.internal.cgetenv(NAME) returns the value of the environment
%   variable NAME as a char vector, or [] (C NULL) if it is not set.
%
%   An unset variable cannot be told apart from one set to the empty
%   string in Octave (nor in MATLAB before R2022b, which added isenv); for
%   the same behavior everywhere, both are reported as unset ([]).
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

v = getenv(name);
if isempty(v)
    v = [];
end
end
