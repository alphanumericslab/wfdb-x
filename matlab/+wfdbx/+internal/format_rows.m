function txt = format_rows(V, pre, width, prec, dash)
%FORMAT_ROWS Print the rows of a matrix of numbers as C printf does.
%   TXT = wfdbx.internal.format_rows(V, PRE, WIDTH, PREC) returns the text
%   that sprintf(FMT, V.') writes for the format FMT made of, for each
%   column k of V, the literal text PRE{k} and the conversion %Wd (PREC(k)
%   < 0) or %W.Pf (P = PREC(k)), W = WIDTH(k) (0: no width), and a newline
%   at the end of each row.  The digits are computed with vector
%   operations on whole columns, much faster than sprintf for many rows.
%
%   TXT = wfdbx.internal.format_rows(V, PRE, WIDTH, PREC, DASH) prints the
%   elements of V where the logical matrix DASH is true as "-" (as %Ws),
%   whatever their value.
%
%   TXT is [] if the values cannot be printed this way (another non-finite
%   value, a non-integer for %d, a magnitude of 2^52 or more after scaling,
%   or a value whose rounding to P decimals cannot be decided from its
%   double scaled by 10^P): the caller then uses sprintf.  Numbers are
%   printed as C does: %d of -0 is "0"; %.Pf of a negative number (or of
%   -0) has a minus sign even if it rounds to zero.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

txt = [];
[m, q] = size(V);
if nargin < 5 || isempty(dash)
    dash = false(m, q);
end
sp = repmat(' ', m, 1);     % a column of blanks
cols = cell(1, 0);      % the blocks of columns of the lines (char)
nc = 0;                 % (their number of columns)
signs = cell(1, q);     % (the column of each minus sign)
fields = zeros(2, q);   % the first and last column of each field
lens = cell(1, q);      % (the length of each field, if they vary)
vary = false;
for k = 1:q
    x = V(:, k);
    dk = dash(:, k);
    if any(dk)
        x(dk) = 0;
    end
    if ~all(isfinite(x))
        return;
    end
    p = prec(k);
    if p < 0
        if any(x ~= fix(x))
            return;
        end
        a = abs(x);
        neg = x < 0;
        p = 0;
    else
        a = abs(x * 10 ^ p);
        r = round(a);
        if any(abs(abs(a - r) - 0.5) <= a * 2 ^ -50)     % (4 eps(a) or more)
            return;     % (too close to a half: the exact value decides)
        end
        a = r;
        neg = x < 0 | (x == 0 & 1 ./ x < 0);    % (-0 too)
    end
    if any(a >= 4503599627370496)   % 2^52
        return;
    end
    [F, len] = render(a, neg, p, sp);
    F = [F{:}];
    if any(dk)
        len(dk) = 1;
    end
    w = width(k);
    lmax = max([len; 0]);
    F = F(:, size(F, 2) - lmax + 1:end);
    if lmax <= w
        % (every field has the width w)
        F = [repmat(' ', m, w - lmax), F]; %#ok<AGROW>
    elseif ~all(len == lmax)
        lens{k} = max(len, w);
        vary = true;
    end
    if ~isempty(pre{k})
        cols{end + 1} = repmat(pre{k}, m, 1); %#ok<AGROW>
        nc = nc + numel(pre{k});
    end
    fields(:, k) = nc + [1; size(F, 2)];
    cols{end + 1} = F; %#ok<AGROW>
    nc = nc + size(F, 2);
    if any(neg)
        r = find(neg);
        signs{k} = r + m * (fields(2, k) - len(r));
    end
    if any(dk)
        signs{k} = [signs{k}; find(dk) + m * (fields(2, k) - 1)];
    end
end
cols{end + 1} = repmat(char(10), m, 1);
M = [cols{:}];
for k = 1:q
    dk = dash(:, k);
    if any(dk)
        M(dk, fields(1, k):fields(2, k)) = ' ';
    end
    M(signs{k}) = '-';
end
txt = reshape(M.', 1, []);
if vary
    % remove the blanks before the fields shorter than their block
    keep = true(size(M));
    for k = 1:q
        if ~isempty(lens{k})
            f = fields(:, k);
            keep(:, f(1):f(2)) = (1:f(2) - f(1) + 1) > f(2) - f(1) + 1 - lens{k};
        end
    end
    keep = keep.';
    txt = txt(keep(:).');
end
end

function [F, len] = render(a, neg, p, sp)
% The numbers A (non-negative integers, to be printed with P decimals:
% A / 10^P), right-aligned: F, a cell row of char blocks (a blank column
% first, for the sign).  LEN: the length of each, minus sign included where
% NEG.  The digits are taken three at a time from tables.
persistent Z TB NDB
if isempty(Z)
    Z = cell(1, 3);     % Z{n}: the n-digit numbers, with leading zeros
    for n = 1:3
        Z{n} = reshape(sprintf(sprintf('%%0%dd', n), 0:10 ^ n - 1), n, []).';
    end
    % rows 1-1000: 000-999; 1001-2000: the same without leading zeros;
    % 2001: blank
    TB = [Z{3}; reshape(sprintf('%3d', 0:999), 3, []).'; '   '];
    NDB = [3 * ones(1000, 1); 1 + ((0:999)' >= 10) + ((0:999)' >= 100); 0];
end
fr = cell(1, 0);        % the decimals, in groups of at most 3
k = p;
while k > 0
    n = min(3, k);
    d = 10 ^ n;
    q = floor(a / d);
    fr = [{Z{n}(a - d * q + 1, :)}, fr]; %#ok<AGROW>
    a = q;
    k = k - n;
end
ig = cell(1, 0);        % the integer part, in groups of 3
ndig = 0;
first = true;
while true
    q = floor(a / 1000);
    idx = a - 1000 * q + 1 + 1000 * (q == 0);
    if ~first
        idx(a == 0) = 2001;
    end
    ig = [{TB(idx, :)}, ig]; %#ok<AGROW>
    ndig = ndig + NDB(idx);
    a = q;
    first = false;
    if ~any(q)
        break;
    end
end
if p > 0
    F = [{sp}, ig, {repmat('.', numel(sp), 1)}, fr];
else
    F = [{sp}, ig];
end
len = ndig + p + (p > 0) + neg;
end
