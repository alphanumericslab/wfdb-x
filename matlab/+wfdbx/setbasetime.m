function stat = setbasetime(string)
%SETBASETIME Set the base time and date.
%   STAT = wfdbx.setbasetime(STRING) sets the base time (time of day of
%   sample 0) and date from STRING ("hh:mm:ss dd/mm/yyyy", the date being
%   optional).  An empty STRING (or []) sets the current time and date.
%   Returns 0, or -1 if STRING is not a valid time.
%
%   See also wfdbx.timstr, wfdbx.strtim.
%
%   Translation of the C function setbasetime() (lib/signal.c, WFDB 10.7.0):
%   same arguments and results.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
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

S = wfdbx.internal.sig_state();
S.pdays = -1;
stat = 0;
if ~ischar(string) || isempty(string)
    c = clock();
    S.date_string = sprintf('%02d/%02d/%d', c(3), c(2), c(1));
    S.bdate = wfdbx.strdat(S.date_string);
    S.time_string = sprintf('%d:%d:%d', c(4), c(5), fix(c(6)));
    S.btime = wfdbx.internal.fstrtim(S.time_string, 1000);
    return;
end
k = find(string ~= ' ', 1);
if isempty(k)
    string = '';
else
    string = string(k:end);
end
k = find(string == ' ', 1);
if ~isempty(k)
    tpart = string(1:k - 1);
    dpart = string(k + 1:end);
else
    tpart = string;
    dpart = [];
end
S.btime = wfdbx.internal.fstrtim(tpart, 1000);
if ischar(dpart)
    S.bdate = wfdbx.strdat(dpart);
else
    S.bdate = 0;
end
if S.btime == 0 && S.bdate == 0 && ~strncmp(tpart, '[', 1)
    wfdbx.internal.wfdb_error('setbasetime: incorrect time format, ''%s''\n', ...
        string);
    stat = -1;
end
end
