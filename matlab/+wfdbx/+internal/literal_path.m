function p = literal_path(p)
%LITERAL_PATH A file name that fopen opens as named.
%   P = wfdbx.internal.literal_path(NAME) (WFDB-x) returns NAME, or './'
%   followed by NAME if NAME begins with '~': GNU Octave's fopen, mkdir,
%   dir and isfolder expand a leading '~' (the home directory), which C's
%   fopen does not.  The tools open the files they read or create
%   themselves under the names that wfdbx.wfdbx_input_path and
%   wfdbx.wfdbx_output_path return through this function, so that a name
%   that still begins with '~' (legacy mode, or a home directory that
%   cannot be found) is a file of that name in the current directory, as
%   in C.  Other names (and [] ) are returned unchanged.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU Lesser General Public License as published by
% the Free Software Foundation, either version 2.1 of the License, or (at
% your option) any later version. See LICENSE.

if ischar(p) && ~isempty(p) && p(1) == '~'
    p = ['./' p];
end
end
