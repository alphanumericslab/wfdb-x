function stat = setinfo(record)
%SETINFO Open a .info file for info strings.
%   STAT = wfdbx.setinfo(RECORD) creates (or opens for appending)
%   RECORD.info, to which wfdbx.putinfo then writes.  wfdbx.setinfo([])
%   closes it.  Returns 0, or a negative value on error.
%
%   See also wfdbx.putinfo, wfdbx.getinfo.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if isa(record, 'string')   % MATLAB string
    record = char(record);
end
S = wfdbx.internal.sig_state();
stat = wfdbx.internal.wfdb_oinfoclose();
if ~ischar(record)
    return;
end
record = wfdbx.internal.wfdb_striphea(record);
if wfdbx.internal.wfdb_checkname(record, 'record')
    stat = -1;
    return;
end
S.outinfo = wfdbx.internal.wfdb_open('info', record, 4);    % WFDB_APPEND
if isempty(S.outinfo)
    wfdbx.internal.wfdb_error('setinfo: can''t create info file for record %s\n', record);
    stat = -1;
    return;
end
stat = 0;
end
