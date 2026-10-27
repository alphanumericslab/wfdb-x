function stat = setanndesc(code, s)
%SETANNDESC Redefine the description of an annotation code.
%   STAT = wfdbx.setanndesc(CODE, S) makes S the description returned by
%   wfdbx.anndesc for annotation code CODE (0 to 49).  If CODE is positive, the change is recorded so that
%   it is written in the table of the annotation files written afterwards;
%   with -CODE, it is not.  STAT is 0, or -1 for an illegal code.
%
%   See also wfdbx.anndesc, wfdbx.setannstr.
%
%   Translation of the C function setanndesc() (lib/annot.c, WFDB 10.7.0):
%   same arguments and results.

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
[tab, mflags, stat] = wfdbx.internal.ann_setdef(st.tstring, st.modified, code, s);
if stat == 0
    st.tstring = tab;
    st.modified = mflags;
else
    wfdbx.internal.wfdb_error('setanndesc: illegal annotation code %d\n', ...
        abs(code));
end
end
