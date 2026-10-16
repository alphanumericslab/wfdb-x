function [stat, cal] = getcal(desc, units)
%GETCAL Find calibration information for a signal type.
%   [STAT, CAL] = wfdbx.getcal(DESC, UNITS) searches the calibration list
%   (see wfdbx.calopen) for the first entry whose signal type is a prefix
%   of DESC and whose units are UNITS ([] matches anything).  STAT is 0
%   and CAL a wfdbx.calinfo structure if one is found; otherwise STAT is
%   -1 and CAL is an empty calinfo structure.
%
%   Example:
%       wfdbx.calopen('wfdbcal');
%       [stat, cal] = wfdbx.getcal('ECG lead II', 'mV');
%
%   See also wfdbx.calopen, wfdbx.putcal.

% Copyright (C) 1991-2013 George B. Moody (original C implementation,
% lib/calib.c; revised 2019-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.calstate();
L = st.list;
for k = 1:numel(L)
    c = L(k);
    nt = numel(c.sigtype);
    if (~ischar(desc) || nt == 0 || strncmp(desc, c.sigtype, nt)) && ...
            (~ischar(units) || strcmp(units, c.units))
        cal = c;
        stat = 0;
        return;
    end
end
cal = wfdbx.calinfo();
stat = -1;
end
