function [key, value, ok] = meta_entry(content)
%META_ENTRY The key and value of an info string.
%   [KEY, VALUE, OK] = wfdbx.internal.meta_entry(CONTENT), where CONTENT is
%   an info string as it appears in a header (a char row of bytes
%   beginning with '#', without its line ending): OK is true if it is a
%   "Key: value" entry, that is, if the text after the '#' contains a
%   colon, and the key (the text before the first colon) is not empty and
%   does not contain '#' once the spaces, tabs, VT, FF and CR at both ends
%   are removed; KEY and VALUE (the text after the colon, trimmed in the
%   same way) are then the entry.  Otherwise the info string is a free
%   comment (OK false; KEY and VALUE are '').
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

key = '';
value = '';
ok = false;
text = content(2:end);
i = find(text == ':', 1);
if isempty(i)
    return;
end
k = wfdbx.internal.meta_trim(text(1:i-1));
if isempty(k) || any(k == '#')
    return;
end
key = k;
value = wfdbx.internal.meta_trim(text(i+1:end));
ok = true;
end
