function y = ammap(a)
%AMMAP Map an AHA annotation code into an MIT annotation code.
%   Y = wfdbx.ammap(A) returns the MIT code corresponding to the AHA
%   annotation code A (a character code, e.g. double('N')), or NOTQRS.
%   A may be an array.
%
%   See also wfdbx.mamap.
%
%   Translation of the C macro ammap() (lib/ecgmap.h, WFDB 10.7.0): same
%   arguments and results.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/ecgmap.h from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/ecgmap.h, WFDB Software Package 10.7.0.
%   Copyright (C) 1999 George B. Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

persistent t
if isempty(t)
    % MIT codes of the AHA codes 'E' to ']' (NOTQRS = 0 for invalid codes)
    t = [ ...
            10 6 0 0 0 0 0 0 0 1 ...
            22 12 13 41 0 0 14 5 0 0 ...
            0 0 32 0 33];
end
y = zeros(size(a));
k = a >= 'E' & a <= ']';
y(k) = t(a(k) - ('E' - 1));
end
