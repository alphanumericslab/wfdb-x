function removed = meta_change(record, keys, values, opt, id)
%META_CHANGE Change the metadata entries of the header of a record.
%   REMOVED = wfdbx.internal.meta_change(RECORD, KEYS, VALUES, OPT, ID)
%   applies the changes KEYS, VALUES (checked by
%   wfdbx.internal.meta_changes, meta_key and meta_value; a value of []
%   removes the entries for the key) to the header of RECORD, in order,
%   and returns the number of lines removed.  OPT has the options
%   'input_dir' and 'network' (for reading the header; see
%   wfdbx.internal.meta_read) and 'dir' (a directory in which to write the
%   changed header under the same file name, instead of the header that
%   was read; [] or '' for none).  ID gives the error identifiers
%   (wfdbx.internal.meta_id).
%
%   A change of an entry replaces its line, keeping its line ending, by
%   "# Key: value" ("# Key:" for an empty value); a new entry is inserted
%   after the last info string, or, if there is none, after the last line
%   that is not blank, with the line ending of the record line (or of the
%   first line that has one, or CR LF).  Every other byte is kept.  The
%   header is written (through wfdbx.internal.meta_write) only if it
%   changes, or if 'dir' is given.  Every change is checked before
%   anything is written.
%
%   Errors (argument errors: identifier ID.arg; file errors: ID.file):
%   those of meta_read; 'dir' not a string (argument error) or not an
%   existing directory (file error: "directory DIR does not exist"); a
%   header read from a URL without 'dir', a header without a record line,
%   or a key to be set that has more than one entry in the header
%   (argument errors); a header that cannot be written (file error).
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

d = opt.dir;
if ~(ischar(d) || (isa(d, 'double') && isempty(d)))
    error(id.arg, '%s: dir must be a directory name', id.fname);
end
has_dir = ischar(d) && ~isempty(d);
[data, path, url] = wfdbx.internal.meta_read(record, opt.input_dir, ...
    opt.network, id);
% (the destination)
if ~has_dir
    if url
        error(id.arg, ['header of record %s was read from a URL, and cannot ' ...
            'be changed (give ''dir'' to write the changed header to a local ' ...
            'directory)'], record);
    end
    dest = path;
else
    dd = wfdbx.internal.expand_home(reshape(d, 1, []));
    if ~isfolder(dd)
        error(id.file, 'directory %s does not exist', d);
    end
    seps = find(path == '/' | path == '\');
    if ~isempty(seps)
        base = path(seps(end)+1:end);
    else
        base = path;
    end
    if dd(end) == '/' || (ispc() && dd(end) == '\')
        dest = [dd base];
    else
        dest = [dd '/' base];
    end
end
H = wfdbx.internal.meta_parse(data);
if H.rec == 0
    error(id.arg, 'header of record %s has no record line', record);
end
% (every change is checked before the header is changed)
for c = 1:numel(keys)
    idx = matches(H, keys{c});
    if ischar(values{c}) && numel(idx) > 1
        L = sprintf('%d, ', idx);
        error(id.arg, ['header of record %s has more than one entry for key ' ...
            '%s (lines %s); remove them first'], record, keys{c}, L(1:end-2));
    end
end
removed = 0;
for c = 1:numel(keys)
    k = keys{c};
    v = values{c};
    idx = matches(H, k);
    if ~ischar(v)
        H.content(idx) = [];
        H.eol(idx) = [];
        removed = removed + numel(idx);
    elseif ~isempty(idx)
        H.content{idx(1)} = entry_line(k, v);
    else
        H = insert(H, entry_line(k, v));
    end
    H = wfdbx.internal.meta_parse(wfdbx.internal.meta_bytes(H));
end
out = wfdbx.internal.meta_bytes(H);
if has_dir || numel(out) ~= numel(data) || any(out ~= data)
    wfdbx.internal.meta_write(dest, out, record, id);
end
end

function idx = matches(H, key)
% the line indices of the entries for KEY (without regard to letter case)
idx = H.line(strcmp(H.fkey, wfdbx.internal.meta_fold(key)));
end

function s = entry_line(k, v)
% an entry as it is written: "# Key: value", or "# Key:"
if isempty(v)
    s = ['# ' k ':'];
else
    s = ['# ' k ': ' v];
end
end

function H = insert(H, content)
% Insert a line of the given content at the insertion point of H.
% (the line ending: that of the record line, or of the first line that
% has one, or CR LF)
eol = H.eol{H.rec};
if isempty(eol)
    k = find(~cellfun('isempty', H.eol), 1);
    if isempty(k)
        eol = sprintf('\r\n');
    else
        eol = H.eol{k};
    end
end
% (after the last info string, or after the last line that is not blank)
n = numel(H.content);
if ~isempty(H.info)
    at = H.info(end) + 1;
else
    at = n + 1;
    for j = n:-1:1
        if ~isempty(wfdbx.internal.meta_trim(H.content{j}))
            at = j + 1;
            break;
        end
    end
end
if at > 1 && isempty(H.eol{at - 1})
    H.eol{at - 1} = eol;
end
H.content = [H.content(1:at-1), {content}, H.content(at:end)];
H.eol = [H.eol(1:at-1), {eol}, H.eol(at:end)];
end
