function [v, e] = strtol(s, base, pos, lmin, lmax)
%STRTOL Emulate the C function strtol().
%   [V, E] = wfdbx.internal.strtol(S) parses a decimal integer at the start
%   of the char vector S as C strtol(S, &end, 10) does: leading white space
%   is skipped, an optional sign is accepted, and parsing stops at the
%   first character that is not a digit.  V is the value (a double) and E
%   is the index of the first character not consumed (1-based, i.e. the C
%   end pointer plus one).  If no number was found, V is 0 and E is POS.
%
%   [V, E] = wfdbx.internal.strtol(S, BASE, POS) parses in base BASE (0,
%   or 2 to 36; base 0 selects 8, 10 or 16 from the prefix as C does),
%   starting at index POS (default 1).
%
%   [V, E] = wfdbx.internal.strtol(S, BASE, POS, LMIN, LMAX) clamps the
%   result to [LMIN, LMAX] (default: the range of a 64-bit C long), as
%   strtol does on overflow.  Values beyond 2^53 are not exact.
%
%   See also wfdbx.internal.atoi, wfdbx.internal.strtod.
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

persistent dig
if isempty(dig)
    % digit value of each byte (99 = not a digit)
    dig = 99 * ones(1, 256);
    dig(49:58) = 0:9;           % '0'-'9'
    dig(98:123) = 10:35;        % 'a'-'z'
    dig(66:91) = 10:35;         % 'A'-'Z'
end
if nargin < 2 || isempty(base)
    base = 10;
end
if nargin < 3 || isempty(pos)
    pos = 1;
end
n = numel(s);
i = pos;
while i <= n && (s(i) == ' ' || (s(i) >= 9 && s(i) <= 13))   % isspace
    i = i + 1;
end
neg = false;
if i <= n && (s(i) == '+' || s(i) == '-')
    neg = s(i) == '-';
    i = i + 1;
end
if base == 0 || base == 16
    if i + 2 <= n && s(i) == '0' && (s(i+1) == 'x' || s(i+1) == 'X') && ...
            dig(double(s(i+2)) + 1) < 16
        base = 16;
        i = i + 2;
    elseif base == 0
        if i <= n && s(i) == '0'
            base = 8;
        else
            base = 10;
        end
    end
end
start = i;
v = 0;
while i <= n
    k2 = min(n, i + 31);
    d = dig(double(s(i:k2)) + 1);
    bad = find(d >= base, 1);
    if isempty(bad)
        cnt = k2 - i + 1;
    else
        cnt = bad - 1;
    end
    if cnt > 0
        v = v * base^cnt + d(1:cnt) * (base .^ (cnt-1:-1:0))';
        i = i + cnt;
    end
    if ~isempty(bad)
        break;
    end
end
if i == start
    v = 0;
    e = pos;
    return;
end
e = i;
if neg
    v = -v;
end
if nargin < 5
    lmax = 9223372036854775807;
    lmin = -9223372036854775808;
end
if v > lmax
    v = lmax;
elseif v < lmin
    v = lmin;
end
end
