function d = wfdbx_get_input_dir()
%WFDBX_GET_INPUT_DIR The directory from which input files are read.
%   DIR = wfdbx.wfdbx_get_input_dir() returns the input directory (see
%   wfdbx.wfdbx_set_input_dir), or [] if none.  This function is a wfdb-x
%   addition.
%
%   See also wfdbx.wfdbx_set_input_dir.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.io_state();
wfdbx.internal.init_input_dir(st);
d = st.input_dir;
end
