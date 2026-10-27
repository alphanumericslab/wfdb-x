function test_cstd_parse()
%TEST_CSTD_PARSE Tests of strtol, strtod, atoi, atof, Strtok, csscanf, fgets_lines.
%   Ported from python/tests/test_cstd.py, with additional cases.  Positions
%   are 1-based (Python end index + 1).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It tests wfdb-x; it has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

% strtol
[v, e] = wfdbx.internal.strtol('  -12abc');
assert_eq([v e], [-12 6], 'strtol -12abc');
[v, e] = wfdbx.internal.strtol('abc');
assert_eq([v e], [0 1], 'strtol abc');
[v, e] = wfdbx.internal.strtol('0x1f', 16);
assert_eq([v e], [31 5], 'strtol 0x1f');
v = wfdbx.internal.strtol('99999999999999999999');
assert_eq(v, 9223372036854775807, 'strtol overflow');
v = wfdbx.internal.strtol('-99999999999999999999');
assert_eq(v, -9223372036854775808, 'strtol underflow');
[v, e] = wfdbx.internal.strtol('x 360 rest', 10, 2);
assert_eq([v e], [360 6], 'strtol at pos');
[v, e] = wfdbx.internal.strtol('017', 0);
assert_eq([v e], [15 4], 'strtol base 0 octal');
[v, e] = wfdbx.internal.strtol('0x', 0);
assert_eq([v e], [0 2], 'strtol 0x');
[v, e] = wfdbx.internal.strtol('+', 10);
assert_eq([v e], [0 1], 'strtol sign only');
[v, e] = wfdbx.internal.strtol('12345678901234567', 10);
assert_eq([v e], [12345678901234567 18], 'strtol long');
[v, e] = wfdbx.internal.strtol('zz', 36);
assert_eq([v e], [1295 3], 'strtol base 36');
v = wfdbx.internal.strtol('100', 10, 1, -2147483648, 99);
assert_eq(v, 99, 'strtol clamp');

% atoi, atof
assert_eq(wfdbx.internal.atoi(' 42x'), 42, 'atoi');
assert_eq(wfdbx.internal.atoi('4294967297'), 1, 'atoi wraps');
assert_eq(wfdbx.internal.atoi('x'), 0, 'atoi none');
assert_eq(wfdbx.internal.atof(' -2.5e1q'), -25, 'atof');

% strtod
[v, e] = wfdbx.internal.strtod('1.5e2x');
assert_eq([v e], [150 6], 'strtod 1.5e2x');
[v, e] = wfdbx.internal.strtod(' .25');
assert_eq([v e], [0.25 5], 'strtod .25');
[v, e] = wfdbx.internal.strtod('x');
assert_eq([v e], [0 1], 'strtod x');
assert_eq(wfdbx.internal.strtod('0x10'), 16, 'strtod 0x10');
assert_eq(wfdbx.internal.strtod('0x1.8p1'), 3, 'strtod hex float');
[v, e] = wfdbx.internal.strtod('1e');
assert_eq([v e], [1 2], 'strtod 1e');
[v, e] = wfdbx.internal.strtod('-Infinity!');
assert_eq([v e], [-Inf 10], 'strtod -Infinity');
[v, e] = wfdbx.internal.strtod('inf');
assert_eq([v e], [Inf 4], 'strtod inf');
[v, e] = wfdbx.internal.strtod('nan(12)x');
assert_eq(e, 8, 'strtod nan(...)');
assert(isnan(v), 'strtod nan');
[v, e] = wfdbx.internal.strtod('a 7.', 2);
assert_eq([v e], [7 5], 'strtod at pos');
assert_eq(wfdbx.internal.strtod('0.1'), 0.1, 'strtod 0.1 exact');
assert_eq(wfdbx.internal.strtod('1e400'), Inf, 'strtod overflow');

