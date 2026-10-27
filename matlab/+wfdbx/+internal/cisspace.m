function tf = cisspace(c)
%CISSPACE C isspace() in the C locale.
%   TF = wfdbx.internal.cisspace(C) is true for the characters (or codes)
%   space, \t, \n, \v, \f and \r.  C may be an array; TF has its size.
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

c = double(c);
tf = c == 32 | (c >= 9 & c <= 13);   % ' ', \t \n \v \f \r
end
