function y = setisqrs(a, x)
%SETISQRS Change the isqrs table entry of an annotation code.
%   Y = wfdbx.setisqrs(A, X) sets the entry of the annotation code A (1 to
%   49) to X (stored in a C char, i.e. wrapped to -128..127) and returns
%   the new entry; for an invalid code nothing is changed and 0 is
%   returned.
%
%   See also wfdbx.isqrs.
%
%   Translation of the C macro setisqrs() (lib/ecgmap.h, WFDB 10.7.0): same
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

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if a > 0 && a <= ACMAX
    m = wfdbx.internal.ecg_map();
    m.qrs(a + 1) = mod(x + 128, 256) - 128;
    y = m.qrs(a + 1);
else
    y = 0;
end
end
