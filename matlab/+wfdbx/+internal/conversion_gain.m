function g = conversion_gain(S, fn, s)
%CONVERSION_GAIN Gain of an input signal for the unit conversion functions.
%   G = wfdbx.internal.conversion_gain(S, FN, SIG) returns the gain of
%   input signal SIG (S is the signal state).  If SIG is not a valid signal
%   number, it reports "FN: invalid signal number SIG" and returns 0; if
%   the signal is uncalibrated (gain 0), it reports "FN: signal SIG is
%   uncalibrated" and returns 0.  wfdb-x: the C library assumed
%   WFDB_DEFGAIN (200 adu per physical unit) in both cases, as legacy mode
%   (wfdbx.wfdbx_set_legacy) does, without an error; see
%   docs/DIVERGENCES.md.
%
%   See also wfdbx.adumuv, wfdbx.muvadu, wfdbx.aduphys, wfdbx.physadu.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

WFDB_DEFGAIN = 200;     % lib/wfdb.h

s = mod(s, 4294967296);     % WFDB_Signal is unsigned
if S.legacy_mode    % wfdb-x: legacy mode (original behavior)
    if s < S.nvsig
        g = S.vsd(s + 1).info.gain;
    else
        g = WFDB_DEFGAIN;
    end
    if g == 0
        g = WFDB_DEFGAIN;
    end
    return;
end
if s >= S.nvsig
    wfdbx.internal.wfdb_error('%s: invalid signal number %u\n', fn, s);
    g = 0;
    return;
end
g = S.vsd(s + 1).info.gain;
if g == 0
    wfdbx.internal.wfdb_error('%s: signal %u is uncalibrated\n', fn, s);
end
end
