function y = isqrs(a)
%ISQRS True (1) if an annotation code denotes a QRS complex.
%   Y = wfdbx.isqrs(A) returns 1 if the annotation code A denotes a QRS
%   complex, 0 otherwise (and for invalid codes).
%
%   See also wfdbx.ecgcodes, wfdbx.setisqrs.
%
%   Translation of the C macro isqrs() (lib/ecgmap.h, WFDB 10.7.0): same
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
    y = m.qrs(a + 1);
else
    y = 0;
end
end
