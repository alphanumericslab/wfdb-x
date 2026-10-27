function [v, e] = strtod(s, pos)
%STRTOD Emulate the C function strtod().
%   [V, E] = wfdbx.internal.strtod(S) parses a floating-point number at the
%   start of the char vector S as C strtod() does: leading white space is
%   skipped; decimal and hexadecimal forms, "inf", "infinity" and "nan" (in
%   any case, with an optional sign) are accepted.  V is the value and E the
%   index of the first character not consumed (1-based).  If no number was
%   found, V is 0 and E is POS.
%
%   [V, E] = wfdbx.internal.strtod(S, POS) starts parsing at index POS
%   (default 1).
%
%   See also wfdbx.internal.atof, wfdbx.internal.strtol.
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

persistent pat
if isempty(pat)
    pat = ['^[+-]?(?:' ...
        '0[xX](?:[0-9a-fA-F]+(?:\.[0-9a-fA-F]*)?|\.[0-9a-fA-F]+)(?:[pP][+-]?[0-9]+)?' ...
        '|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?' ...
        '|[iI][nN][fF](?:[iI][nN][iI][tT][yY])?' ...
        '|[nN][aA][nN](?:\([0-9A-Za-z_]*\))?)'];
end
if nargin < 2
    pos = 1;
end
n = numel(s);
i = pos;
while i <= n && (s(i) == ' ' || (s(i) >= 9 && s(i) <= 13))   % isspace
    i = i + 1;
end
if i > n
    v = 0;
    e = pos;
    return;
end
u = s(i:n);
u(u > 127) = char(127);     % (Octave's regexp rejects invalid UTF-8)
t = regexp(u, pat, 'match', 'once');
if isempty(t)
    v = 0;
    e = pos;
    return;
end
e = i + numel(t);
neg = t(1) == '-';
if t(1) == '-' || t(1) == '+'
    t = t(2:end);
end
c = t(1);
if numel(t) > 1 && c == '0' && (t(2) == 'x' || t(2) == 'X')
    h = lower(t(3:end));
    k = find(h == 'p', 1);
    if isempty(k)
        ex = 0;
    else
        ex = str2double(h(k+1:end));
        h = h(1:k-1);
    end
    k = find(h == '.', 1);
    if isempty(k)
        a = h;
        b = '';
    else
        a = h(1:k-1);
        b = h(k+1:end);
    end
    d = [a b];
    dv = double(d) - 48;   % digit values ('0' is 48)
    dv(dv > 9) = dv(dv > 9) - 39;       % 'a'-'f'
    m = 0;
    for j = 1:numel(dv)
        m = m * 16 + dv(j);
    end
    v = pow2(m, ex - 4 * numel(b));
elseif c == 'i' || c == 'I'
    v = Inf;
elseif c == 'n' || c == 'N'
    v = NaN;
else
    v = str2double(t);
    if isnan(v)         % out of range (Octave): as C, +-HUGE_VAL
        v = Inf;
    end
end
if neg
    v = -v;
end
end
