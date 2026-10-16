function [stat, annot, ia] = ann_get1(ia)
%ANN_GET1 getann for one input annotator structure.
%   [STAT, ANNOT, IA] = wfdbx.internal.ann_get1(IA) does what getann does
%   for the input annotator IA (see wfdbx.internal.ann_next) and returns
%   its updated state.  ANNOT is [] unless STAT is 0.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if ia.pann.anntyp ~= 0
    annot = ia.pann;
    ia.pann.anntyp = 0;
    ia.prev_time = annot.time;
    ia.prev_tt = ia.pann_tt;
    stat = 0;
    return;
end
if ia.ateof ~= 0
    annot = [];
    if ia.ateof ~= -1
        stat = -1;
        return;
    end
    wfdbx.internal.wfdb_error('getann: unexpected EOF in annotator %s\n', ...
        ia.name);
    stat = -3;
    return;
end
a = ia.ann;
ia.prev_time = a.time;
ia.prev_tt = ia.ann_tt;
retpos = ia.auxpos;
ia = wfdbx.internal.ann_next(ia);
if retpos >= 0
    a.aux = wfdbx.internal.ann_auxget(ia.buf, retpos);
else
    a.aux = [];
end
annot = a;
stat = 0;
end
