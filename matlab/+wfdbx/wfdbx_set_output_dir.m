function previous = wfdbx_set_output_dir(d)
%WFDBX_SET_OUTPUT_DIR Set the directory in which output files are created.
%   PREVIOUS = wfdbx.wfdbx_set_output_dir(DIR) makes the library create
%   every output file (headers, signal files, annotation files: wfdb_open
%   in WFDB_WRITE or WFDB_APPEND mode) named by a relative name (the
%   record name, which may itself contain directories, and the file type)
%   as DIR/NAME; DIR may be relative to the current directory or a ~ name.
%   Absolute names and ~ names are used as given (in legacy mode, every
%   name is created under DIR).  [] or '' restores the default: the value
%   of the environment variable WFDBX_OUTPUT_DIR if it is set, otherwise
%   none (files are created as named).  PREVIOUS is the previous
%   directory ([] if none).  A URL is refused: an error message is
%   printed, the setting is unchanged, and PREVIOUS is its current value
%   (so that restoring it later is still correct).  Nothing else changes:
%   headers record the names as given.  The setting is not reset by
%   wfdbx.wfdbquit, and it applies in legacy mode too.  This function is
%   a wfdb-x addition; the high-level writers set it for their 'dir'
%   option.
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
