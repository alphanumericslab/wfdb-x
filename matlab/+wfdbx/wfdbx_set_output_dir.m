function previous = wfdbx_set_output_dir(d)
%WFDBX_SET_OUTPUT_DIR Set the directory in which output files are created.
%   PREVIOUS = wfdbx.wfdbx_set_output_dir(DIR) makes the library create
%   every output file (headers, signal files, annotation files: wfdb_open
%   in WFDB_WRITE or WFDB_APPEND mode) as DIR/NAME, where NAME is the name
%   it would use otherwise (the record name, which may itself contain
%   directories, and the file type).  [] or '' means none (the default:
%   files are created as named).  PREVIOUS is the previous directory ([]
%   if none).  Nothing else changes: headers record the names as given.
%   The setting is not reset by wfdbx.wfdbquit, and it applies in legacy
%   mode too.  This function is a wfdb-x addition; the high-level writers
%   set it for their 'dir' option.
%
%   Example:
%       old = wfdbx.wfdbx_set_output_dir('out');
%       ...                             % (write files)
%       wfdbx.wfdbx_set_output_dir(old);
%
%   See also wfdbx.wfdbx_get_output_dir, wfdbx.write_record,
%   wfdbx.write_annotations.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

d = wfdbx.internal.strarg(d);
st = wfdbx.internal.io_state();
previous = st.output_dir;
if ischar(d) && ~isempty(d)
    st.output_dir = d;
else
    st.output_dir = [];
end
end
