function name = wfdbfile(s, record)
%WFDBFILE The pathname of a WFDB file.
%   NAME = wfdbx.wfdbfile(S, RECORD) returns the pathname (or URL) of the
%   file of type S (e.g. 'hea', 'dat', 'atr') of the record RECORD, or []
%   if it does not exist.  wfdb-x: the file is looked up as by wfdb_open,
%   at one location: under the input directory for a relative name (see
%   wfdbx.wfdbx_set_input_dir); in legacy mode, in the WFDB path.  If
%   RECORD is [] (or empty), S is taken as a file name.  A trailing '.hea'
%   is removed from RECORD.
%
%   NAME = wfdbx.wfdbfile([], []) returns the name of the last file opened
%   (or tried) by the library.
%
%   Example:
%       wfdbx.wfdbfile('hea', '100s')      % '100s.hea' (no input directory)
%
%   See also wfdbx.wfdbx_set_input_dir, wfdbx.getwfdb, wfdbx.setwfdb.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
