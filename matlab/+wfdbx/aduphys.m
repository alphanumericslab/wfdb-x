function x = aduphys(s, a)
%ADUPHYS Convert ADC units to physical units.
%   X = wfdbx.aduphys(S, A) converts A (ADC units of input signal S) to
%   physical units: (A - baseline) / gain.  If S is not a valid signal
%   number or the signal is uncalibrated (gain 0), an error is reported and
%   NaN is returned (wfdb-x: C assumed a gain of 200; see
%   docs/DIVERGENCES.md; in legacy mode, see wfdbx.wfdbx_set_legacy, a
%   gain of 200 and a baseline of 0 for invalid signal numbers are used,
%   as in C).
%
%   See also wfdbx.physadu, wfdbx.adumuv.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
g = wfdbx.internal.conversion_gain(S, 'aduphys', s);
if g == 0
    x = NaN;
    return;
end
s = mod(s, 4294967296);     % WFDB_Signal is unsigned
if s < S.nvsig
    b = S.vsd(s + 1).info.baseline;
else
    b = 0;      % wfdb-x: legacy mode (original behavior)
end
x = (a - b) / g;
end

