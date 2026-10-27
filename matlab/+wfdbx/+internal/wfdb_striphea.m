function p = wfdb_striphea(p)
%WFDB_STRIPHEA Remove a trailing '.hea' from a record name.
%   P = wfdbx.internal.wfdb_striphea(P) returns P without its last four
%   characters if it is longer than 4 characters and ends with '.hea'.
%   [] (NULL) is returned unchanged.
%
%   Translation of the C function wfdb_striphea() (lib/wfdbio.c, WFDB
%   10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/wfdbio.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if ischar(p) && numel(p) > 4 && strcmp(p(end-3:end), '.hea')
    p = p(1:end-4);
end
end
