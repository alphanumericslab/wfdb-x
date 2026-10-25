function flushcal()
%FLUSHCAL Empty the calibration list.
%   wfdbx.flushcal() removes all entries from the calibration list.
%
%   See also wfdbx.calopen, wfdbx.putcal.

% Copyright (C) 1991-2013 George B. Moody (original C implementation,
% lib/calib.c; revised 2019-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.cal_state();
st.list = repmat(wfdbx.calinfo(), 1, 0);
end
