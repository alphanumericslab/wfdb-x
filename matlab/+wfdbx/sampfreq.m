function f = sampfreq(record)
%SAMPFREQ Sampling frequency of a record.
%   F = wfdbx.sampfreq(RECORD) reads the header of RECORD and returns its
%   sampling frequency (in Hz); a negative value if the header cannot be
%   read, and 0 if the header does not specify it (wfdb-x: C assumed
%   250 Hz; see docs/DIVERGENCES.md).  F = wfdbx.sampfreq([]) returns the
%   sampling frequency of the currently open record (as modified by
%   setgvmode/setsampfreq).
%
%   See also wfdbx.setsampfreq, wfdbx.getifreq.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if nargin >= 1 && isa(record, 'string')   % MATLAB string
    record = char(record);
end
if nargin < 1
    record = [];
end
S = wfdbx.internal.sigstate();
record = wfdbx.internal.wfdb_striphea(record);
if ischar(record)
    wfdbx.internal.wfdb_setirec(record);
    wfdbx.setsampfreq(0);
    n = wfdbx.internal.readheader(record);
    if n < 0
        f = n;
        return;
    end
end
f = S.sfreq;
end
