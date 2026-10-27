function init_output_dir(st)
%INIT_OUTPUT_DIR Read the output directory from the environment, once.
%   wfdbx.internal.init_output_dir(ST) (wfdb-x), for the I/O state ST: on
%   the first call, the output directory is taken from the environment
%   variable WFDBX_OUTPUT_DIR (if set and not empty; a URL is refused with
%   an error message and ignored).
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

if ~st.output_dir_init
    st.output_dir_init = true;
    v = wfdbx.internal.cgetenv('WFDBX_OUTPUT_DIR');
    if ischar(v)
        if wfdbx.internal.is_url(v)
            wfdbx.internal.wfdb_error(['wfdbx_set_output_dir: the output ' ...
                'directory must be a local directory\n']);
        else
            st.env_output_dir = v;
            st.output_dir = v;
        end
    end
end
end
