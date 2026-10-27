function ia = ann_unget(ia, annot)
%ANN_UNGET Push an annotation back into an input annotator structure.
%   IA = wfdbx.internal.ann_unget(IA, ANNOT) is the body of ungetann
%   (WFDB-x), after its checks, for the input annotator structure IA
%   (whose pushback buffer is empty): ANNOT becomes the annotation that
%   the next getann returns.
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
