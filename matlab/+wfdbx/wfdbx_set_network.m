function previous = wfdbx_set_network(on)
%WFDBX_SET_NETWORK Allow or forbid network access.
%   PREVIOUS = wfdbx.wfdbx_set_network(ON) allows the library to read URLs
%   if ON is true, and forbids it if ON is false.  Network access is off by
%   default.  With it off, the first attempt to open a URL prints a message.
%
%   wfdbx.wfdbx_set_network([]) restores the default: on if the environment
%   variable WFDBX_NETWORK is set to a nonzero number, otherwise off.
%
%   PREVIOUS is the previous setting (1 or 0).  Remote files are read once
%   and kept for the rest of the session.  A download gives up when it
%   cannot connect, or receives nothing, for 30 seconds.  The high-level
%   readers also take this setting as their 'network' option.
%
%   Example (record 100 of the MIT-BIH Arrhythmia Database, read from
%   PhysioNet):
%       wfdbx.wfdbx_set_network(1);
%       rec = wfdbx.read_record('100', 'input_dir', ...
%           'https://physionet.org/files/mitdb/1.0.0/');
%
%   See also wfdbx.wfdbx_get_network, wfdbx.wfdbx_set_input_dir.
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

previous = wfdbx.wfdbx_get_network();
st = wfdbx.internal.io_state();
if isempty(on) || (~islogical(on) && on < 0)
    st.network = st.env_network;
else
    st.network = double(logical(on));
end
end
