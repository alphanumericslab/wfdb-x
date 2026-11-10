function p = wfdbx_output_path(name)
%WFDBX_OUTPUT_PATH Where a program creates a file that it writes itself.
%   P = wfdbx.wfdbx_output_path(NAME) returns the path under which a
%   program creates a file that it writes itself, rather than through the
%   library.  The file is created where wfdb_open creates a file of that
%   name (with an empty file type): in normal mode, a relative name under
%   the output directory, if one is set (see wfdbx.wfdbx_set_output_dir), a
%   ~ name expanded, and an absolute name as given; in legacy mode, any
%   name under the output directory, if one is set, used as a plain prefix.
%   When the output directory has been prefixed to the name, the
%   directories missing in the resulting path are created, as for the
%   output files of the library.  The tools use it for the files they
%   create themselves, such as the WAV file of mit2wav.
%
%   NAME is a file name (char vector or string).  [], '' and '-' (the
%   standard output, if the program treats it so) are returned as given.
%
%   P is the path to create, or [] if NAME is a URL (in normal mode, any
%   name that begins with a URL scheme), which cannot be written.
%
%   Example (writes a text file in the output directory):
%       old = wfdbx.wfdbx_set_output_dir('out');
%       fid = fopen(wfdbx.wfdbx_output_path('notes.txt'), 'wb');
%       fprintf(fid, 'checked\n');                    % out/notes.txt
%       fclose(fid);
%       wfdbx.wfdbx_set_output_dir(old);
%
%   See also wfdbx.wfdbx_input_path, wfdbx.wfdbx_set_output_dir.
%
%   Part of WFDB-x; not in the original WFDB package (C:
%   wfdbx_output_path).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU Lesser General Public License as published by
% the Free Software Foundation, either version 2.1 of the License, or (at
% your option) any later version. See LICENSE.

% WFDB-x: files that a program opens itself (see wfdbx.wfdbx_input_path).
name = wfdbx.internal.strarg(name);
if ~ischar(name) || wfdbx.internal.is_url(name)
    p = [];
    return;
end
if isempty(name) || strcmp(name, '-')
    p = name;
    return;
end
st = wfdbx.internal.io_state();
wfdbx.internal.init_output_dir(st);
d = st.output_dir;
if wfdbx.wfdbx_get_legacy()
    if ~ischar(d) || isempty(d)
        p = name;
        return;
    end
    p = [d '/' name];       % (as wfdb_open in legacy mode)
else
    if wfdbx.internal.has_scheme(name)
        p = [];
        return;
    end
    if ~ischar(d) || isempty(d) || name(1) == '~' || ...
            wfdbx.internal.is_absolute_path(name)
        p = wfdbx.internal.resolve_name(name, true);
        return;
    end
    p = wfdbx.internal.resolve_name(name, true);
end
% create the missing directories (only at '/' separators, as for the
% output files of the library; errors are ignored: opening then fails)
for k = reshape(find(p == '/'), 1, [])
    if k > 1
        dk = p(1:k-1);
        dk = wfdbx.internal.literal_path(dk);
        if ~isfolder(dk)
            [ok, msg] = mkdir(dk); %#ok<ASGLU>
        end
    end
end
end
