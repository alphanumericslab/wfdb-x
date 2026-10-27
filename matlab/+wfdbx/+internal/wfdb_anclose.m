function wfdb_anclose()
%WFDB_ANCLOSE Close all annotators (called by wfdbx.wfdbquit and annopen).
%   wfdbx.internal.wfdb_anclose() closes all input annotators, then all
%   output annotators (last opened first), as wfdb_anclose in annot.c.
%
%   Translation of the C function wfdb_anclose() (lib/annot.c, WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/annot.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/annot.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

st = wfdbx.internal.ann_state();
for an = numel(st.iad):-1:1
    wfdbx.iannclose(an - 1);
end
for an = numel(st.oad):-1:1
    wfdbx.oannclose(an - 1);
end
end
