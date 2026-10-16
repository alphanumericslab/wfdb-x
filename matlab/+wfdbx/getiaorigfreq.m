function f = getiaorigfreq(an)
%GETIAORIGFREQ Time resolution recorded in an input annotation file.
%   F = wfdbx.getiaorigfreq(AN) returns the time resolution given by the
%   "## time resolution" record of input annotator AN, 0 if there is none,
%   or -2 if AN is not open.
%
%   See also wfdbx.getiafreq.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.annstate();
if an >= 0 && an < numel(st.iad) && ~isempty(st.iad{an+1})
    f = st.iad{an+1}.afreq;
else
    f = -2;
end
end
