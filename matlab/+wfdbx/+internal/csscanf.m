function [n, vals] = csscanf(s, fmt)
%CSSCANF Emulate the C function sscanf().
%   [N, VALS] = wfdbx.internal.csscanf(S, FMT) scans the char vector S
%   according to the C format FMT, which may contain the conversions %d %i
%   %u %x %X %o (integers), %f %e %g %E %G %a (floating point), %s, %c (with
%   optional width, and * to suppress assignment), %%, white space (which
%   matches any amount of white space) and other characters (which must
%   match).  Length modifiers (h, l, ll, L, ...) are accepted and ignored.
%
%   N is the C return value: the number of assigned conversions, or -1 (EOF)
%   if the input ended before the first conversion.  VALS is a cell row of
%   the N converted values (doubles for numeric conversions, char vectors
%   for %s and %c), in order.  As in C, the variables whose conversions
%   failed keep their previous ("stale") values: callers assign only the
%   first N of their variables, e.g.
%
%       [n, v] = wfdbx.internal.csscanf(line, '%lf');
%       if n == 1, x = v{1}; end      % otherwise x is unchanged
%
%   FMT uses MATLAB char syntax: write sprintf-style escapes such as \t as
%   actual characters (white space in FMT is any of space, \t, \n, ...).
%   Parsed formats are cached.
%
%   See also wfdbx.internal.strtol, wfdbx.internal.strtod.
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

persistent keys items nk
if isempty(nk)
    keys = cell(1, 64);
    items = cell(1, 64);
    nk = 0;
end
k = find(strcmp(fmt, keys), 1);
if isempty(k)
    it = parse_format(fmt);
    if nk == numel(keys)
        nk = 0;
        keys(:) = {[]};
    end
    nk = nk + 1;
    keys{nk} = fmt;
    items{nk} = it;
else
    it = items{k};
end

vals = {};
nconv = 0;
i = 1;
ns = numel(s);
eof_first = false;
kinds = it.kind;
for q = 1:numel(kinds)
    kind = kinds(q);
    if kind == 2                % white space in the format
        while i <= ns && (s(i) == ' ' || (s(i) >= 9 && s(i) <= 13))   % isspace
            i = i + 1;
        end
        continue;
    elseif kind == 3            % ordinary character
        if i <= ns && s(i) == it.ch(q)
            i = i + 1;
            continue;
        end
        if i > ns && nconv == 0
            eof_first = true;
        end
        break;
    elseif kind == 4            % %%
        while i <= ns && (s(i) == ' ' || (s(i) >= 9 && s(i) <= 13))   % isspace
            i = i + 1;
        end
        if i <= ns && s(i) == '%'
            i = i + 1;
            continue;
        end
        break;
    elseif kind == 0            % unsupported conversion: stop
        break;
    end
    conv = it.ch(q);
    width = it.width(q);
    if conv ~= 'c' && conv ~= '['
        while i <= ns && (s(i) == ' ' || (s(i) >= 9 && s(i) <= 13))   % isspace
            i = i + 1;
        end
    end
    if i > ns
        if nconv == 0 && isempty(vals)
            eof_first = true;
        end
        break;
    end
    if width > 0
        sub = s(i:min(ns, i + width - 1));
    else
        sub = s(i:ns);
    end
    switch conv
        case {'d', 'u'}
            [v, e] = wfdbx.internal.strtol(sub, 10);
            if e == 1, break; end
            i = i + e - 1;
        case 'i'
            [v, e] = wfdbx.internal.strtol(sub, 0);
            if e == 1, break; end
            i = i + e - 1;
        case 'o'
            [v, e] = wfdbx.internal.strtol(sub, 8);
            if e == 1, break; end
            i = i + e - 1;
        case {'x', 'X'}
            [v, e] = wfdbx.internal.strtol(sub, 16);
            if e == 1, break; end
            i = i + e - 1;
        case {'e', 'E', 'f', 'F', 'g', 'G', 'a', 'A'}
            [v, e] = wfdbx.internal.strtod(sub);
            if e == 1, break; end
            i = i + e - 1;
        case 's'
            j = find(sub == ' ' | (sub >= 9 & sub <= 13), 1);   % isspace
            if isempty(j)
                v = sub;
            else
                v = sub(1:j-1);
            end
            i = i + numel(v);
        case 'c'
            w = max(width, 1);
            if numel(sub) < w, break; end
            v = sub(1:w);
            i = i + w;
        otherwise
            break;
    end
    if ~it.suppress(q)
        nconv = nconv + 1;
        vals{nconv} = v; %#ok<AGROW>
    end
end
if eof_first && nconv == 0
    n = -1;
else
    n = nconv;
end
end

function it = parse_format(fmt)
% kind: 1 conversion, 2 white space, 3 ordinary character, 4 %%,
% 0 unparseable conversion (scanning stops there).
nf = numel(fmt);
kind = zeros(1, nf);
ch = char(zeros(1, nf));
width = zeros(1, nf);
suppress = false(1, nf);
m = 0;
pos = 1;
while pos <= nf
    c = fmt(pos);
    m = m + 1;
    if c == '%'
        p = pos + 1;
        sup = p <= nf && fmt(p) == '*';
        if sup, p = p + 1; end
        w = 0;
        while p <= nf && fmt(p) >= '0' && fmt(p) <= '9'
            w = w * 10 + (fmt(p) - 48);   % '0' is 48
            p = p + 1;
        end
        while p <= nf && any(fmt(p) == 'hlLqjzt')
            p = p + 1;
        end
        if p > nf || ~any(fmt(p) == 'diouxXeEfFgGaAsc%[')
            kind(m) = 0;
            break;
        end
        if fmt(p) == '%'
            kind(m) = 4;
        else
            kind(m) = 1;
            ch(m) = fmt(p);
            width(m) = w;
            suppress(m) = sup;
        end
        pos = p + 1;
    elseif c == ' ' || (c >= 9 && c <= 13)   % isspace
        kind(m) = 2;
        pos = pos + 1;
    else
        kind(m) = 3;
        ch(m) = c;
        pos = pos + 1;
    end
end
it.kind = kind(1:m);
it.ch = ch(1:m);
it.width = width(1:m);
it.suppress = suppress(1:m);
end
