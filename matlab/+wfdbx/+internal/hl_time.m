function [t, ok] = hl_time(t, fs)
%HL_TIME Convert a time argument of the high-level API.
%   T = wfdbx.internal.hl_time(T) returns a sample number: T itself if it
%   is a number, or wfdbx.strtim(T) (made non-negative) for a time string;
%   [] stays [].
%
%   [T, OK] = wfdbx.internal.hl_time(T, FS), where FS is the sampling
%   frequency in use (wfdbx.getifreq()), returns OK = false (and T = [])
%   without calling strtim if FS <= 0 and T is a time string that needs a
%   sampling frequency (wfdbx.wfdbx_time_needs_freq); the caller then
%   reports the error.  wfdb-x: there is no default sampling frequency
%   (see docs/DIVERGENCES.md); in legacy mode (wfdbx.wfdbx_get_legacy),
%   strtim is always called, as before.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ok = true;
if ischar(t)
    if nargin > 1 && fs <= 0 && ~wfdbx.wfdbx_get_legacy() && ...
            wfdbx.wfdbx_time_needs_freq(t)
        ok = false;
        t = [];
        return;
    end
    t = wfdbx.strtim(t);
    if t < 0
        t = -t;
    end
elseif ~isempty(t)
    t = fix(double(t));
end
end
