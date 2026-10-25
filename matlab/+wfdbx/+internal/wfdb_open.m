function f = wfdb_open(s, record, mode)
%WFDB_OPEN Find and open a WFDB file.
%   F = wfdbx.internal.wfdb_open(S, RECORD, MODE) opens the file of type S
%   (e.g. 'hea', 'atr'; [] or '' for none) of the record RECORD, and
%   returns a wfdbx.internal.WFDBFile, or [] (NULL) if it cannot be opened.
%   MODE is 0 (WFDB_READ), 1 (WFDB_WRITE) or 4 (WFDB_APPEND).
%
%   For reading, the file RECORD.S is searched in each directory of the
%   WFDB path (with %r in a path component replaced by the current record
%   name, and %Nr by its first N characters); if RECORD.S is not found,
%   the short name RECORD.S(1:3) is tried.  The directory of a file found
%   is moved to the front of the WFDB path (wfdbx.internal.wfdb_addtopath).
%   An absolute name (beginning with '/'; on MS-Windows also 'X:\',
%   'X:/' or '\\') is first opened as given, except in legacy mode
%   (wfdb-x).  Output files are created in the current directory (or in
%   the directory given by RECORD), within the output directory if one is
%   set (wfdbx.wfdbx_set_output_dir; wfdb-x).  If RECORD is empty, S is
%   the file name.
%   The record '-' is the standard input (MODE 0) or output.
%
%   The name of the file opened (or of the last file tried) is available
%   from wfdbx.wfdbfile([], []) (io_state().wfdb_filename).
%
%   Remote files (http:// and https:// URLs) are not supported: such path
%   components and records are never found.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, after a code review, Oct 2026): an input
% file named by an absolute path is opened directly (the C library
% searched for it in each directory of the WFDB path, so that it was found
% only if the path had an empty component or the current directory was
% the root), and output files can be created in a directory set with
% wfdbx.wfdbx_set_output_dir.  The original behavior remains available
% with --legacy (see docs/DIVERGENCES.md).
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if ~ischar(s)
    s = '';
end
if ~ischar(record) || isempty(record)
    if ~isempty(s)
        record = s;
        s = '';
    else
        f = [];
        return;
    end
end
st = wfdbx.internal.io_state();
if strcmp(record, '-')
    if mode == 0
        if isempty(st.stdin_file)
            st.stdin_file = wfdbx.internal.WFDBFile(-1, 0, '-', 1);
        end
        f = st.stdin_file;
    else
        if isempty(st.stdout_file)
            st.stdout_file = wfdbx.internal.WFDBFile(-1, 0, '-', 2);
        end
        f = st.stdout_file;
    end
    return;
end
% A record name ending with '/' (e.g. "dir/") means "dir/dir".
rlen = numel(record);
r = record;
if rlen > 1 && record(rlen) == '/'
    p = rlen;           % 1-based index of the final '/'
    q = p - 1;
    while q > 1
        if record(q) == '/'
            q = q + 1;
            break;
        end
        q = q - 1;
    end
    if q < p
        r = [record record(q:p-1)];
    end
end
if mode == 1 || mode == 4
    st.wfdb_filename = spr1(r, s);
    if ischar(st.output_dir)    % wfdb-x: in the output directory, if set
        st.wfdb_filename = [st.output_dir '/' st.wfdb_filename];
    end
    if mode == 1
        f = wfdbx.internal.wfdb_fopen(st.wfdb_filename, 'wb');
    else
        f = wfdbx.internal.wfdb_fopen(st.wfdb_filename, 'ab');
    end
    return;
end
if isempty(st.path_prefix)
    wfdbx.getwfdb();
end
if strncmp(r, 'http://', 7) || strncmp(r, 'https://', 8)
    st.wfdb_filename = spr1(r, s);
    f = wfdbx.internal.wfdb_fopen(st.wfdb_filename, 'rb');
    if ~isempty(f)
        wfdbx.internal.wfdb_addtopath(st.wfdb_filename);
        return;
    end
end
% wfdb-x: an absolute local path is opened directly (and, as for a URL,
% its directory is added to the WFDB path); if it cannot be, the WFDB path
% is searched as in the C library (and in legacy mode).
if is_absolute_path(r) && ~wfdbx.wfdbx_get_legacy()
    st.wfdb_filename = spr1(r, s);
    f = wfdbx.internal.wfdb_fopen(st.wfdb_filename, 'rb');
    if ~isempty(f)
        wfdbx.internal.wfdb_addtopath(st.wfdb_filename);
        return;
    end
end
irec = st.irec;
prefixes = st.path_prefix;      % a copy: wfdb_addtopath may change the path
ptypes = st.path_type;
for k = 1:numel(prefixes)
    b = prefixes{k};
    if any(b == '%')
        b = expand(b, irec);
    end
    if ~isempty(b)
        if ptypes(k) == 1
            if b(end) ~= '/'
                b = [b '/']; %#ok<AGROW>
            end
        elseif b(end) ~= '/'
            b = [b '/']; %#ok<AGROW>
        end
    end
    b = [b r]; %#ok<AGROW>
    st.wfdb_filename = spr1(b, s);
    f = wfdbx.internal.wfdb_fopen(st.wfdb_filename, 'rb');
    if ~isempty(f)
        wfdbx.internal.wfdb_addtopath(st.wfdb_filename);
        return;
    end
    long_filename = st.wfdb_filename;
    st.wfdb_filename = spr2(b, s);
    if ~strcmp(st.wfdb_filename, long_filename)
        f = wfdbx.internal.wfdb_fopen(st.wfdb_filename, 'rb');
        if ~isempty(f)
            wfdbx.internal.wfdb_addtopath(st.wfdb_filename);
            return;
        end
    end
end
f = [];
end

function tf = is_absolute_path(s)
% wfdb-x: true if S is an absolute local path: on POSIX systems, one that
% begins with '/'; on MS-Windows, one that begins with 'X:\', 'X:/', '\\'
% or '/'.
tf = s(1) == '/';
if ~tf && ispc() && numel(s) >= 2
    tf = (numel(s) >= 3 && s(2) == ':' && (s(3) == '\' || s(3) == '/') && ...
        ((s(1) >= 'A' && s(1) <= 'Z') || (s(1) >= 'a' && s(1) <= 'z'))) || ...
        (s(1) == '\' && s(2) == '\');
end
end

function n = spr1(record, ftype)
if isempty(ftype)
    n = record;
else
    n = [record '.' ftype];
end
end

function n = spr2(record, ftype)
if isempty(ftype)
    n = [record '.'];
else
    n = [record '.' ftype(1:min(end, 3))];
end
end

function out = expand(prefix, irec)
% Substitute %r (record name) and %Nr (its first N characters).
out = '';
n = numel(prefix);
i = 1;
while i <= n
    c = prefix(i);
    if c == '%'
        i = i + 1;
        if i <= n
            c = prefix(i);
        else
            c = char(0);
        end
        if c == 'r'
            out = [out irec]; %#ok<AGROW>
            i = i + 1;
        elseif c >= '1' && c <= '9' && i + 1 <= n && prefix(i+1) == 'r'
            out = [out irec(1:min(end, c - 48))]; %#ok<AGROW>
            i = i + 2;
        else
            if c ~= char(0)
                out = [out c]; %#ok<AGROW>
            end
            i = i + 1;
        end
    else
        out = [out c]; %#ok<AGROW>
        i = i + 1;
    end
end
end
