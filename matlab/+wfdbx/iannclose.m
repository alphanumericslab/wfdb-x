function iannclose(an)
%IANNCLOSE Close an input annotator.
%   wfdbx.iannclose(AN) closes input annotator AN; the annotators opened
%   after it are renumbered (AN+1 becomes AN, ...), as in C.
%
%   See also wfdbx.annopen, wfdbx.oannclose.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.ann_state();
if an >= 0 && an < numel(st.iad) && ~isempty(st.iad{an+1})
    f = st.iad{an+1}.file;
    if ~isempty(f)
        f.close();
    end
    st.iad(an+1) = [];
end
end
