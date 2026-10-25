function ia = ann_iadata(f, name, istat, P)
%ANN_IADATA A new input annotator structure (C's struct iadata).
%   IA = wfdbx.internal.ann_iadata(F, NAME, ISTAT, P) returns the input
%   annotator structure of the open file F (a WFDBFile) of annotator NAME,
%   in format ISTAT (0: MIT, 2: AHA), whose decoded contents are P (see
%   wfdbx.internal.ann_parse), positioned before its first annotation.
%   Its fields are described in wfdbx.internal.ann_next.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

AUXBUFLEN = 771;    % size of the aux string buffer of an input annotator
ia.file = f;
ia.name = name;
ia.stat = istat;
ia.P = P;
ia.k = 0;
ia.ateof = 0;
ia.tmul = 0;
ia.afreq = 0;
ia.ann = wfdbx.annotation();
ia.ann_tt = 0;
ia.pann = wfdbx.annotation();
ia.pann_tt = 0;
ia.prev_tt = 0;
ia.prev_time = 0;
ia.buf = zeros(1, AUXBUFLEN);
ia.index = 0;
ia.auxpos = -1;
end
