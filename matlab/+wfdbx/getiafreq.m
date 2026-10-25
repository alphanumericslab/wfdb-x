function f = getiafreq(an)
%GETIAFREQ Time resolution of the times returned by an input annotator.
%   F = wfdbx.getiafreq(AN) returns the number of ticks per second of the
%   times returned by wfdbx.getann(AN), or -2 if AN is not open.
%
%   See also wfdbx.setiafreq, wfdbx.getiaorigfreq.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.ann_state();
if an >= 0 && an < numel(st.iad) && ~isempty(st.iad{an+1})
    ia = st.iad{an+1};
    if ia.afreq > 0
        f = ia.afreq * ia.tmul;
    else
        f = wfdbx.sampfreq([]) * ia.tmul / wfdbx.getspf();
    end
else
    f = -2;
end
end
