function v = adumuv(s, a)
%ADUMUV Convert ADC units to microvolts.
%   V = wfdbx.adumuv(S, A) converts A (ADC units of input signal S) to
%   microvolts, rounded to an integer.  If S is not a valid signal number
%   or the signal is uncalibrated (gain 0), an error is reported and
%   WFDB_INVALID_SAMPLE is returned (wfdb-x: C assumed a gain of 200; see
%   docs/DIVERGENCES.md; in legacy mode, see wfdbx.wfdbx_set_legacy, a
%   gain of 200 is used, as in C).
%
%   See also wfdbx.muvadu, wfdbx.aduphys.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

WFDB_INVALID_SAMPLE = -32768;   % lib/wfdb.h

S = wfdbx.internal.sigstate();
g = wfdbx.internal.conversion_gain(S, 'adumuv', s);
if g == 0
    v = WFDB_INVALID_SAMPLE;
    return;
end
x = a * 1000 / g;
if x >= 0
    v = fix(x + 0.5);
else
    v = fix(x - 0.5);
end
end
