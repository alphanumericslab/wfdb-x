function stat = newheader(record)
%NEWHEADER Create a header file for the open output signals.
%   STAT = wfdbx.newheader(RECORD) writes RECORD.hea, describing the
%   output signals opened by osigopen/osigfopen and the samples written
%   so far (number of samples, checksums, initial values), with the
%   sampling frequency set by setsampfreq and the base time set by
%   setbasetime.  Returns 0, or -1 on error.
%
%   See also wfdbx.setheader, wfdbx.osigfopen, wfdbx.putinfo.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if isa(record, 'string')   % MATLAB string
    record = char(record);
end
S = wfdbx.internal.sigstate();
record = wfdbx.internal.wfdb_striphea(record);
if S.nosig > 0
    osi = [S.osd(1:S.nosig).info];
else
    osi = wfdbx.siginfo(0);
end
stat = wfdbx.setheader(record, osi, S.nosig);
end
