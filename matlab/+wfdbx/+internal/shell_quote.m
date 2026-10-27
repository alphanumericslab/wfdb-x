function s = shell_quote(s)
%SHELL_QUOTE Quote a string for /bin/sh.
%   Q = wfdbx.internal.shell_quote(S) returns S enclosed in single quotes
%   (with each single quote in S written as '\''), for use in a command
%   passed to system().
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

s = ['''' strrep(s, '''', '''\''''') ''''];
end
