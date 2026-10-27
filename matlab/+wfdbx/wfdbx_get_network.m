function on = wfdbx_get_network()
%WFDBX_GET_NETWORK True if network access is allowed.
%   ON = wfdbx.wfdbx_get_network() returns 1 if the library may read URLs
%   (see wfdbx.wfdbx_set_network), 0 otherwise.
%
%   See also wfdbx.wfdbx_set_network.
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
if isempty(st.network)
    v = wfdbx.internal.cgetenv('WFDBX_NETWORK');
    st.env_network = double(ischar(v) && wfdbx.internal.strtol(v, 10) ~= 0);
    st.network = st.env_network;
end
on = st.network;
end
