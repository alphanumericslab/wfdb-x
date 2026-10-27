function st = ann_state()
%ANN_STATE The global state of the WFDB annotation module (a wfdbx.internal.AnnState).
%   ST = wfdbx.internal.ann_state() returns the handle object holding the
%   open annotators and the mnemonic tables.  It is created on the first
%   call.
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

persistent s
if isempty(s)
    s = wfdbx.internal.AnnState();
end
st = s;
end
