function d = wfdbx_get_output_dir()
%WFDBX_GET_OUTPUT_DIR The directory in which output files are created.
%   DIR = wfdbx.wfdbx_get_output_dir() returns the directory set by
%   wfdbx.wfdbx_set_output_dir, or [] if none.  This function is a wfdb-x
%   addition.
%
%   See also wfdbx.wfdbx_set_output_dir.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.io_state();
wfdbx.internal.init_output_dir(st);
d = st.output_dir;
end
