function t = strtim(string)
%STRTIM Convert a time string to a time in sample intervals.
%   T = wfdbx.strtim(STRING) converts an elapsed time "hh:mm:ss.sss" (or
%   "mm:ss", "ss"), an absolute time "[hh:mm:ss.sss dd/mm/yyyy]" (returned
%   as a negative number: minus the elapsed time from the base time), or
%   "sN" (N sample intervals), "cN" (counter value), "fN" (frame number),
%   "e" (end of the record), "i" (current input time), "o" (current
%   output time).
%
%   If no sampling frequency is specified and STRING needs one (see
%   wfdbx.wfdbx_time_needs_freq), an error is reported and 0 is returned
%   (wfdb-x: C used 1 sample per second, as legacy mode does; see
%   docs/DIVERGENCES.md and wfdbx.wfdbx_set_legacy).
%
%   See also wfdbx.timstr, wfdbx.mstimstr, wfdbx.wfdbx_time_needs_freq.

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
if S.ifreq > 0
    f = S.ifreq;
elseif S.sfreq > 0
    f = S.sfreq;
elseif ~S.legacy_mode && wfdbx.wfdbx_time_needs_freq(string)
    % wfdb-x: no default sampling frequency (C used 1 sample per second)
    wfdbx.internal.wfdb_error('strtim: sampling frequency is not specified\n');
    t = 0;
    return;
else
    f = 1;      % wfdb-x: legacy mode (original behavior); otherwise not used
end
t = wfdbx.internal.fstrtim(string, f);
end
