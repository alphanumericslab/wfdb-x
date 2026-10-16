function a = physadu(s, v)
%PHYSADU Convert physical units to ADC units.
%   A = wfdbx.physadu(S, V) converts V (physical units of input signal S)
%   to ADC units, rounded to an integer.  If S is not a valid signal number
%   or the signal is uncalibrated (gain 0), an error is reported and
%   WFDB_INVALID_SAMPLE is returned (wfdb-x: C assumed a gain of 200; see
%   docs/DIVERGENCES.md; in legacy mode, see wfdbx.wfdbx_set_legacy, a
%   gain of 200 and a baseline of 0 for invalid signal numbers are used,
%   as in C).
%
%   See also wfdbx.aduphys, wfdbx.muvadu.

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
g = wfdbx.internal.conversion_gain(S, 'physadu', s);
if g == 0
    a = WFDB_INVALID_SAMPLE;
    return;
end
s = mod(s, 4294967296);     % WFDB_Signal is unsigned
if s < S.nvsig
    b = S.vsd(s + 1).info.baseline;
else
    b = 0;      % wfdb-x: legacy mode (original behavior)
end
v = v * g;
if v >= 0
    a = fix(v + 0.5) + b;
else
    a = fix(v - 0.5) + b;
end
a = wfdbx.internal.cint32(a);
end
