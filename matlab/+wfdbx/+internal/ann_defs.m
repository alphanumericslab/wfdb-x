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

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

defs = struct('astr', {st.astring}, 'tstr', {st.tstring}, ...
    'mod', st.modified);
end
