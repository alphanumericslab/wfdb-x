function tf = has_scheme(name)
%HAS_SCHEME True if a name begins with a URL scheme.
%   TF = wfdbx.internal.has_scheme(NAME) (WFDB-x) is true if NAME begins
%   with a URL scheme followed by '://': a letter, then at least one
%   letter, digit, '+', '-' or '.' (http://, https://, ftp://, sftp://,
%   file://, ...).  A drive letter (C:) is not a scheme.  In normal mode, a
%   name with a scheme is a URL, never a local file name, and only an
%   http:// or https:// URL can be read (see wfdbx.internal.wfdb_fopen).
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

tf = ischar(name) && ...
    ~isempty(regexp(name, '^[A-Za-z][A-Za-z0-9+.-]+://', 'once'));
end
