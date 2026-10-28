function name = wfdbfile(s, record)
%WFDBFILE The pathname of a WFDB file.
%   NAME = wfdbx.wfdbfile(S, RECORD) returns the pathname (or URL) of the
%   file of type S (e.g. 'hea', 'dat', 'atr') of the record RECORD, or []
%   if it does not exist.  WFDB-x: the file is looked up as by wfdb_open,
%   at one location: under the input directory for a relative name (see
%   wfdbx.wfdbx_set_input_dir); in legacy mode, in the WFDB path.  If
%   RECORD is [] (or empty), S is taken as a file name.  A trailing '.hea'
%   is removed from RECORD.
%
%   NAME = wfdbx.wfdbfile([], []) returns the name of the last file opened
%   (or tried) by the library.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.wfdbfile('hea', '100s')   % '/path/to/wfdb-x/tests/data/100s.hea'
%
%   See also wfdbx.wfdbx_set_input_dir, wfdbx.getwfdb, wfdbx.setwfdb.
%
%   Translation of the C function wfdbfile() (lib/wfdbio.c, WFDB 10.7.0): same
%   arguments and results. Differences: the file is found as wfdb_open() finds
%   it, not by a search of the WFDB path; see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: the file is looked up at the one location its
% name designates, not searched for in the WFDB path. Each change is marked
% "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
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

if isa(s, 'string')   % MATLAB string
    s = char(s);
end
if isa(record, 'string')   % MATLAB string
    record = char(record);
end
st = wfdbx.internal.io_state();
if ~ischar(s) && ~ischar(record)
    name = st.wfdb_filename;
    return;
end
if ischar(record)
    record = wfdbx.internal.wfdb_striphea(record);
end
f = wfdbx.internal.wfdb_open(s, record, 0);
if ~isempty(f)
    f.close();
    name = st.wfdb_filename;
else
    name = [];
end
end
