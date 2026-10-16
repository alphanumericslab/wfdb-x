function stat = ungetann(an, annot)
%UNGETANN Push an annotation back into an input annotator.
%   STAT = wfdbx.ungetann(AN, ANNOT) makes ANNOT the annotation returned
%   by the next wfdbx.getann(AN).  Only one annotation can be pushed back.
%   STAT is 0 on success, -1 if the pushback buffer is full, or -2 if AN
%   is not an open input annotator.
%
%   See also wfdbx.getann.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.annstate();
if an < 0 || an >= numel(st.iad) || isempty(st.iad{an+1})
    wfdbx.internal.wfdb_error('ungetann: annotator %d is not initialized\n', an);
    stat = -2;
    return;
end
ia = st.iad{an+1};
if ia.pann.anntyp ~= 0
    wfdbx.internal.wfdb_error('ungetann: pushback buffer is full\n');
    wfdbx.internal.wfdb_error( ...
        'ungetann: annotation at %d, annotator %d not pushed back\n', ...
        annot.time, an);
    stat = -1;
    return;
end
p = wfdbx.annotation();
p.time = annot.time;
p.anntyp = annot.anntyp;
p.subtyp = annot.subtyp;
p.chan = annot.chan;
p.num = annot.num;
p.aux = annot.aux;
ia.pann = p;
if annot.time == ia.prev_time
    ia.pann_tt = ia.prev_tt;
else
    ia.pann_tt = annot.time / ia.tmul;
end
st.iad{an+1} = ia;
stat = 0;
end
