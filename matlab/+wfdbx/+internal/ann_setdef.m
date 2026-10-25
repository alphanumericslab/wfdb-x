function [tab, mflags, stat] = ann_setdef(tab, mflags, code, s)
%ANN_SETDEF Redefine a string of an annotation type definition table.
%   [TAB, MFLAGS, STAT] = wfdbx.internal.ann_setdef(TAB, MFLAGS, CODE, S)
%   is the body of setannstr and setanndesc (wfdb-x), for a string table
%   TAB (of mnemonics or descriptions: a 1-by-50 cell, index code+1) and
%   the modification flags MFLAGS of a definition table (see
%   wfdbx.internal.ann_defs): it sets the string of code abs(CODE) to S
%   ([] means ''), and, if CODE is positive and the string changed, marks
%   the code as modified.  STAT is 0, or -1 if the code is illegal (nothing
%   is changed then; the caller prints the message).

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
