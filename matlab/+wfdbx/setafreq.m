function setafreq(f)
%SETAFREQ Set the time resolution of output annotators.
%   wfdbx.setafreq(F) sets the time resolution (ticks per second) recorded
%   in annotation files opened for writing afterwards (a "## time
%   resolution" NOTE is written at their start if F > 0).
%
%   See also wfdbx.getafreq, wfdbx.setiafreq.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.annstate();
st.oafreq = f;
end
