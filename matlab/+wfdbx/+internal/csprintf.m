function s = csprintf(fmt, varargin)
%CSPRINTF Format data as the C function sprintf() does (glibc).
%   S = wfdbx.internal.csprintf(FMT, A1, A2, ...) returns the char vector
%   that C sprintf() writes for the format FMT and the arguments A1, A2, ...
%   (one argument per conversion, plus one per '*' width or precision).
%
%   Supported conversions: %d %i %u %x %X %o %c %s %e %E %f %F %g %G %%,
%   with the flags - + space # 0, a field width and a precision (either may
%   be '*'), and the length modifiers hh h l ll L q j z t.  The results are
%   those of glibc on x86-64:
%     * numbers are doubles (or other numeric/logical scalars); integer
%       conversions print integer values (non-integers are truncated toward
%       zero, NaN prints as INT_MIN);
%     * %u, %x and %o print the C unsigned value: negative numbers are
%       taken modulo 2^32 (2^64 with l or ll, 2^16 with h, 2^8 with hh), and
%       %hd and %hhd wrap to a short or a char;
%     * %c prints one byte (a number is taken modulo 256; a char prints its
%       first character); %s prints a char vector, or "(null)" for [] (C
%       NULL);
%     * infinities and NaNs print as inf, -inf, nan or -nan (INF, NAN for
%       upper-case conversions), the sign of a NaN being its sign bit (0/0
%       computed at run time is -nan, as in C on x86; the constant NaN is
%       nan);
%     * %ld and %lld print the same as %d.
%
%   FMT is written as in C source code: escape sequences such as \n, \t, \r
%   and \\ in it are interpreted (as MATLAB sprintf does).  Text that is not
%   part of the format (file names, descriptions, ...) must therefore be
%   passed as an argument of %s, never inside FMT.
%
%   Parsed formats are cached, and when all arguments are ordinary values
%   (finite double scalars, integer values for integer conversions,
%   non-empty char vectors), the result is produced by a single call of
%   sprintf.  (A char vector is printed whole even if it contains a NUL
%   character, unlike C.)  For large outputs, format whole arrays with one
%   sprintf call instead (see matlab/DEVELOPING.md).
%
%   See also wfdbx.internal.cprintf, wfdbx.internal.cout, sprintf.
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

persistent keys specs nk lastfmt lastp
if isempty(nk)
    keys = cell(1, 256);
    specs = cell(1, 256);
    nk = 0;
    lastfmt = [];
    lastp = [];
end
if ischar(lastfmt) && strcmp(fmt, lastfmt)
    p = lastp;
else
    k = find(strcmp(fmt, keys), 1);
    if isempty(k)
        p = parse_format(fmt);
        if nk == numel(keys)
            nk = 0;
            keys(:) = {[]};
        end
        nk = nk + 1;
        keys{nk} = fmt;
        specs{nk} = p;
    else
        p = specs{k};
    end
    lastfmt = fmt;
    lastp = p;
end

% Fast path: one call of sprintf when every argument is ordinary.
if p.fast && numel(varargin) == p.nargs
    if p.hasnum
        try
            x = [varargin{p.numidx}];
        catch
            x = [];
        end
        % finite values, and integers for the integer conversions
        % (NaN * 0 is NaN, so that non-finite values fail the test)
        ok = numel(x) == p.nnum && isa(x, 'double') && ...
            sum(abs(x - fix(x)) .* p.intmask) == 0 && (~p.hasuns || ...
            (min(x(p.unssel)) >= 0 && max(x(p.unssel) - p.unslim) < 0));
    else
        ok = true;
    end
    if ok && p.hasstr
        a = varargin(p.stridx);
        ok = all(cellfun('isclass', a, 'char')) && ~any(cellfun('isempty', a));
    end
    if ok && p.haschr
        a = varargin(p.chridx);
        ok = all(cellfun('isclass', a, 'char')) && ...
            all(cellfun('prodofsize', a) == 1);
    end
    if ok
        s = sprintf(p.ffmt, varargin{:});
        return;
    end
end

% General path: one conversion at a time.
nc = numel(p.conv);
out = cell(1, 2 * nc + 1);
out{1} = p.lits{1};
ai = 0;
na = numel(varargin);
for k = 1:nc
    flags = p.flags{k};
    width = p.width(k);
    prec = p.prec(k);
    if width == -2
        ai = ai + 1;
        width = getint(varargin, ai, na);
        if width < 0
            flags = [flags '-']; %#ok<AGROW>
            width = -width;
        end
    end
    if prec == -2
        ai = ai + 1;
        prec = getint(varargin, ai, na);
        if prec < 0
            prec = -1;
        end
    end
    ai = ai + 1;
    if ai <= na
        x = varargin{ai};
    else
        x = 0;          % missing argument (undefined in C)
    end
    out{2*k} = convert(p.conv(k), p.lmod(k), flags, width, prec, x);
    out{2*k+1} = p.lits{k+1};
