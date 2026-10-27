function [stat, annot, ia] = ann_get1(ia)
%ANN_GET1 getann for one input annotator structure.
%   [STAT, ANNOT, IA] = wfdbx.internal.ann_get1(IA) does what getann does
%   for the input annotator IA (see wfdbx.internal.ann_next) and returns
%   its updated state.  ANNOT is [] unless STAT is 0.
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
