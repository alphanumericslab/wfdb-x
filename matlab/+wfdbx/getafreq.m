function f = getafreq()
%GETAFREQ Time resolution of output annotators (set by wfdbx.setafreq).
%   F = wfdbx.getafreq() returns the value given to wfdbx.setafreq (0 by
%   default).
%
%   See also wfdbx.setafreq.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.ann_state();
f = st.oafreq;
end
