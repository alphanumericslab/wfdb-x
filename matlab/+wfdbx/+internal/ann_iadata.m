function ia = ann_iadata(f, name, istat, P)
%ANN_IADATA A new input annotator structure (C's struct iadata).
%   IA = wfdbx.internal.ann_iadata(F, NAME, ISTAT, P) returns the input
%   annotator structure of the open file F (a WFDBFile) of annotator NAME,
%   in format ISTAT (0: MIT, 2: AHA), whose decoded contents are P (see
%   wfdbx.internal.ann_parse), positioned before its first annotation.
%   Its fields are described in wfdbx.internal.ann_next.
%
%   Part of the translation of lib/annot.c (WFDB 10.7.0).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
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
