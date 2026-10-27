function code = strann(s)
%STRANN Convert a mnemonic string to an annotation code.
%   CODE = wfdbx.strann(S) returns the annotation code (1 to 49) whose
%   mnemonic (wfdbx.annstr) is S, or 0 (NOTQRS) if there is none.
%
%   See also wfdbx.annstr, wfdbx.setannstr.
%
%   Translation of the C function strann() (lib/annot.c, WFDB 10.7.0): same
%   arguments and results.

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
if ~ischar(s)
    s = '';
end
st = wfdbx.internal.ann_state();
t = st.astring;
for code = 1:ACMAX
    if strcmp(s, t{code+1})
        return;
    end
end
code = 0;
end
