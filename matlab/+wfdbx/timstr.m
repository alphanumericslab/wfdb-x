function s = timstr(t)
%TIMSTR Convert a time in sample intervals to a string.
%   S = wfdbx.timstr(T) returns T (in sample intervals) as an elapsed
%   time "hh:mm:ss" if T > 0 or if the base time is not defined, or as an
%   absolute time "[hh:mm:ss dd/mm/yyyy]" (time of day -T sample intervals
%   after the base time) otherwise.  The sampling frequency is that of
%   the open record (or the one set by setifreq/setsampfreq).  If no
%   sampling frequency is specified, an error is reported and T is returned
%   as a sample number, 'sN' with N = |T| (wfdb-x: C used 1 sample per
%   second, as legacy mode does: see docs/DIVERGENCES.md and
%   wfdbx.wfdbx_set_legacy).
%
%   See also wfdbx.mstimstr, wfdbx.strtim.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
if S.ifreq > 0
    f = S.ifreq;
elseif S.sfreq > 0
    f = S.sfreq;
elseif S.legacy_mode
    f = 1;      % wfdb-x: legacy mode (original behavior)
else
    % wfdb-x: no default sampling frequency (C used 1 sample per second)
    wfdbx.internal.wfdb_error('timstr: sampling frequency is not specified\n');
    s = sprintf('s%d', abs(t));
    return;
end
s = wfdbx.internal.ftimstr(t, f);
end
