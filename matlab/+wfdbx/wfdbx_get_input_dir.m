function d = wfdbx_get_input_dir()
%WFDBX_GET_INPUT_DIR The directory from which input files are read.
%   DIR = wfdbx.wfdbx_get_input_dir() returns the input directory set by
%   wfdbx.wfdbx_set_input_dir or WFDBX_INPUT_DIR, or [] if none is set (the
%   current folder).
%
%   See also wfdbx.wfdbx_set_input_dir.
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

st = wfdbx.internal.io_state();
wfdbx.internal.init_input_dir(st);
d = st.input_dir;
end
