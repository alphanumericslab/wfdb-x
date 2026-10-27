function lines = fgets_lines(data, bufsize)
%FGETS_LINES Split text into the successive results of C fgets().
%   LINES = wfdbx.internal.fgets_lines(DATA, BUFSIZE) returns a cell row of the
%   char vectors that successive calls of fgets(buf, BUFSIZE, fp) would return
%   when reading DATA (a uint8 or char vector, e.g. from
%   wfdbx.internal.stdin_bytes): each piece has at most BUFSIZE-1 characters
%   and ends with a newline, unless the line was longer or the input ended.
%
%   Example:
%       wfdbx.internal.fgets_lines(sprintf('abc\ndefgh'), 4)
%       % returns {'abc', char(10), 'def', 'gh'}
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

data = char(data(:)');
n = numel(data);
if n == 0
    lines = cell(1, 0);
    return;
end
lim = bufsize - 1;
ends = find(data == char(10));
if isempty(ends) || ends(end) ~= n
    ends = [ends n];
end
starts = [1 ends(1:end-1) + 1];
len = ends - starts + 1;
if all(len <= lim)
    nl = numel(ends);
    lines = cell(1, nl);
    for k = 1:nl
        lines{k} = data(starts(k):ends(k));
    end
    return;
end
% Some lines are longer than the buffer: split them into pieces.
npieces = sum(ceil(len / lim));
lines = cell(1, npieces);
m = 0;
for k = 1:numel(ends)
    i = starts(k);
    while i <= ends(k)
        j = min(i + lim - 1, ends(k));
        m = m + 1;
        lines{m} = data(i:j);
        i = j + 1;
    end
end
end
