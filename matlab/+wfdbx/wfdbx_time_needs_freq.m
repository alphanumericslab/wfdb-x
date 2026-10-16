function r = wfdbx_time_needs_freq(string)
%WFDBX_TIME_NEEDS_FREQ True if strtim needs a sampling frequency for a string.
%   R = wfdbx.wfdbx_time_needs_freq(STRING) returns 0 if STRING (after any
%   leading spaces, tabs, newlines and carriage returns) begins with 'e',
%   'i', 'o' or 's' (times that wfdbx.strtim converts without a sampling
%   frequency), or with 'c' while the counter frequency is not specified;
%   it returns 1 otherwise.  This function is a wfdb-x addition (wfdb-x
%   never assumes a sampling frequency; see docs/DIVERGENCES.md).
%
%   Example:
%       wfdbx.wfdbx_time_needs_freq('s100')     % 0
%       wfdbx.wfdbx_time_needs_freq('0:10')     % 1
%
%   See also wfdbx.strtim, wfdbx.sampfreq, wfdbx.getcfreq.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

string = wfdbx.internal.strarg(string);
k = 1;
n = numel(string);
while k <= n && any(string(k) == [' ', char(9), char(10), char(13)])
    k = k + 1;
end
if k > n
    r = 1;
    return;
end
switch string(k)
    case {'e', 'i', 'o', 's'}
        r = 0;
    case 'c'
        S = wfdbx.internal.sigstate();
        r = double(S.cfreq > 0);
    otherwise
        r = 1;
end
end
