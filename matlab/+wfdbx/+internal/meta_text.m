function s = meta_text(s, what, id)
%META_TEXT A metadata key or value given as an argument, as bytes.
%   S = wfdbx.internal.meta_text(S, WHAT, ID) returns S as a char row
%   whose characters are bytes: S may be a char row vector (or '', or a
%   MATLAB string scalar), or a uint8 vector of bytes, taken as given.  An
%   error (identifier ID.arg, see wfdbx.internal.meta_id) is thrown if S
%   is anything else ("WHAT must be a string"), or if it has a character
%   above 255 (possible in MATLAB only: in Octave, a char array holds
%   bytes).  WHAT is 'metadata key' or 'metadata value'.
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

s = wfdbx.internal.strarg(s);
if isa(s, 'uint8') && (isvector(s) || isempty(s))
    s = char(reshape(s, 1, []));
    return;
end
if ~ischar(s) || ~(isrow(s) || isempty(s))
    error(id.arg, '%s must be a string', what);
end
s = reshape(s, 1, []);
if any(double(s) > 255)
    error(id.arg, ['%s ''%s'' has a character that is not Latin-1 (one ' ...
        'byte per character); give it as bytes (uint8)'], what, s);
end
end