% Strtok
t = wfdbx.internal.Strtok(sprintf('  a  b\tc\r\n'));
d = sprintf(' \t\r\n');
toks = {t.next(d), t.next(d), t.next(d), t.next(d)};
assert_eq(toks(1:3), {'a', 'b', 'c'}, 'strtok tokens');
assert(isempty(toks{4}) && ~ischar(toks{4}), 'strtok NULL');
t = wfdbx.internal.Strtok(sprintf('x 0 MLII lead\r\n'));
t.next(' ');
t.next(' ');
assert_eq(t.next(sprintf('\r\n')), 'MLII lead', 'strtok rest of line');
t = wfdbx.internal.Strtok('abc');
assert_eq(t.next(' '), 'abc', 'strtok single');
assert(~ischar(t.next(' ')), 'strtok end');
t = wfdbx.internal.Strtok('   ');
assert(~ischar(t.next(' ')), 'strtok only delimiters');
t = wfdbx.internal.Strtok('a b');
t.next(' ');
assert_eq(t.rest(), 'b', 'strtok rest');

% csscanf
[n, v] = wfdbx.internal.csscanf('', '%lf');
assert_eq(n, -1, 'sscanf empty');
assert(isempty(v), 'sscanf empty values');
[n, v] = wfdbx.internal.csscanf('   ', '%lf');
assert_eq(n, -1, 'sscanf blank');
[n, v] = wfdbx.internal.csscanf('x', '%lf');
assert_eq(n, 0, 'sscanf x');
assert(isempty(v), 'sscanf x values');
[n, v] = wfdbx.internal.csscanf('12 N 1 2 3', '%lld%s%d%d%d');
assert_eq(n, 5, 'sscanf count');
assert_eq(v, {12, 'N', 1, 2, 3}, 'sscanf values');
[n, v] = wfdbx.internal.csscanf('01.02.85', '%d%*c%d%*c%d');
assert_eq(n, 3, 'sscanf date count');
assert_eq(v, {1, 2, 85}, 'sscanf date');
[n, v] = wfdbx.internal.csscanf('12 N', '%lld%s%d%d%d');
assert_eq(n, 2, 'sscanf partial');
assert_eq(v, {12, 'N'}, 'sscanf partial values');
[n, v] = wfdbx.internal.csscanf('[10:20:30 1/2/2000]', '[%d:%d:%d %d/%d/%d');
assert_eq(n, 6, 'sscanf literal');
assert_eq(v, {10, 20, 30, 1, 2, 2000}, 'sscanf literal values');
[n, v] = wfdbx.internal.csscanf('1,2,"Q', '%d,%d,"%c');
assert_eq(n, 3, 'sscanf %c');
assert_eq(v, {1, 2, 'Q'}, 'sscanf %c values');
[n, v] = wfdbx.internal.csscanf('abcdef', '%3s%s');
assert_eq(v, {'abc', 'def'}, 'sscanf width');
assert_eq(n, 2, 'sscanf width count');
[n, v] = wfdbx.internal.csscanf('ff 0x10 017', '%x %i %i');
assert_eq(v, {255, 16, 15}, 'sscanf hex');
assert_eq(n, 3, 'sscanf hex count');
[n, v] = wfdbx.internal.csscanf('1.5 2', '%lf%lf');
assert_eq(v, {1.5, 2}, 'sscanf doubles');
assert_eq(n, 2, 'sscanf doubles count');
[n, ~] = wfdbx.internal.csscanf('5', '%d%d');
assert_eq(n, 1, 'sscanf eof after first');
[n, ~] = wfdbx.internal.csscanf('', 'x%d');
assert_eq(n, -1, 'sscanf eof at literal');

% fgets_lines
assert_eq(wfdbx.internal.fgets_lines(uint8(sprintf('abc\ndefgh')), 4), ...
    {'abc', char(10), 'def', 'gh'}, 'fgets_lines');
assert_eq(wfdbx.internal.fgets_lines(sprintf('a\nbc\n'), 100), ...
    {sprintf('a\n'), sprintf('bc\n')}, 'fgets_lines short');
assert_eq(numel(wfdbx.internal.fgets_lines('', 10)), 0, 'fgets_lines empty');
assert_eq(wfdbx.internal.fgets_lines(sprintf('\n\nx'), 10), ...
    {char(10), char(10), 'x'}, 'fgets_lines blank lines');
end
