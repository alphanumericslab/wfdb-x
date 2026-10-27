function put_input_dir(st, d)
%PUT_INPUT_DIR Set the input directory.
%   wfdbx.internal.put_input_dir(ST, D) (WFDB-x) sets the input directory
%   of the I/O state ST to D, or, if D is [] or '', to its default (the
%   value of WFDBX_INPUT_DIR, or none).  Used by wfdbx.wfdbx_set_input_dir,
%   wfdbx.setwfdb and wfdbx.resetwfdb.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

wfdbx.internal.init_input_dir(st);
if ischar(d) && ~isempty(d)
    st.input_dir = d;
else
    st.input_dir = st.env_input_dir;
end
end
