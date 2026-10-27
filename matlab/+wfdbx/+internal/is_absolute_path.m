function tf = is_absolute_path(s)
%IS_ABSOLUTE_PATH True if a name is an absolute local path.
%   TF = wfdbx.internal.is_absolute_path(S) (wfdb-x): on POSIX systems, S
%   begins with '/'; on MS-Windows, also with 'X:\', 'X:/' or '\'.
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

tf = ~isempty(s) && s(1) == '/';
if ~tf && ispc() && numel(s) >= 2
    tf = (numel(s) >= 3 && s(2) == ':' && (s(3) == '\' || s(3) == '/') && ...
        ((s(1) >= 'A' && s(1) <= 'Z') || (s(1) >= 'a' && s(1) <= 'z'))) || ...
        (s(1) == '\' && s(2) == '\');
end
end
