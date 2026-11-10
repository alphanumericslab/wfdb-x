function [fid, tmp] = temp_create(dest)
%TEMP_CREATE Create the temporary file that is to replace a file.
%   [FID, TMP] = wfdbx.internal.temp_create(DEST) creates a new file in the
%   directory of DEST, named '.NAME.XXXXXXXX.tmp' (NAME being the file name
%   of DEST, XXXXXXXX eight random letters and digits), opens it for
%   writing ('wb') and returns its file identifier FID and its name TMP.
%   FID is -1 if the file cannot be created.  The file is meant to be
%   renamed over DEST once it is complete, so it is created with the
%   permissions that DEST will then have: those of DEST if DEST exists
%   (in Octave, its read and write permissions; in MATLAB, its read, write
%   and execute permissions, set with fileattrib), otherwise those of a new
%   file (0666 less the umask).  No shell command is run, whatever the
%   name: Octave creates the file under a umask that leaves exactly those
%   permissions, so that a file whose destination is private (0600) is
%   never readable by others, even while it is written.
%
%   Used by wfdbx.internal.meta_write (the metadata functions) and by
%   wfdbx.internal.staged_open (write_record and write_annotations).
%
%   Part of WFDB-x; not in the original WFDB package.

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

seps = find(dest == '/' | (ispc() & dest == '\'));
if isempty(seps)
    prefix = '';
    base = dest;
else
    prefix = dest(1:seps(end));
    base = dest(seps(end)+1:end);
end
octave = wfdbx.internal.is_octave();
% the permissions of DEST, if it exists
mode = [];
attr = [];
if isfile(dest) && ~ispc()
    if octave
        [info, err] = stat(dest);
        if err == 0
            mode = mod(info.mode, 512);
        end
    else
        [ok, a] = fileattrib(dest);
        if ok
            attr = a;
        end
    end
end
for attempt = 1:100
    tmp = [prefix '.' base '.' token() '.tmp'];
    if ~exists(tmp, octave)
        break;
    end
end
if ~isempty(mode)
    % (Octave has no chmod: the file is created under the umask that
    % leaves the read and write permissions of DEST; umask takes and
    % returns the octal digits of the mask as a decimal number)
    old = umask(str2double(dec2base(511 - mode, 8)));
    fid = fopen(tmp, 'wb');
    umask(old);
else
    fid = fopen(tmp, 'wb');
end
if fid >= 0 && ~isempty(attr)
    set_attributes(tmp, attr);
end
end

function t = token()
% Eight random letters and digits (from tempname, which leaves the state of
% the random number generators unchanged).
t = '';
while numel(t) < 8
    [~, x] = fileparts(tempname());
    x = x((x >= 'a' & x <= 'z') | (x >= 'A' & x <= 'Z') | (x >= '0' & x <= '9'));
    t = [t, x(max(1, end - 5):end)]; %#ok<AGROW>
end
t = t(1:8);
end

function tf = exists(name, octave)
% True if anything (a dangling symbolic link included) has the name NAME.
if octave
    [~, err] = lstat(name);
    tf = err == 0;
else
    tf = isfile(name) || isfolder(name);
end
end

function set_attributes(name, a)
% MATLAB: give the file NAME the permissions a (from fileattrib).
who = {'User', 'u'; 'Group', 'g'; 'Other', 'o'};
what = {'Read', 'r'; 'Write', 'w'; 'Execute', 'x'};
for i = 1:3
    for j = 1:3
        field = [who{i, 1} what{j, 1}];
        if isfield(a, field) && ~isnan(double(a.(field)))
            if a.(field)
                fileattrib(name, ['+' what{j, 2}], who{i, 2});
            else
                fileattrib(name, ['-' what{j, 2}], who{i, 2});
            end
        end
    end
end
end
