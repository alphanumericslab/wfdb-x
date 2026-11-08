function p = wfdbx_input_path(name)
%WFDBX_INPUT_PATH Where a program opens a file that it reads itself.
%   P = wfdbx.wfdbx_input_path(NAME) returns the path under which a program
%   opens a file that it reads itself, rather than through the library.
%   The file is found where wfdb_open finds a file of that name (with an
%   empty file type): in normal mode, a relative name under the input
%   directory, if one is set (see wfdbx.wfdbx_set_input_dir), a ~ name
%   expanded, and an absolute name as given; in legacy mode, the name as
%   given.  The tools use it for the files named on their command line
%   that they read themselves, such as the -i file of wrsamp.
%
%   NAME is a file name (char vector or string).  [], '' and '-' (the
%   standard input, if the program treats it so) are returned as given.
%
%   P is the path to open, or [] if NAME is a URL, or becomes one when the
%   input directory is prefixed to it: such a file cannot be opened in
%   this way.
%
%   Example (reads a text file from the input directory):
%       old = wfdbx.wfdbx_set_input_dir('data');
%       fid = fopen(wfdbx.wfdbx_input_path('samples.txt'), 'rb');
%       text = fread(fid, Inf, 'uint8=>char')';      % data/samples.txt
%       fclose(fid);
%       wfdbx.wfdbx_set_input_dir(old);
%
%   See also wfdbx.wfdbx_output_path, wfdbx.wfdbx_set_input_dir.
%
%   Part of WFDB-x; not in the original WFDB package (C:
%   wfdbx_input_path).

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

% WFDB-x: files that a program opens itself.  Decided by Reza Sameni, Nov
% 2026: a file named to a tool is found, or created, where the library
% finds, or creates, a file of that name, so that the input and output
% directories apply to every file a tool reads or writes.
name = wfdbx.internal.strarg(name);
if ~ischar(name) || wfdbx.internal.is_url(name)
    p = [];
    return;
end
if isempty(name) || strcmp(name, '-') || wfdbx.wfdbx_get_legacy()
    p = name;
    return;
end
p = wfdbx.internal.resolve_name(name, false);
if wfdbx.internal.is_url(p)
    p = [];
end
end
