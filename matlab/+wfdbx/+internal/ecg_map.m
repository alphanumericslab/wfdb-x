function m = ecg_map()
%ECG_MAP The annotation mapping tables (a wfdbx.internal.EcgMap object).
%   M = wfdbx.internal.ecg_map() returns the handle object holding the
%   tables used by wfdbx.isqrs, wfdbx.map1, wfdbx.map2 and wfdbx.annpos.
%   For speed in loops, read the table once, e.g. q = m.qrs; then
%   q(code + 1) for valid codes (1 to 49).
%
%   Part of the translation of lib/ecgmap.h (WFDB 10.7.0).

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

persistent s
if isempty(s)
    s = wfdbx.internal.EcgMap();
end
m = s;
end
