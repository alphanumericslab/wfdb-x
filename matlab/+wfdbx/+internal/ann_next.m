function ia = ann_next(ia)
%ANN_NEXT Read the next annotation of an input annotator into ia.ann.
%   IA = wfdbx.internal.ann_next(IA) is the second half of getann in
%   lib/annot.c: it makes the next annotation of the decoded file
%   (wfdbx.internal.ann_parse) the current one (IA.k, IA.ann, IA.ann_tt),
%   stores its aux data in the aux ring buffer (IA.buf, IA.index,
%   IA.auxpos) and sets IA.ateof at the end of the file.
%
%   An input annotator IA is a structure with the fields: file (the
%   WFDBFile), name, stat (0 = WFDB_READ, 2 = WFDB_AHA_READ), P (the
%   decoded file), k (index in P of the current annotation, 0 before the
%   first), ateof, tmul, afreq, ann (time, anntyp, subtyp, chan, num),
%   ann_tt, pann (pushed-back annotation), pann_tt, prev_tt, prev_time,
%   buf (the 771-byte aux buffer, double 0-255), index (next free
%   position, 0-based) and auxpos (0-based position of the aux string of
%   ann, or -1).
%
%   Part of the translation of lib/annot.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/annot.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/annot.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

FLINTMAX = 9007199254740992;    % 2^53: doubles are exact integers below
AUXLEN = 6;                     % length of the AHA aux field

P = ia.P;
j = ia.k + 1;
if j > P.N
    ia.ateof = 1;
    return;
end
ia.k = j;
tt = P.tt(j);
ia.ann_tt = tt;
ia.ann.anntyp = P.typ(j);
ia.ann.subtyp = P.sub(j);
ia.ann.chan = P.chan(j);
ia.ann.num = P.num(j);
x = tt * ia.tmul;
if x >= 0 && x < FLINTMAX
    t = fix(x);
    if x - t >= 0.5
        t = t + 1;
    end
    ia.ann.time = t;
else
    ia.ann.time = wfdbx.internal.ann_round(x);
end
if P.aha
    if P.badseq(j)
        wfdbx.internal.wfdb_error( ...
            'getann: unexpected annot number in annotator %s\n', ia.name);
    end
    if ia.index >= 256 - (AUXLEN + 2)   % as in C
        ia.index = 0;
    end
    kk = ia.index + 1;          % 0-based position of the data
    av = P.auxav(j);
    if av > 0
        o = P.auxoff(j);
        ia.buf(kk+1:kk+av) = double(P.D(o+1:o+av));
    end
    if ia.buf(kk+1) ~= 0
        ia.buf(ia.index+1) = AUXLEN;
        ia.auxpos = ia.index;
        ia.buf(kk+AUXLEN+1) = 0;
        ia.index = ia.index + AUXLEN + 2;
    else
        ia.auxpos = -1;
    end
else
    ia.auxpos = -1;
    for m = P.tokfirst(j):P.tokfirst(j) + P.tokcnt(j) - 1
        [ia.buf, ia.index, ia.auxpos] = wfdbx.internal.ann_auxput(ia.buf, ...
            ia.index, P, m);
    end
end
if j == P.N && P.eofend
    ia.ateof = -1;
end
end
