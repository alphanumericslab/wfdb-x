function H = meta_parse(data)
%META_PARSE Split a header into lines and find its metadata entries.
%   H = wfdbx.internal.meta_parse(DATA) parses the bytes DATA of a header
%   (a char row, one character per byte).  The header is split after each
%   line feed; each line has a content (without its line ending) and a line
%   ending (CR LF, LF, or '' for a last line without one).  H has the
%   fields:
%
%     content, eol  1-by-N cell arrays: the content and line ending of each
%                   line
%     rec           index of the record line, the first line whose content
%                   does not begin with '#' (as the C function getinfo()
%                   reads a header), or 0 if there is none
%     info          indices of the info strings: the lines after the
%                   record line whose content begins with '#'
%     line, key, value, fkey
%                   the "Key: value" entries among the info strings, in
%                   file order (see wfdbx.internal.meta_entry): their line
%                   indices (a row), keys, values and keys with A-Z changed
%                   to a-z (1-by-M cell arrays)
%
%   wfdbx.internal.meta_bytes(H) joins the lines again.
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

LF = char(10);
CR = char(13);
data = reshape(data, 1, []);
lf = find(data == LF);
starts = [1, lf + 1];
if starts(end) > numel(data)
    starts(end) = [];
end
n = numel(starts);
content = cell(1, n);
eol = cell(1, n);
for j = 1:n
    s = starts(j);
    if j <= numel(lf)
        e = lf(j);
        if e > s && data(e - 1) == CR
            content{j} = data(s:e-2);
            eol{j} = [CR LF];
        else
            content{j} = data(s:e-1);
            eol{j} = LF;
        end
    else
        content{j} = data(s:end);
        eol{j} = '';
    end
end
H.content = content;
H.eol = eol;
H.rec = 0;
H.info = zeros(1, 0);
H.line = zeros(1, 0);
H.key = cell(1, 0);
H.value = cell(1, 0);
H.fkey = cell(1, 0);
for j = 1:n
    c = content{j};
    if isempty(c) || c(1) ~= '#'
        H.rec = j;
        break;
    end
end
if H.rec == 0
    return;
end
for j = H.rec+1:n
    c = content{j};
    if ~isempty(c) && c(1) == '#'
        H.info(end + 1) = j;
        [k, v, ok] = wfdbx.internal.meta_entry(c);
        if ok
            H.line(end + 1) = j;
            H.key{end + 1} = k;
            H.value{end + 1} = v;
            H.fkey{end + 1} = wfdbx.internal.meta_fold(k);
        end
    end
end
end
