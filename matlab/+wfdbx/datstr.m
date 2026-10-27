function s = datstr(date)
%DATSTR Convert a Julian date to a string.
%   S = wfdbx.datstr(DATE) returns " dd/mm/yyyy" (with a leading space).
%
%   See also wfdbx.strdat.
%
%   Translation of the C function datstr() (lib/signal.c, WFDB 10.7.0): same
%   arguments and results.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

ymd = wfdbx.internal.datymd(date);
s = sprintf(' %02d/%02d/%d', ymd(3), ymd(2), ymd(1));
S = wfdbx.internal.sig_state();
S.date_string = s;
S.pdays = -1;
end
