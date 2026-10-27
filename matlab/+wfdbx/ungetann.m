function stat = ungetann(an, annot)
%UNGETANN Push an annotation back into an input annotator.
%   STAT = wfdbx.ungetann(AN, ANNOT) makes ANNOT the annotation returned
%   by the next wfdbx.getann(AN).  Only one annotation can be pushed back.
%   STAT is 0 on success, -1 if the pushback buffer is full, or -2 if AN
%   is not an open input annotator.
%
%   See also wfdbx.getann.
%
%   Translation of the C function ungetann() (lib/annot.c, WFDB 10.7.0):
%   same arguments and results.

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

st = wfdbx.internal.ann_state();
if an < 0 || an >= numel(st.iad) || isempty(st.iad{an+1})
    wfdbx.internal.wfdb_error('ungetann: annotator %d is not initialized\n', an);
    stat = -2;
    return;
end
ia = st.iad{an+1};
if ia.pann.anntyp ~= 0
    wfdbx.internal.wfdb_error('ungetann: pushback buffer is full\n');
    wfdbx.internal.wfdb_error( ...
        'ungetann: annotation at %d, annotator %d not pushed back\n', ...
        annot.time, an);
    stat = -1;
    return;
end
ia = wfdbx.internal.ann_unget(ia, annot);
st.iad{an+1} = ia;
stat = 0;
end
