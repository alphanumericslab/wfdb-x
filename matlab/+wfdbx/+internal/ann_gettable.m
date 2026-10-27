function stat = ann_gettable(i)
%ANN_GETTABLE Read the annotation table at the start of an annotation file.
%   STAT = wfdbx.internal.ann_gettable(I) (get_ann_table in annot.c) reads
%   the NOTE annotations at time 0 at the start of input annotator I: the
%   time resolution ("## time resolution: F") and the redefinitions of
%   mnemonics and descriptions ("CODE MNEMONIC DESCRIPTION"), into the
%   library's table; the first other annotation is pushed back (see
%   wfdbx.internal.ann_readtable).  Then the time resolution of the
%   annotator is set (setiafreq) from the input frequency.
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

st = wfdbx.internal.ann_state();
[stat, ia, defs] = wfdbx.internal.ann_readtable(st.iad{i+1}, ...
    wfdbx.internal.ann_defs(st));
st.iad{i+1} = ia;
st.astring = defs.astr;
st.tstring = defs.tstr;
st.modified = defs.mod;
if stat < 0
    return;
end
wfdbx.setiafreq(i, wfdbx.getifreq());
end