end
s = [out{:}];
end

function v = getint(args, ai, na)
if ai <= na
    v = fix(double(args{ai}(1)));
else
    v = 0;
end
end

function t = convert(conv, lmod, flags, width, prec, x)
% Format one argument.  lmod: 0 none, 1 h, 2 hh, 3 l/ll/L/q/j/z/t.
if ischar(x) && conv ~= 's'
    x = double(x);
elseif islogical(x)
    x = double(x);
end
switch conv
    case {'d', 'i'}
        if isempty(x)
            x = 0;
        end
        x = double(x(1));
        if ~isfinite(x)
            if lmod == 3
                x = -9223372036854775808;   % LONG_MIN
            else
                x = -2147483648;
            end
        end
        x = fix(x);
        if lmod == 1
            x = mod(x + 32768, 65536) - 32768;
        elseif lmod == 2
            x = mod(x + 128, 256) - 128;
        end
        if abs(x) >= 9007199254740992   % 2^53
            x = int64(x);
        end
        t = sprintf(spec(flags, width, prec, 'd'), x);
    case {'u', 'x', 'X', 'o'}
        if isempty(x)
            x = 0;
        end
        if isinteger(x) && x(1) >= 0
            x = x(1);
        else
            x = double(x(1));
            if ~isfinite(x)
                x = 0;
            end
            x = fix(x);
            if lmod == 0
                x = mod(x, 4294967296);
            elseif lmod == 1
                x = mod(x, 65536);
            elseif lmod == 2
                x = mod(x, 256);
            elseif x < 0
                % 2^64 + x, exactly
                x = intmax('uint64') - uint64(-x) + 1;
            elseif x >= 9007199254740992   % 2^53
                x = uint64(x);
            end
        end
        if conv == 'u'
            conv = 'd';
            if isinteger(x)
                conv = 'u';
            end
        end
        t = sprintf(spec(flags, width, prec, conv), x);
    case 'c'
        if ischar(x)
            if isempty(x)
                c = char(0);
            else
                c = x(1);
            end
        else
            if isempty(x)
                x = 0;
            end
            c = char(mod(fix(double(x(1))), 256));
        end
        t = pad(c, flags, width);
    case 's'
        if ischar(x)
            t = x(:)';
            if prec >= 0 && prec < numel(t)
                t = t(1:prec);
            end
        elseif isempty(x)
            if prec >= 0 && prec < 6
                t = '';
            else
                t = '(null)';
            end
        else
            t = char(x(:)');
            if prec >= 0 && prec < numel(t)
                t = t(1:prec);
            end
        end
        k = find(t == char(0), 1);     % a C string ends at its first NUL
        if ~isempty(k)
            t = t(1:k-1);
        end
        t = pad(t, flags, width);
    otherwise   % e E f F g G
        if isempty(x)
            x = 0;
        end
        x = double(x(1));
        if isfinite(x)
            if conv == 'F'
                conv = 'f';
            end
            t = sprintf(spec(flags, width, prec, conv), x);
        else
            if isnan(x)
                u = typecast(x, 'uint32');
                neg = u(2) >= 2147483648;
                t = 'nan';
            else
                neg = x < 0;
                t = 'inf';
            end
            if conv < 'a'
                t = upper(t);
            end
            if neg
                t = ['-' t];
            elseif any(flags == '+')
                t = ['+' t];
            elseif any(flags == ' ')
                t = [' ' t];
            end
            t = pad(t, flags, width);
        end
end
end

function sp = spec(flags, width, prec, conv)
sp = ['%' flags];
if width >= 0
    sp = [sp sprintf('%d', width)];
end
if prec >= 0
    sp = [sp '.' sprintf('%d', prec)];
end
sp = [sp conv];
end

function t = pad(t, flags, width)
n = width - numel(t);
if n > 0
    if any(flags == '-')
        t = [t blanks(n)];
    else
        t = [blanks(n) t];
    end
end
end

function p = parse_format(fmt)
% Split FMT into literal text and conversion specifications.
nf = numel(fmt);
lits = {};
conv = '';
lmod = [];
flagsc = {};
width = [];
prec = [];
ffmt = '';          % format for the fast path
fast = true;
kinds = [];         % per argument: 1 int, 2 unsigned, 4 float, 5 string, 6 char
unslim = [];        % per unsigned argument: 2^32, or 2^53 with l/ll
lit = '';
pos = 1;
while pos <= nf
    j = find(fmt(pos:nf) == '%', 1);
    if isempty(j)
        lit = [lit fmt(pos:nf)]; %#ok<AGROW>
        ffmt = [ffmt fmt(pos:nf)]; %#ok<AGROW>
        break;
    end
    j = pos + j - 1;
    lit = [lit fmt(pos:j-1)]; %#ok<AGROW>
    ffmt = [ffmt fmt(pos:j-1)]; %#ok<AGROW>
    q = j + 1;
    if q <= nf && fmt(q) == '%'
        lit = [lit '%%']; %#ok<AGROW>
        ffmt = [ffmt '%%']; %#ok<AGROW>
        pos = q + 1;
        continue;
    end
    f0 = q;
    while q <= nf && any(fmt(q) == '-+ #0')
        q = q + 1;
    end
    flags = fmt(f0:q-1);
    w = -1;
    if q <= nf && fmt(q) == '*'
        w = -2;
        q = q + 1;
    elseif q <= nf && fmt(q) >= '0' && fmt(q) <= '9'
        w = 0;
        while q <= nf && fmt(q) >= '0' && fmt(q) <= '9'
            w = w * 10 + (fmt(q) - 48);   % '0' is 48
            q = q + 1;
        end
    end
    pr = -1;
    if q <= nf && fmt(q) == '.'
        q = q + 1;
        if q <= nf && fmt(q) == '*'
            pr = -2;
            q = q + 1;
        else
            pr = 0;
            while q <= nf && fmt(q) >= '0' && fmt(q) <= '9'
                pr = pr * 10 + (fmt(q) - 48);   % '0' is 48
                q = q + 1;
            end
        end
    end
    lm = 0;
    while q <= nf && any(fmt(q) == 'hlLqjzt')
        if fmt(q) == 'h'
            lm = lm + 1;
        else
            lm = 3;
        end
        q = q + 1;
    end
    lm = min(lm, 3);
    if q > nf || ~any(fmt(q) == 'diuxXoceEfFgGs')
        % not a supported conversion: printed literally
        lit = [lit strrep(fmt(j:min(q, nf)), '%', '%%')]; %#ok<AGROW>
        ffmt = [ffmt strrep(fmt(j:min(q, nf)), '%', '%%')]; %#ok<AGROW>
        pos = q + 1;
        continue;
    end
    c = fmt(q);
    lits{end+1} = unescape(lit); %#ok<AGROW>
    lit = '';
    conv(end+1) = c; %#ok<AGROW>
    lmod(end+1) = lm; %#ok<AGROW>
    flagsc{end+1} = flags; %#ok<AGROW>
    width(end+1) = w; %#ok<AGROW>
    prec(end+1) = pr; %#ok<AGROW>
    if w == -2 || pr == -2 || lm == 1 || lm == 2
        fast = false;
    end
    sp = ['%' flags];
    if w >= 0
        sp = [sp sprintf('%d', w)]; %#ok<AGROW>
    end
    if pr >= 0
        sp = [sp '.' sprintf('%d', pr)]; %#ok<AGROW>
    end
    switch c
        case {'d', 'i'}
            kinds(end+1) = 1; %#ok<AGROW>
            sp = [sp 'd']; %#ok<AGROW>
        case {'u', 'x', 'X', 'o'}
            kinds(end+1) = 2; %#ok<AGROW>
            if lm == 3
                unslim(end+1) = 9007199254740992; %#ok<AGROW>
            else
                unslim(end+1) = 4294967296; %#ok<AGROW>
            end
            if c == 'u'
                sp = [sp 'd']; %#ok<AGROW>
            else
                sp = [sp c]; %#ok<AGROW>
            end
        case 's'
            kinds(end+1) = 5; %#ok<AGROW>
            sp = [sp 's']; %#ok<AGROW>
        case 'c'
            kinds(end+1) = 6; %#ok<AGROW>
            sp = [sp 'c']; %#ok<AGROW>
        otherwise
            kinds(end+1) = 4; %#ok<AGROW>
            if c == 'F'
                sp = [sp 'f']; %#ok<AGROW>
            else
                sp = [sp c]; %#ok<AGROW>
            end
    end
    ffmt = [ffmt sp]; %#ok<AGROW>
    pos = q + 1;
end
lits{end+1} = unescape(lit);
p.lits = lits;
p.conv = conv;
p.lmod = lmod;
p.flags = flagsc;
p.width = width;
p.prec = prec;
p.fast = fast;
p.ffmt = ffmt;
p.nargs = numel(kinds);
numsel = kinds <= 4;
p.numidx = find(numsel);
p.nnum = numel(p.numidx);
p.hasnum = any(numsel);
nk = kinds(numsel);
p.intsel = nk <= 2;
p.intmask = double(p.intsel);
p.hasint = any(p.intsel);
p.unssel = nk == 2;
p.hasuns = any(p.unssel);
p.unslim = unslim;
p.stridx = find(kinds == 5);
p.hasstr = ~isempty(p.stridx);
p.chridx = find(kinds == 6);
p.haschr = ~isempty(p.chridx);
end

function t = unescape(lit)
% Interpret the escape sequences of literal text (which contains no
% conversions, only %% for a percent sign).
if isempty(lit)
    t = '';
elseif any(lit == '\') || any(lit == '%')
    t = sprintf(lit);
else
    t = lit;
end
end
