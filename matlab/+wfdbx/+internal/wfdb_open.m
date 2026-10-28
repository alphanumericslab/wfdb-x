function f = wfdb_open(s, record, mode)
%WFDB_OPEN Open a WFDB file.
%   F = wfdbx.internal.wfdb_open(S, RECORD, MODE) opens the file of type S
%   (e.g. 'hea', 'atr'; [] or '' for none) of the record RECORD, and
%   returns a wfdbx.internal.WFDBFile, or [] (NULL) if it cannot be opened.
%   MODE is 0 (WFDB_READ), 1 (WFDB_WRITE) or 4 (WFDB_APPEND).  The file
%   name is RECORD.S (or either of them alone if the other is empty); a
%   record name ending with '/' ('dir/') means 'dir/dir'.  The record '-'
%   is the standard input (MODE 0) or output.
%
%   WFDB-x: nothing is searched.  A relative name is read under the input
%   directory (wfdbx.wfdbx_set_input_dir) and written under the output
%   directory (wfdbx.wfdbx_set_output_dir), if one is set; an absolute
%   name, a ~ name or a URL is used as given (a URL can only be read, and
%   only if network access is allowed: wfdbx.wfdbx_set_network).  For
%   reading, the short name RECORD.S(1:3) is tried too, at the same
%   location (wfdbx.internal.open_at).
%
%   In legacy mode, the file is searched for in each directory of the WFDB
%   path (with %r in a path component replaced by the current record name,
%   and %Nr by its first N characters), trying RECORD.S and then the short
%   name, and the directory of a file found is moved to the front of the
%   WFDB path (wfdbx.internal.wfdb_addtopath); output files are created as
%   named (within the output directory, if one is set); no remote files
%   are read.
%
%   The name of the file opened (or of the last file tried) is available
%   from wfdbx.wfdbfile([], []) (io_state().wfdb_filename).
%
%   Translation of the C function wfdb_open() (lib/wfdbio.c, WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: files are not searched for in the WFDB path: a
% relative name is read under the input directory and written under the
% output directory, an absolute name, a ~ name or a URL is used as given,
% and URLs are opened only if network access is allowed. Each change is
% marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
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
r = wfdbx.internal.expand_record(record);    % ('dir/' means 'dir/dir')
legacy = wfdbx.wfdbx_get_legacy();
if mode == 1 || mode == 4
    st.wfdb_filename = spr1(r, s);
    wfdbx.internal.init_output_dir(st);
    if ~legacy
        % WFDB-x: a relative name in the output directory, if one is set;
        % a URL cannot be written
        if wfdbx.internal.is_url(st.wfdb_filename)
            f = [];
            return;
        end
        st.wfdb_filename = wfdbx.internal.resolve_name(st.wfdb_filename, true);
    elseif ischar(st.output_dir)    % WFDB-x: legacy mode: any name
        st.wfdb_filename = [st.output_dir '/' st.wfdb_filename];
    end
    if mode == 1
        f = wfdbx.internal.wfdb_fopen(st.wfdb_filename, 'wb');
    else
        f = wfdbx.internal.wfdb_fopen(st.wfdb_filename, 'ab');
    end
    return;
end
if ~legacy      % WFDB-x: the one location that the name designates
    f = wfdbx.internal.open_at(wfdbx.internal.resolve_name(r, false), s);
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
