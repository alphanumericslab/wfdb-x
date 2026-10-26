function previous = wfdbx_set_input_dir(d)
%WFDBX_SET_INPUT_DIR Set the directory from which input files are read.
%   PREVIOUS = wfdbx.wfdbx_set_input_dir(DIR) makes the library read every
%   file named by a relative name (a record's header, an annotation file,
%   a file named on the command line, ...) as DIR/NAME.  DIR may be a
%   local directory (relative to the current directory, or a ~ name) or
%   the URL of a directory (e.g. 'https://physionet.org/files/mitdb/1.0.0/';
%   reading it needs network access, see wfdbx.wfdbx_set_network).  Names
%   given as absolute paths, ~ names or URLs are used as given; nothing
%   else is searched.  [] or '' restores the default: the value of the
%   environment variable WFDBX_INPUT_DIR if it is set, otherwise none
%   (names are used as given, relative to the current directory).
%   PREVIOUS is the previous directory ([] if none).  The setting is not
%   used in legacy mode (which searches the WFDB path; see wfdbx.getwfdb).
%   This function is a wfdb-x addition; the high-level readers set it for
%   their 'input_dir' option.
%
%   Example:
%       old = wfdbx.wfdbx_set_input_dir('/data/mitdb');
%       rec = wfdbx.read_record('100');        % /data/mitdb/100.hea, ...
%       wfdbx.wfdbx_set_input_dir(old);
%
%   See also wfdbx.wfdbx_get_input_dir, wfdbx.wfdbx_set_output_dir,
%   wfdbx.wfdbx_set_network, wfdbx.setwfdb.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

d = wfdbx.internal.strarg(d);
st = wfdbx.internal.io_state();
wfdbx.internal.init_input_dir(st);
previous = st.input_dir;
wfdbx.internal.put_input_dir(st, d);
end
