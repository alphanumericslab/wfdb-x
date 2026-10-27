function defs = ann_defs(st)
%ANN_DEFS An annotation type definition table.
%   DEFS = wfdbx.internal.ann_defs(ST) returns the definition table of the
%   annotation state ST (a wfdbx.internal.AnnState) as a structure with
%   the fields astr (the mnemonics: a 1-by-50 cell, index code+1), tstr
%   (the descriptions; [] for NULL) and mod (1-by-50, 1 for the modified
%   codes, which are written in the table of output files).  The table of
%   the library is ann_defs(wfdbx.internal.ann_state()); that of a fresh
%   state, ann_defs(wfdbx.internal.AnnState()), holds the defaults.
%   (wfdb-x: wfdbx.internal.ann_readtable and ann_puttable take a table,
%   so that wfdbx.internal.ann_sortfile can use one of its own.)
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
% Changes from the original: the table is a value passed to the functions
% that read and write it, so that ann_sortfile can use its own. Each change
% is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
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

defs = struct('astr', {st.astring}, 'tstr', {st.tstring}, ...
    'mod', st.modified);
end
