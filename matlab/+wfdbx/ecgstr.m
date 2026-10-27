function s = ecgstr(code)
%ECGSTR Convert an annotation code to a fixed mnemonic string.
%   S = wfdbx.ecgstr(CODE) returns the fixed mnemonic of annotation code
%   CODE (0 to 49; not changed by wfdbx.setannstr), or '[CODE]' for other
%   codes.
%
%   See also wfdbx.strecg, wfdbx.annstr.
%
%   Translation of the C function ecgstr() (lib/annot.c, WFDB 10.7.0): same
%   arguments and results.

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

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if code >= 0 && code <= ACMAX
    st = wfdbx.internal.ann_state();
    s = st.cstring{code+1};
else
    s = sprintf('[%d]', code);
end
end
