function f = getiaorigfreq(an)
%GETIAORIGFREQ Time resolution recorded in an input annotation file.
%   F = wfdbx.getiaorigfreq(AN) returns the time resolution given by the
%   "## time resolution" record of input annotator AN, 0 if there is none,
%   or -2 if AN is not open.
%
%   See also wfdbx.getiafreq.
%
%   Translation of the C function getiaorigfreq() (lib/annot.c, WFDB
%   10.7.0): same arguments and results.

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
    f = st.iad{an+1}.afreq;
else
    f = -2;
end
end
