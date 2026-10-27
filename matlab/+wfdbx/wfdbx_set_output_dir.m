function previous = wfdbx_set_output_dir(d)
%WFDBX_SET_OUTPUT_DIR Set the directory in which output files are created.
%   PREVIOUS = wfdbx.wfdbx_set_output_dir(DIR) makes the library create every
%   output file named by a relative name (headers, signal files, annotation
%   files) in the local folder DIR.  Names given as full paths or ~ paths
%   are used as given.  A URL is refused with an error message, and the
%   setting is unchanged.
%
%   wfdbx.wfdbx_set_output_dir([]) restores the default: the environment
%   variable WFDBX_OUTPUT_DIR if it is set, otherwise the current folder.
%
%   PREVIOUS is the previous setting ([] if none).  The high-level writers
%   also take the output directory as their 'dir' option.
%
%   Example (the example writes the annotation file out/rec.qrs):
%       old = wfdbx.wfdbx_set_output_dir('out');
%       wfdbx.write_annotations('rec', 'qrs', [100 460], 'symbols', 'NN');
%       wfdbx.wfdbx_set_output_dir(old);       % out/rec.qrs was written
%
%   See also wfdbx.wfdbx_get_output_dir, wfdbx.wfdbx_set_input_dir.
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

d = wfdbx.internal.strarg(d);
st = wfdbx.internal.io_state();
wfdbx.internal.init_output_dir(st);
previous = st.output_dir;
if ischar(d) && wfdbx.internal.is_url(d)
    wfdbx.internal.wfdb_error(['wfdbx_set_output_dir: the output ' ...
        'directory must be a local directory\n']);
elseif ischar(d) && ~isempty(d)
    st.output_dir = d;
else
    st.output_dir = st.env_output_dir;
end
end
