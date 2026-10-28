function f = fetch_open(url)
%FETCH_OPEN Open a remote file for reading (normal mode).
%   F = wfdbx.internal.fetch_open(URL) (WFDB-x) returns a read-only
%   WFDBFile (type WFDB_NET) of the contents of URL, or [].  If network
%   access is not allowed (wfdbx.wfdbx_get_network), the first such
%   attempt in the process prints a message, and [] is returned.  The file
%   is read in full (redirects are followed; an HTTP status of 400 or more
%   is a failure, and reading gives up if connecting takes 30 s or no data
%   arrives for 30 s, with no limit on the total time, since record files
%   can be large), once per process: the
%   contents, or the failure, are kept for later opens of the same URL.
%   Failures are silent (the callers print their usual messages).  The
%   contents are served from a temporary file, deleted when F is closed.
%
%   Part of the translation of lib/wfdbio.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: URLs are read only if network access is
% allowed, once per process, and through curl, webread or websave (the C
% library used libcurl). Each change is marked "WFDB-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
%
% Original C code: lib/wfdbio.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

f = [];
st = wfdbx.internal.io_state();
if ~wfdbx.wfdbx_get_network()
    if ~st.network_warned
        st.network_warned = true;
        wfdbx.internal.wfdb_error(['WFDB-x: network access is disabled; ' ...
            'set WFDBX_NETWORK=1 or call wfdbx_set_network(1) to open %s\n'], ...
            url);
    end
    return;
end
k = find(strcmp(st.fetched_urls, url), 1);
if isempty(k)
    data = fetch(url);
    st.fetched_urls{end+1} = url;
    st.fetched_data{end+1} = data;
else
    data = st.fetched_data{k};
end
if ~isa(data, 'uint8')
    return;
end
tmp = [tempname() '.wfdbx'];
fid = fopen(tmp, 'wb');
if fid < 0
    return;
end
fwrite(fid, data, 'uint8');
fclose(fid);
fid = fopen(tmp, 'rb');
if fid < 0
    delete(tmp);
    return;
end
f = wfdbx.internal.WFDBFile(fid, 1, url);   % WFDB_NET
f.temp = tmp;
end

function data = fetch(url)
% The contents of URL (uint8 row), or [] on failure.  As in WFDB-x's other
% implementations, the system program curl reads it (MATLAB and Octave can
% run programs only through a shell, so its arguments are quoted).  Without
% curl, webread (Octave) or websave (MATLAB) reads it; their timeout limits
% the whole transfer, so none is set then.
NET_TIMEOUT = '30';   % seconds to connect, or without receiving data
data = [];
tmp = [tempname() '.wfdbx'];
c = onCleanup(@() delete_if_exists(tmp)); %#ok<NASGU>
q = @wfdbx.internal.shell_quote;
cmd = ['curl --silent --fail --location --connect-timeout ' NET_TIMEOUT ...
       ' --speed-limit 1 --speed-time ' NET_TIMEOUT ' --output ' q(tmp) ...
       ' ' q(url)];
if ispc()
    cmd = [cmd ' 2>NUL'];
else
    cmd = [cmd ' 2>/dev/null'];
end
[status, ~] = system(cmd);
if status == 0
    data = read_file(tmp);
elseif status == 127 || status == 9009   % curl not found (POSIX, Windows)
    data = fetch_builtin(url, tmp);
end
if ~isempty(data) || isa(data, 'uint8')
    data = reshape(data, 1, []);
end
end

function data = fetch_builtin(url, tmp)
data = [];
try
    opt = weboptions('Timeout', Inf);
    if wfdbx.internal.is_octave()
        % (Octave's webread returns the bytes of any content as char)
        data = uint8(double(webread(url, opt)));
    else
        % MATLAB: websave writes the bytes as received
        websave(tmp, url, opt);
        data = read_file(tmp);
    end
catch
    data = [];      % (an HTTP status >= 400, no answer, ...)
end
end

function data = read_file(name)
data = [];
fid = fopen(name, 'rb');
if fid >= 0
    data = fread(fid, Inf, 'uint8=>uint8')';
    fclose(fid);
end
end

function delete_if_exists(name)
if isfile(name)
    delete(name);
end
end
