function k = meta_key(key, id)
%META_KEY Check a metadata key given as an argument.
%   K = wfdbx.internal.meta_key(KEY, ID) returns KEY as bytes (see
%   wfdbx.internal.meta_text) without the spaces, tabs, VT, FF and CR at
%   both ends.  An error (identifier ID.arg) is thrown if KEY is not a
%   string, or if K is empty ("metadata key must not be empty") or
%   contains ':', '#', a line break (CR or LF) or a NUL character
%   ("metadata key 'KEY' must not contain ...").
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

key = wfdbx.internal.meta_text(key, 'metadata key', id);
k = wfdbx.internal.meta_trim(key);
if isempty(k)
    error(id.arg, 'metadata key must not be empty');
end
% (in the order of the other implementations, for the same message)
if any(k == ':')
    error(id.arg, 'metadata key ''%s'' must not contain '':''', key);
elseif any(k == '#')
    error(id.arg, 'metadata key ''%s'' must not contain ''#''', key);
elseif any(k == char(13) | k == char(10))
    error(id.arg, 'metadata key ''%s'' must not contain a line break', key);
elseif any(k == char(0))
    error(id.arg, 'metadata key ''%s'' must not contain a NUL character', key);
end
end
