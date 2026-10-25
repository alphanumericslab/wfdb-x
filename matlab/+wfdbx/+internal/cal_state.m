function st = cal_state()
%CAL_STATE The calibration list (a wfdbx.internal.CalState handle object).
%   ST = wfdbx.internal.cal_state() returns the object whose property list
%   is the calibration list (a 1-by-N struct array of wfdbx.calinfo
%   structures) used by wfdbx.calopen, wfdbx.getcal, wfdbx.putcal,
%   wfdbx.newcal and wfdbx.flushcal.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

persistent s
if isempty(s)
    s = wfdbx.internal.CalState();
end
st = s;
end
