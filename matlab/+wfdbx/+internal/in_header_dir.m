function tf = in_header_dir(name)
%IN_HEADER_DIR True if a name in a header stays in the header's directory.
%   TF = wfdbx.internal.in_header_dir(NAME) (wfdb-x) is true for a
%   relative name that does not begin with '~' and has no '..' component
%   (on MS-Windows, no drive letter either): the containment rule for the
%   files named in a header (see wfdbx.internal.open_in).

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

tf = false;
if wfdbx.internal.is_absolute_path(name) || wfdbx.internal.is_url(name) || ...
        (~isempty(name) && name(1) == '~')
    return;
end
if ispc()
    if numel(name) >= 2 && name(2) == ':'
        return;
    end
    name(name == '\') = '/';
end
tf = ~any(strcmp(regexp(name, '/', 'split'), '..'));
end
