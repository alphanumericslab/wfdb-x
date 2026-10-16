function wfdb_anclose()
%WFDB_ANCLOSE Close all annotators (called by wfdbx.wfdbquit and annopen).
%   wfdbx.internal.wfdb_anclose() closes all input annotators, then all
%   output annotators (last opened first), as wfdb_anclose in annot.c.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.annstate();
for an = numel(st.iad):-1:1
    wfdbx.iannclose(an - 1);
end
for an = numel(st.oad):-1:1
    wfdbx.oannclose(an - 1);
end
end
