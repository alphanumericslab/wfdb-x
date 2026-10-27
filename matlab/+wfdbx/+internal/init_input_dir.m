function init_input_dir(st)
%INIT_INPUT_DIR Read the input directory from the environment, once.
%   wfdbx.internal.init_input_dir(ST) (wfdb-x), for the I/O state ST: on
%   the first call, the input directory is taken from the environment
%   variable WFDBX_INPUT_DIR (if set and not empty).  In normal mode, the
%   first call also reports, once per process, that the environment
%   variable WFDB (if set and not empty) is ignored.
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

if ~st.input_dir_init
    st.input_dir_init = true;
    v = wfdbx.internal.cgetenv('WFDBX_INPUT_DIR');
    if ischar(v)
        st.env_input_dir = v;
        st.input_dir = v;
    end
end
if ~st.wfdb_warned && ~wfdbx.wfdbx_get_legacy()
    st.wfdb_warned = true;
    if ischar(wfdbx.internal.cgetenv('WFDB'))
        wfdbx.internal.wfdb_error(['wfdb-x: the WFDB environment variable ' ...
            'is ignored; set WFDBX_INPUT_DIR instead (or use legacy mode)\n']);
    end
end
end
