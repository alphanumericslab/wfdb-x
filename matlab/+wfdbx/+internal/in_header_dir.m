function tf = in_header_dir(name)
%IN_HEADER_DIR True if a name in a header stays in the header's directory.
%   TF = wfdbx.internal.in_header_dir(NAME) (WFDB-x) is true for a
%   relative name that does not begin with '~' and has no '..' component
%   (on MS-Windows, no drive letter either): the containment rule for the
%   files named in a header (see wfdbx.internal.open_in).
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

tf = false;
if wfdbx.internal.is_absolute_path(name) || wfdbx.internal.is_url(name) || ...
        (~isempty(name) && name(1) == '~')
    return;
end
if ispc()
    if numel(name) >= 2 && name(2) == ':'
        return;
    end
    name(name == '\') = '/';
end
tf = ~any(strcmp(regexp(name, '/', 'split'), '..'));
end
