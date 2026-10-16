function stat = putann_bulk(an, A)
%PUTANN_BULK Write many annotations at once (repeated putann).
%   STAT = wfdbx.internal.putann_bulk(AN, A) has exactly the effect of
%   calling wfdbx.putann(AN, a) for each annotation a of A, a structure of
%   rows time, anntyp, subtyp, chan, num and aux (a cell row of [] or
%   uint8 rows), as returned by wfdbx.internal.getann_bulk.  STAT is the
%   status of the last call (0 on success), or the first negative status.
%
%   MIT-format output is encoded with vector operations; AHA-format output
%   and rare cases (time gaps of 2^31 or more, overflowing times) are
%   written one annotation at a time.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

% Annotation words (see wfdbx.putann).
CODE1 = 1024;           % 1 << CS: code 1 in the code field
DATA = 1023;            % data field mask
MAXRR = DATA;           % longest interval that fits in the data field
SKIP = 59 * CODE1;
NUM = 60 * CODE1;
SUB = 61 * CODE1;
CHN = 62 * CODE1;
AUX = 63 * CODE1;
MAXSKIP = 2147483647;   % largest interval represented by one SKIP
OFLUSH = 65536;         % flush the output buffer beyond this many bytes
WFDB_WRITE = 1;
LONG_MIN = -9223372036854775808;
LONG_MAX = 9223372036854775807;
TWO16 = 65536;
TWO32 = 4294967296;

n = numel(A.time);
stat = 0;
if n == 0
    return;
end
st = wfdbx.internal.annstate();
if an < 0 || an >= numel(st.oad) || isempty(st.oad{an+1})
    stat = scalar(an, A, 1:n);
    return;
end
oa = st.oad{an+1};
first = 1;
if ~oa.table_written
    stat = scalar(an, A, 1);
    if n == 1
        return;
    end
    first = 2;
    oa = st.oad{an+1};
end
idx = first:n;
t = A.time(idx);
pt = [oa.ann.time, t(1:end-1)];
d = t - pt;
if oa.stat ~= WFDB_WRITE || any(abs(d) > MAXSKIP) || ...
        any(t <= LONG_MIN | t >= LONG_MAX) || ...
        oa.file.is_std
    s = scalar(an, A, idx);
    if stat == 0 || s < 0
        stat = s;
    end
    return;
end
m = numel(idx);
typ = A.anntyp(idx);
sub = A.subtyp(idx);
achan = mod(A.chan(idx), 256);
pchan = [mod(oa.ann.chan, 256), achan(1:end-1)];
anum = mod(A.num(idx) + 128, 256) - 128;
pnum = [mod(oa.ann.num + 128, 256) - 128, anum(1:end-1)];
if any(~(achan > pchan | anum > pnum | t > pt | (t == 0 & pt == 0)))
    oa.out_of_order = 1;
end
aux = A.aux(idx);
auxln = zeros(1, m);
for k = find(~cellfun('isempty', aux))
    auxln(k) = double(aux{k}(1));
end
z = typ == 0;
sk = z | d > MAXRR | d < 0;
skv = d;
skv(z) = d(z) - 1;
skv = mod(skv, TWO32);
dd = d;
dd(z) = 1;
dd(sk & ~z) = 0;
annwd = mod(dd + typ * CODE1, TWO16);
hs = sub ~= 0;
hc = achan ~= pchan;
hn = anum ~= pnum;
ha = auxln ~= 0;
auxb = auxln + mod(auxln, 2);
nw = 3 * sk + 1 + hs + hc + hn + ha;
nb = 2 * nw + auxb .* ha;
off = cumsum([0, nb(1:end-1)]);         % 0-based start of each segment
B = zeros(1, sum(nb));
p = off;                                % next free position
% SKIP
k = find(sk);
B = putw(B, p(k), SKIP * ones(1, numel(k)));
B = putw(B, p(k) + 2, floor(skv(k) / TWO16));
B = putw(B, p(k) + 4, mod(skv(k), TWO16));
p(k) = p(k) + 6;
B = putw(B, p, annwd);
p = p + 2;
k = find(hs);
B = putw(B, p(k), SUB + mod(sub(k), DATA + 1));
p(k) = p(k) + 2;
k = find(hc);
B = putw(B, p(k), CHN + achan(k));
p(k) = p(k) + 2;
k = find(hn);
B = putw(B, p(k), NUM + mod(anum(k), DATA + 1));
p(k) = p(k) + 2;
k = find(ha);
B = putw(B, p(k), AUX + auxln(k));
p(k) = p(k) + 2;
for q = k
    x = double(aux{q}(2:min(end, auxln(q) + 1)));
    B(p(q)+1:p(q)+numel(x)) = x;
end
nbytes = numel(B);
if oa.olen + nbytes > numel(oa.obuf)
    oa.obuf(oa.olen + nbytes) = 0;
end
oa.obuf(oa.olen+1:oa.olen+nbytes) = B;
oa.olen = oa.olen + nbytes;
if oa.olen >= OFLUSH
    oa = wfdbx.internal.ann_oflush(oa);
end
a = wfdbx.annotation();
a.time = A.time(n);
a.anntyp = A.anntyp(n);
a.subtyp = A.subtyp(n);
a.chan = A.chan(n);
a.num = A.num(n);
a.aux = A.aux{n};
oa.ann = a;
st.oad{an+1} = oa;
if oa.file.ferror()
    wfdbx.internal.wfdb_error( ...
        'putann: write error on annotation file %s\n', oa.name);
    stat = -1;
end
end

function B = putw(B, pos, w)
B(pos + 1) = mod(w, 256);
B(pos + 2) = floor(w / 256);
end

function stat = scalar(an, A, idx)
stat = 0;
a = wfdbx.annotation();
for k = idx
    a.time = A.time(k);
    a.anntyp = A.anntyp(k);
    a.subtyp = A.subtyp(k);
    a.chan = A.chan(k);
    a.num = A.num(k);
    a.aux = A.aux{k};
    s = wfdbx.putann(an, a);
    if stat == 0 || s < 0
        stat = s;
    end
end
end
