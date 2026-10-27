function [tab, mflags, stat] = ann_setdef(tab, mflags, code, s)
%ANN_SETDEF Redefine a string of an annotation type definition table.
%   [TAB, MFLAGS, STAT] = wfdbx.internal.ann_setdef(TAB, MFLAGS, CODE, S)
%   is the body of setannstr and setanndesc (WFDB-x), for a string table
%   TAB (of mnemonics or descriptions: a 1-by-50 cell, index code+1) and
%   the modification flags MFLAGS of a definition table (see
%   wfdbx.internal.ann_defs): it sets the string of code abs(CODE) to S
%   ([] means ''), and, if CODE is positive and the string changed, marks
%   the code as modified.  STAT is 0, or -1 if the code is illegal (nothing
%   is changed then; the caller prints the message).
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

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
mflag = 0;
if code > 0
    mflag = 1;
else
    code = -code;
end
if code > ACMAX
    stat = -1;
    return;
end
if ~ischar(s)
    s = '';
end
old = tab{code+1};
if ~ischar(old) || ~strcmp(old, s)
    tab{code+1} = s;
    if mflag
        mflags(code+1) = 1;
    end
end
stat = 0;
end
