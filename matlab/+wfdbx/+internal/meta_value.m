function v = meta_value(key, value, id)
%META_VALUE Check a metadata value given as an argument.
%   V = wfdbx.internal.meta_value(KEY, VALUE, ID) returns VALUE as bytes
%   (see wfdbx.internal.meta_text) without the spaces, tabs, VT, FF and CR
%   at both ends; V may be empty.  KEY is the key as given (for the
%   messages).  An error (identifier ID.arg) is thrown if VALUE is not a
%   string, or if V contains a line break (CR or LF) or a NUL character
%   ("value of metadata key 'KEY' must not contain ...").
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

value = wfdbx.internal.meta_text(value, 'metadata value', id);
v = wfdbx.internal.meta_trim(value);
key = key_text(key);
if any(v == char(13) | v == char(10))
    error(id.arg, 'value of metadata key ''%s'' must not contain a line break', key);
elseif any(v == char(0))
    error(id.arg, 'value of metadata key ''%s'' must not contain a NUL character', ...
        key);
end
end

function s = key_text(key)
% (the key, already checked, as text for a message)
key = wfdbx.internal.strarg(key);
if isnumeric(key)
    s = char(reshape(key, 1, []));
else
    s = reshape(char(key), 1, []);
end
end
