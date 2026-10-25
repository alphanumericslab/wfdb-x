function ia = ann_unget(ia, annot)
%ANN_UNGET Push an annotation back into an input annotator structure.
%   IA = wfdbx.internal.ann_unget(IA, ANNOT) is the body of ungetann
%   (wfdb-x), after its checks, for the input annotator structure IA
%   (whose pushback buffer is empty): ANNOT becomes the annotation that
%   the next getann returns.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
end
