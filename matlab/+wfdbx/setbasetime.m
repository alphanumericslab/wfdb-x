function stat = setbasetime(string)
%SETBASETIME Set the base time and date.
%   STAT = wfdbx.setbasetime(STRING) sets the base time (time of day of
%   sample 0) and date from STRING ("hh:mm:ss dd/mm/yyyy", the date being
%   optional).  An empty STRING (or []) sets the current time and date.
%   Returns 0, or -1 if STRING is not a valid time.
%
%   See also wfdbx.timstr, wfdbx.strtim.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
