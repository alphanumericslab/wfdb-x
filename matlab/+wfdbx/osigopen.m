function [nsig, si] = osigopen(record, nsig)
%OSIGOPEN Open output signals as specified by the header of a record.
%   [N, SI] = wfdbx.osigopen(RECORD, NSIG) opens the first NSIG output
%   signals described by the header of RECORD (the signal files named
%   there are created in the current directory).  Output signals open
%   before are closed, unless RECORD begins with '+'.  N is NSIG, or a
%   negative value on error; SI describes the signals opened.
%
%   See also wfdbx.osigfopen, wfdbx.putvec, wfdbx.newheader.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if isa(record, 'string')   % MATLAB string
    record = char(record);
end
S = wfdbx.internal.sigstate();
si = wfdbx.siginfo(0);
if ~isempty(record) && record(1) == '+'
    record = record(2:end);
else
    wfdbx.internal.osigclose();
end
record = wfdbx.internal.wfdb_striphea(record);
n = wfdbx.internal.readheader(record);
if n < 0
    nsig = n;
    return;
end
if n < nsig
    wfdbx.internal.wfdb_error( ...
        'osigopen: record %s has fewer signals than needed\n', record);
    nsig = -3;
    return;
end
if nsig <= 0
    nsig = 0;
    return;
end
hsi = [S.hsd(1:nsig).info];
[nsig, si] = wfdbx.internal.openosig('osigopen', hsi, nsig);
end
