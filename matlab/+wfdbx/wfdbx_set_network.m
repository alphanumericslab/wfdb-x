function previous = wfdbx_set_network(on)
%WFDBX_SET_NETWORK Allow or forbid network access.
%   PREVIOUS = wfdbx.wfdbx_set_network(ON) allows the library to open URLs
%   (http:// and https:// names, or files under a URL input directory) if
%   ON is true (or a positive number), and forbids it if ON is false (0).
%   [] or a negative number restores the default: allowed if the
%   environment variable WFDBX_NETWORK is set to a nonzero number,
%   otherwise forbidden.  PREVIOUS is the previous setting (1 or 0).
%   Network access is off by default: the first attempt to open a URL
%   then prints a message.  Remote files are read in full (redirects are
%   followed; an HTTP status of 400 or more is a failure, and reading
%   gives up if connecting takes 30 s or no data arrives for 30 s, with no
%   limit on the total time) and kept for the rest of the session (each URL is
%   requested at most once).  Legacy mode reads no remote files.  This
%   function is a wfdb-x addition; the high-level readers set it for
%   their 'network' option.
%
%   Example:
%       wfdbx.wfdbx_set_network(1);
%       rec = wfdbx.read_record('100', 'input_dir', ...
%           'https://physionet.org/files/mitdb/1.0.0/');
%
%   See also wfdbx.wfdbx_get_network, wfdbx.wfdbx_set_input_dir.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

previous = wfdbx.wfdbx_get_network();
st = wfdbx.internal.io_state();
if isempty(on) || (~islogical(on) && on < 0)
    st.network = st.env_network;
else
    st.network = double(logical(on));
end
end
