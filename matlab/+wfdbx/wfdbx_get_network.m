function on = wfdbx_get_network()
%WFDBX_GET_NETWORK True if network access is allowed.
%   ON = wfdbx.wfdbx_get_network() returns 1 if the library may open URLs
%   (see wfdbx.wfdbx_set_network), 0 otherwise.  This function is a wfdb-x
%   addition.
%
%   See also wfdbx.wfdbx_set_network.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.io_state();
if isempty(st.network)
    v = wfdbx.internal.cgetenv('WFDBX_NETWORK');
    st.env_network = double(ischar(v) && wfdbx.internal.strtol(v, 10) ~= 0);
    st.network = st.env_network;
end
on = st.network;
end
