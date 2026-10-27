function d = wfdbx_get_output_dir()
%WFDBX_GET_OUTPUT_DIR The directory in which output files are created.
%   DIR = wfdbx.wfdbx_get_output_dir() returns the output directory set by
%   wfdbx.wfdbx_set_output_dir or WFDBX_OUTPUT_DIR, or [] if none is set
%   (the current folder).
%
%   See also wfdbx.wfdbx_set_output_dir.
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
wfdbx.internal.init_output_dir(st);
d = st.output_dir;
end
