function t = fstrtim(string, f)
%FSTRTIM Convert a time string to sample intervals at F Hz (fstrtim in signal.c).
%   T = wfdbx.internal.fstrtim(STRING, F); see wfdbx.strtim.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody, who contributed this
% function in 2011).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
i = 1;
n = numel(string);
while i <= n && any(string(i) == sprintf(' \t\n\r'))
    i = i + 1;
end
string = string(i:end);
if isempty(string)
    c = char(0);
else
    c = string(1);
end
switch c
    case 'c'
        if S.cfreq > 0
            t = wfdbx.internal.d2l((wfdbx.internal.strtod(string, 2) - S.bcount) * f / S.cfreq);
        else
            t = wfdbx.internal.strtol(string, 10, 2);
        end
    case 'e'
        if S.in_msrec
            t = S.msnsamples;
        else
            t = S.nsamples;
        end
        if bitand(S.gvmode, 1) == 1     % WFDB_HIGHRES
            t = t * S.spfmax;
        end
    case 'f'
        t = wfdbx.internal.d2l(wfdbx.internal.strtol(string, 10, 2) * f / S.ffreq);
    case 'i'
        if S.ifreq > 0
            a = S.ifreq / S.sfreq;
        else
            a = 1;
        end
        if bitand(S.gvmode, 1) == 1     % WFDB_HIGHRES
            b = S.ispfmax;
        else
            b = 1;
        end
        t = wfdbx.internal.d2l(S.istime * a * b);
    case 'o'
        t = S.ostime;
    case 's'
        t = wfdbx.internal.strtol(string, 10, 2);
    case '['
        string = string(2:end);
        q = find(string == ']', 1);
        if isempty(q)
            t = 0;
            return;
        end
        p = find(string == ' ', 1);
        if isempty(p) || p > q
            days = 0;
        else
            r = find(string(p + 1:end) == '/', 1);
            if isempty(r) || p + r > q
                days = wfdbx.internal.strtol(string, 10, p + 1);
            else
                days = wfdbx.strdat(string(p + 1:end)) - S.bdate;
            end
        end
        x = wfdbx.internal.fstrtim(string, 1000) - S.btime;
        if x < -2^63        % (a WFDB_Time difference, which wraps around in C)
            x = x + 2^64;
        elseif x >= 2^63
            x = x - 2^64;
        end
        if days > 0
            x = x + days * (24 * 60 * 60 * 1000);
        end
        t = wfdbx.internal.d2l(x * f / 1000 + 0.5);
        if t ~= -2^63       % (in C, -LONG_MIN is LONG_MIN)
            t = -t;
        end
    otherwise
        x = wfdbx.internal.strtod(string);
        p = find(string == ':', 1);
        if isempty(p)
            t = wfdbx.internal.d2l(x * f + 0.5);
            return;
        end
        y = wfdbx.internal.strtod(string, p + 1);
        p2 = find(string(p + 1:end) == ':', 1);
        if isempty(p2)
            t = wfdbx.internal.d2l((60 * x + y) * f + 0.5);
            return;
        end
        z = wfdbx.internal.strtod(string, p + p2 + 1);
        t = wfdbx.internal.d2l((3600 * x + 60 * y + z) * f + 0.5);
end
end
