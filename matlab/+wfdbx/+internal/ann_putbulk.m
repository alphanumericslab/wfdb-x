function [stat, oa] = ann_putbulk(oa, n, A, idx)
%ANN_PUTBULK Encode many annotations into an output annotator structure.
%   [STAT, OA] = wfdbx.internal.ann_putbulk(OA, N, A, IDX) has exactly the
%   effect of wfdbx.internal.ann_putword(OA, N, a) for each annotation a
%   = A(k), k in IDX (a nonempty row of indices into the structure of rows
%   A; see wfdbx.internal.putann_bulk), for the output annotator structure
%   OA (number N, in messages), whose annotation table has been written.
%   STAT is the status of the last annotation (0 on success), or the
%   first negative status.  (wfdb-x: the body of putann_bulk, which
%   wfdbx.internal.ann_sortfile also uses.)
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

stat = 0;
t = A.time(idx);
pt = [oa.ann.time, t(1:end-1)];
d = t - pt;
if oa.stat ~= WFDB_WRITE || any(abs(d) > MAXSKIP) || ...
        any(t <= LONG_MIN | t >= LONG_MAX) || ...
        oa.file.is_std
    a = wfdbx.annotation();
    for k = reshape(idx, 1, [])
        a.time = A.time(k);
        a.anntyp = A.anntyp(k);
        a.subtyp = A.subtyp(k);
        a.chan = A.chan(k);
        a.num = A.num(k);
        a.aux = A.aux{k};
        [s, oa] = wfdbx.internal.ann_putword(oa, n, a);
        if stat == 0 || s < 0
            stat = s;
        end
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
for k = reshape(find(~cellfun('isempty', aux)), 1, [])
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
for q = reshape(k, 1, [])
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
last = idx(end);
a.time = A.time(last);
a.anntyp = A.anntyp(last);
a.subtyp = A.subtyp(last);
a.chan = A.chan(last);
a.num = A.num(last);
a.aux = A.aux{last};
oa.ann = a;
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

