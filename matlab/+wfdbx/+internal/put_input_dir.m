function put_input_dir(st, d)
%PUT_INPUT_DIR Set the input directory.
%   wfdbx.internal.put_input_dir(ST, D) (wfdb-x) sets the input directory
%   of the I/O state ST to D, or, if D is [] or '', to its default (the
%   value of WFDBX_INPUT_DIR, or none).  Used by wfdbx.wfdbx_set_input_dir,
%   wfdbx.setwfdb and wfdbx.resetwfdb.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

wfdbx.internal.init_input_dir(st);
if ischar(d) && ~isempty(d)
    st.input_dir = d;
else
    st.input_dir = st.env_input_dir;
end
end
