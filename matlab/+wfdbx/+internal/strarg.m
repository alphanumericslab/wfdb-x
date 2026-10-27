function x = strarg(x)
%STRARG Convert MATLAB string arguments to char.
%   X = wfdbx.internal.strarg(X) returns char(X) if X is a string scalar
%   ("100s"), a cell row of char vectors if X is a string array, and X
%   otherwise, with the strings of a cell X converted to char vectors.
%   The high-level functions apply it to their arguments, so that they
%   accept strings as well as char vectors.  (GNU Octave has no string
%   class: X is then returned unchanged.)
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

if isa(x, 'string')
    if isscalar(x)
        x = char(x);
    else
        x = reshape(cellstr(x), 1, []);
    end
elseif iscell(x)
    for k = reshape(find(cellfun('isclass', x, 'string')), 1, [])
        x{k} = char(x{k});
    end
end
end
