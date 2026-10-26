function f = open_in(d, s, name, record)
%OPEN_IN Open a file named in the header of a record.
%   F = wfdbx.internal.open_in(D, S, NAME, RECORD) (wfdb-x) opens, for
%   reading, the file NAME (of type S: a signal file, S = [], or the
%   header of a segment, S = 'hea') named in the header of RECORD, in the
%   directory D of that header (as returned by wfdbx.internal.wfdb_dirname;
%   [] if unknown, for a header read from the standard input: NAME is then
%   resolved as any relative name).  NAME must be in that directory or
%   below it: a name that is absolute, begins with '~', is a URL or has a
%   '..' component is refused with an error message ("init: file NAME
%   named in the header of record RECORD is not in the header's
%   directory").  The signal file name '-' (the standard input) is
%   accepted.  Returns a WFDBFile, or [].

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if strcmp(name, '-')
    f = wfdbx.internal.wfdb_open(s, name, 0);       % WFDB_READ
    return;
end
if ~wfdbx.internal.in_header_dir(name)
    wfdbx.internal.wfdb_error(['init: file %s named in the header of ' ...
        'record %s is not in the header''s directory\n'], name, record);
    f = [];
    return;
end
if ~ischar(d)
    f = wfdbx.internal.wfdb_open(s, name, 0);       % WFDB_READ
else
    f = wfdbx.internal.open_at([d name], s);
end
end
