function p = resolve_name(name, output)
%RESOLVE_NAME The location of a file named by a name (normal mode).
%   P = wfdbx.internal.resolve_name(NAME, OUTPUT) (wfdb-x) returns where
%   the file NAME is read (OUTPUT false) or written (OUTPUT true): a name
%   beginning with '~' with the home directory expanded
%   (wfdbx.internal.expand_home), an absolute name or a URL as given, and
%   any other (relative) name under the input directory (for reading) or
%   the output directory (for writing), if one is set, joined with exactly
%   one separator ('/' after a URL); '~' in the directory is expanded.
%   Nothing is searched.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if ~isempty(name) && name(1) == '~'
    p = wfdbx.internal.expand_home(name);
    return;
end
if wfdbx.internal.is_absolute_path(name) || wfdbx.internal.is_url(name)
    p = name;
    return;
end
st = wfdbx.internal.io_state();
if output
    wfdbx.internal.init_output_dir(st);
    d = st.output_dir;
else
    wfdbx.internal.init_input_dir(st);
    d = st.input_dir;
end
if ~ischar(d) || isempty(d)
    p = name;
    return;
end
d = wfdbx.internal.expand_home(d);
if isempty(d) || d(end) == '/' || (ispc() && d(end) == '\')
    p = [d name];
else
    p = [d '/' name];
end
end
