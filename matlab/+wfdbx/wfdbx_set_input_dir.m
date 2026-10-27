function previous = wfdbx_set_input_dir(d)
%WFDBX_SET_INPUT_DIR Set the directory from which input files are read.
%   PREVIOUS = wfdbx.wfdbx_set_input_dir(DIR) makes the library read every
%   file named by a relative name, such as '100' or 'mitdb/100', from DIR.
%   DIR is a local folder, a ~ path or the URL of a directory, such as
%   'https://physionet.org/files/mitdb/1.0.0/'.  Reading a URL needs network
%   access (see wfdbx.wfdbx_set_network).  Names given as full paths, ~
%   paths or URLs are used as given.
%
%   wfdbx.wfdbx_set_input_dir([]) restores the default: the environment
%   variable WFDBX_INPUT_DIR if it is set, otherwise the current folder.
%
%   PREVIOUS is the previous setting ([] if none).  The high-level readers
%   also take the input directory as their 'input_dir' option.
%
%   Example (/data/mitdb stands for a local copy of the MIT-BIH Arrhythmia
%   Database in /data/mitdb):
%       old = wfdbx.wfdbx_set_input_dir('/data/mitdb');
%       rec = wfdbx.read_record('100');        % reads /data/mitdb/100.hea, ...
%       wfdbx.wfdbx_set_input_dir(old);
%
%   See also wfdbx.wfdbx_get_input_dir, wfdbx.wfdbx_set_output_dir,
%   wfdbx.wfdbx_set_network.
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
wfdbx.internal.init_input_dir(st);
previous = st.input_dir;
wfdbx.internal.put_input_dir(st, d);
end
