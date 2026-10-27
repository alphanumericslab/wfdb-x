function f = open_in(d, s, name, record)
%OPEN_IN Open a file named in the header of a record.
%   F = wfdbx.internal.open_in(D, S, NAME, RECORD) (WFDB-x) opens, for
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
%
%   Part of the translation of lib/wfdbio.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: a file named in a header is read from the
% header's directory, and a name that leaves that directory is refused.
% docs/DIVERGENCES.md gives the reasons.
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
