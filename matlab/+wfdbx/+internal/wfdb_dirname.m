function d = wfdb_dirname(name)
%WFDB_DIRNAME The directory part of a file name or URL.
%   D = wfdbx.internal.wfdb_dirname(NAME) (wfdb-x) returns NAME up to and
%   including its last directory separator ('/', and on MS-Windows '\'),
%   or '' if it has none.
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

if ispc()
    k = find(name == '/' | name == '\', 1, 'last');
else
    k = find(name == '/', 1, 'last');
end
if isempty(k)
    d = '';
else
    d = name(1:k);
end
end
