function wfdb_oaflush()
%WFDB_OAFLUSH Flush the output annotators (called by wfdbx.wfdbflush).
%   wfdbx.internal.wfdb_oaflush() writes the buffered annotations of all
%   output annotators to their files, as wfdb_oaflush in annot.c.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.annstate();
for k = 1:numel(st.oad)
    oa = wfdbx.internal.ann_oflush(st.oad{k});
    oa.file.flush();
    st.oad{k} = oa;
end
end
