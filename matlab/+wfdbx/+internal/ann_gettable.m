function stat = ann_gettable(i)
%ANN_GETTABLE Read the annotation table at the start of an annotation file.
%   STAT = wfdbx.internal.ann_gettable(I) (get_ann_table in annot.c) reads
%   the NOTE annotations at time 0 at the start of input annotator I: the
%   time resolution ("## time resolution: F") and the redefinitions of
%   mnemonics and descriptions ("CODE MNEMONIC DESCRIPTION"), into the
%   library's table; the first other annotation is pushed back (see
%   wfdbx.internal.ann_readtable).  Then the time resolution of the
%   annotator is set (setiafreq) from the input frequency.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.ann_state();
[stat, ia, defs] = wfdbx.internal.ann_readtable(st.iad{i+1}, ...
    wfdbx.internal.ann_defs(st));
st.iad{i+1} = ia;
st.astring = defs.astr;
st.tstring = defs.tstr;
st.modified = defs.mod;
if stat < 0
    return;
end
wfdbx.setiafreq(i, wfdbx.getifreq());
end
