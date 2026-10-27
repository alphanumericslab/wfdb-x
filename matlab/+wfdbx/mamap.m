function y = mamap(a, s)
%MAMAP Map an MIT annotation code into an AHA annotation code.
%   Y = wfdbx.mamap(A, S) returns the AHA annotation code (a character
%   code, as a double) of the MIT annotation code A with subtype S.
%   Invalid codes map to double('O').
%
%   See also wfdbx.ammap.
%
%   Translation of the C macro mamap() (lib/ecgmap.h, WFDB 10.7.0): same
%   arguments and results.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
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

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
persistent t
if isempty(t)
    t = double('ONNNNVFNNNENPQUOOOOOOOOOONOOOOQO[]NNOONOOROOOOOOOO');     % codes 0 to ACMAX
end
if a > 0 && a <= ACMAX
    y = t(a + 1);
    if y == 'U' && s ~= -1
        y = double('O');
    end
else
    y = double('O');
end
end
