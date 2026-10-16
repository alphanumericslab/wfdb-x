function stat = putcal(cal)
%PUTCAL Append an entry to the calibration list.
%   STAT = wfdbx.putcal(CAL) appends the wfdbx.calinfo structure CAL to
%   the calibration list, and returns 0.
%
%   See also wfdbx.getcal, wfdbx.newcal.

% Copyright (C) 1991-2013 George B. Moody (original C implementation,
% lib/calib.c; revised 2019-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.calstate();
c = wfdbx.calinfo();
c.low = cal.low;
c.high = cal.high;
c.scale = cal.scale;
c.sigtype = cal.sigtype;
c.units = cal.units;
c.caltype = cal.caltype;
st.list(end+1) = c;
stat = 0;
end
