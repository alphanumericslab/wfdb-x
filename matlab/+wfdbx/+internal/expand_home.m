function r = expand_home(name)
%EXPAND_HOME Expand a leading ~ in a file name.
%   R = wfdbx.internal.expand_home(NAME) (wfdb-x) returns NAME with a
%   leading '~' (followed by a directory separator or nothing) replaced by
%   the home directory ($HOME, or that of the current user if HOME is unset
%   or empty; on MS-Windows, %USERPROFILE%), and, on POSIX systems, '~USER'
%   by the home directory of USER (NAME unchanged if there is no such
%   user, or if the home directory cannot be found).  Trailing separators
%   of the home directory are dropped ('~' with home '/h/' is '/h'; an
%   empty result is '/').  Other names are returned unchanged.
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

r = name;
if isempty(name) || name(1) ~= '~'
    return;
end
i = 2;          % 1-based index just past the user name
while i <= numel(name) && ~is_dsep(name(i))
    i = i + 1;
end
home = [];
if i == 2
    if ispc()
        home = wfdbx.internal.cgetenv('USERPROFILE');
    else
        home = wfdbx.internal.cgetenv('HOME');
        if ~ischar(home)
            home = user_home([]);
        end
    end
elseif ~ispc()
    home = user_home(name(2:i-1));
end
if ~ischar(home)
    return;
end
while ~isempty(home) && is_dsep(home(end))
    home = home(1:end-1);
end
r = [home name(i:end)];
if isempty(r)
    r = '/';
end
end

function tf = is_dsep(c)
tf = c == '/' || (ispc() && c == '\');
end

function home = user_home(user)
% The home directory of USER (of the current user if USER is []), or [].
home = [];
if wfdbx.internal.is_octave()
    if isempty(user)
        pw = getpwuid(getuid());
    else
        pw = getpwnam(user);
    end
    if isstruct(pw) && ischar(pw.dir)
        home = pw.dir;
    end
elseif isempty(user)
    home = char(java.lang.System.getProperty('user.home'));
elseif ~isempty(regexp(user, '^[A-Za-z0-9._-]+$', 'once'))
    % (MATLAB has no getpwnam: the passwd database, through getent)
    [s, out] = system(['getent passwd ' user]);
    f = regexp(strtrim(out), ':', 'split');
    if s == 0 && numel(f) >= 6
        home = f{6};
    end
end
end
