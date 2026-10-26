function [nsig, si] = osigopen(record, nsig)
%OSIGOPEN Open output signals as specified by the header of a record.
%   [N, SI] = wfdbx.osigopen(RECORD, NSIG) opens the first NSIG output
%   signals described by the header of RECORD (the signal files named
%   there are created as output files: under the output directory, if
%   one is set).  Output signals open before are closed, unless RECORD
%   begins with '+'.  N is NSIG, or a negative value on error; SI
%   describes the signals opened.
%
%   wfdb-x: an output signal file is never one of the input files.  In
%   normal mode, if a signal file to be created is the same file as a
%   signal file of the open input record (one open for input, or one of
%   any segment of the open multi-segment record; the files are compared,
%   not their names: links and other spellings are recognized), it is
%   neither created nor truncated: the message "osigopen: output file NAME is
%   also an input file" is printed and -3 is returned, the input staying
%   open.  Legacy mode does not check (the original truncated the input).
%   This behavior is identical in all six implementations of wfdb-x.
%
%   See also wfdbx.osigfopen, wfdbx.putvec, wfdbx.newheader.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if isa(record, 'string')   % MATLAB string
    record = char(record);
end
S = wfdbx.internal.sig_state();
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
