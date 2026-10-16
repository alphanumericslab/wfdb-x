function v = WFDB_DEFFREQ()
%WFDB_DEFFREQ Default sampling frequency (Hz).
%   V = wfdbx.WFDB_DEFFREQ() returns 250, the value of WFDB_DEFFREQ in
%   lib/wfdb.h.  wfdb-x keeps it for compatibility but never assumes a
%   default sampling frequency (see docs/DIVERGENCES.md).
%
%   See also wfdbx.sampfreq, wfdbx.setsampfreq.

% Copyright (C) 1983-2013 George B. Moody (original C header, lib/wfdb.h;
% revised 2010-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

v = 250;
end
