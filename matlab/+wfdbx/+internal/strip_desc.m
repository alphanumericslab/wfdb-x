function x = strip_desc(x)
%STRIP_DESC Remove the white space at both ends of signal descriptions.
%   SI = wfdbx.internal.strip_desc(SI) removes the white space (space, \t,
%   \n, \v, \f, \r) at both ends of the desc field of each structure of
%   the wfdbx.siginfo array SI (a [] desc is left unchanged).
%   S = wfdbx.internal.strip_desc(S) does the same for the character
%   vector S.  The high-level readers give the signal names this way (C
%   keeps the white space, as the C-style functions do).
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

if ischar(x)
    x = trim_space(x);
    return;
end
for k = 1:numel(x)
    if ischar(x(k).desc)
        x(k).desc = trim_space(x(k).desc);
    end
end
end

function s = trim_space(s)
keep = find(~wfdbx.internal.cisspace(s));
if isempty(keep)
    s = '';
else
    s = s(keep(1):keep(end));
end
end
