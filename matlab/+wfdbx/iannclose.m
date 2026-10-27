function iannclose(an)
%IANNCLOSE Close an input annotator.
%   wfdbx.iannclose(AN) closes input annotator AN; the annotators opened
%   after it are renumbered (AN+1 becomes AN, ...), as in C.
%
%   See also wfdbx.annopen, wfdbx.oannclose.
%
%   Translation of the C function iannclose() (lib/annot.c, WFDB 10.7.0):
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
if an >= 0 && an < numel(st.iad) && ~isempty(st.iad{an+1})
    f = st.iad{an+1}.file;
    if ~isempty(f)
        f.close();
    end
    st.iad(an+1) = [];
end
end
