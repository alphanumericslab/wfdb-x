function [stat, A, ia] = ann_getbulk(ia, m, noaux, nofail)
%ANN_GETBULK Read many annotations from an input annotator structure.
%   [STAT, A, IA] = wfdbx.internal.ann_getbulk(IA, M, NOAUX, NOFAIL) is the
%   body of wfdbx.internal.getann_bulk (wfdb-x), after its checks, for the
%   input annotator structure IA, whose updated state is returned (see
%   getann_bulk for the arguments and results; wfdbx.internal.ann_sortfile
%   uses it too).

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

A = struct('time', zeros(1, 0), 'anntyp', zeros(1, 0), ...
    'subtyp', zeros(1, 0), 'chan', zeros(1, 0), 'num', zeros(1, 0), ...
    'aux', {cell(1, 0)});
stat = 0;
pre = [];
if m > 0 && ia.pann.anntyp ~= 0
    [stat, pre, ia] = wfdbx.internal.ann_get1(ia);
    m = m - 1;
end
if m <= 0 || ia.ateof ~= 0 || ia.P.aha
    % (AHA files: one annotation at a time)
    nb = 0;
    cap = 0;
    while m > 0
        if nofail && ia.pann.anntyp == 0 && ia.ateof ~= 0
            stat = 1;
            break;
        end
        [stat, a, ia] = wfdbx.internal.ann_get1(ia);
        if stat ~= 0
            break;
        end
        nb = nb + 1;
        if nb > cap
            cap = max(16, 2 * cap);
            A.time(cap) = 0;
            A.anntyp(cap) = 0;
            A.subtyp(cap) = 0;
            A.chan(cap) = 0;
            A.num(cap) = 0;
            A.aux{cap} = [];
        end
        A.time(nb) = a.time;
        A.anntyp(nb) = a.anntyp;
        A.subtyp(nb) = a.subtyp;
        A.chan(nb) = a.chan;
        A.num(nb) = a.num;
        A.aux{nb} = a.aux;
        m = m - 1;
    end
    A.time = A.time(1:nb);
    A.anntyp = A.anntyp(1:nb);
    A.subtyp = A.subtyp(1:nb);
    A.chan = A.chan(1:nb);
    A.num = A.num(1:nb);
    A.aux = A.aux(1:nb);
    if noaux
        A.aux = cell(1, 0);
    end
    A = prepend(A, pre, noaux);
    return;
end
P = ia.P;
N = P.N;
j0 = ia.k;
if P.eofend
    cmax = N - j0;
else
    cmax = N - j0 + 1;
end
c = min(m, cmax);           % number of successful calls (>= 1)
lastread = j0 + c;          % last annotation read (N + 1: end of file)
jr = j0 + 1:min(lastread, N);
% Fields: the current annotation, then annotations j0+1 .. j0+c-1.
ret = j0 + 1:j0 + c - 1;
cur = ia.ann;
tm = ia.tmul;
if isempty(ret)
    rt = zeros(1, 0);
else
    x = P.tt(ret) * tm;
    rt = fix(x);
    f = x - rt;
    rt = rt + (x >= 0 & f >= 0.5) - (x < 0 & f < -0.5);
    if any(abs(x) >= 2^53 | isnan(x))   % not exact: round as C does
        rt = wfdbx.internal.ann_round(x);
    end
end
A.time = [cur.time, rt];
A.anntyp = [cur.anntyp, P.typ(ret)];
A.subtyp = [cur.subtyp, P.sub(ret)];
A.chan = [cur.chan, P.chan(ret)];
A.num = [cur.num, P.num(ret)];
% The aux ring buffer: writes for the annotations read (jr), and the aux
% strings of the annotations returned, each taken after the next
% annotation has been read (C returns a pointer into the buffer).
buf = ia.buf;
index = ia.index;
tc = P.tokcnt;
tf = P.tokfirst;
hasw = jr(tc(jr) > 0);                      % annotations with writes
posrec = -ones(1, numel(jr));               % auxpos of each read
if noaux
    for j = reshape(hasw, 1, [])
        for q = tf(j):tf(j) + tc(j) - 1
            [buf, index, p] = wfdbx.internal.ann_auxput(buf, index, P, q);
        end
        posrec(j - j0) = p;
    end
else
    aux = cell(1, c);
    % steps at which an aux string is taken: j + 1 for returned j
    rr = ret(tc(ret) > 0);
    steps = rr + 1;
    if ia.auxpos >= 0
        steps = [j0 + 1, steps];
    end
    % (a row: a for loop runs once per column, and MATLAB's unique can
    % return a column, e.g. 0-by-1 for no elements, which would run the
    % loop once with an empty value)
    ev = reshape(unique([hasw(:); steps(:)]), 1, []);
    curpos = ia.auxpos;
    for s = ev
        if s <= N && s >= j0 + 1 && tc(s) > 0
            for q = tf(s):tf(s) + tc(s) - 1
                [buf, index, p] = wfdbx.internal.ann_auxput(buf, index, P, q);
            end
            posrec(s - j0) = p;
        end
        r = s - 1;                          % the returned annotation
        if r == j0
            if curpos >= 0
                aux{1} = wfdbx.internal.ann_auxget(buf, curpos);
            end
        elseif r <= j0 + c - 1 && tc(r) > 0
            aux{r - j0 + 1} = wfdbx.internal.ann_auxget(buf, posrec(r - j0));
        end
    end
    A.aux = aux;
end
ia.buf = buf;
ia.index = index;
% The state after the last read.
ia.prev_time = A.time(end);
if c >= 2
    ia.prev_tt = P.tt(j0 + c - 1);
else
    ia.prev_tt = ia.ann_tt;
end
kf = min(lastread, N);
if kf > j0
    ia.k = kf;
    ia.ann_tt = P.tt(kf);
    ia.ann.anntyp = P.typ(kf);
    ia.ann.subtyp = P.sub(kf);
    ia.ann.chan = P.chan(kf);
    ia.ann.num = P.num(kf);
    ia.ann.time = wfdbx.internal.ann_round(P.tt(kf) * tm);
    ia.auxpos = posrec(kf - j0);
end
if lastread > N
    ia.ateof = 1;
elseif lastread == N && P.eofend
    ia.ateof = -1;
end
if c < m
    if nofail
        stat = 1;
    else
        [stat, ~, ia] = wfdbx.internal.ann_get1(ia);     % fails
    end
end
A = prepend(A, pre, noaux);
end

function A = prepend(A, a, noaux)
if isempty(a)
    return;
end
A.time = [a.time, A.time];
A.anntyp = [a.anntyp, A.anntyp];
A.subtyp = [a.subtyp, A.subtyp];
A.chan = [a.chan, A.chan];
A.num = [a.num, A.num];
if ~noaux
    A.aux = [{a.aux}, A.aux];
end
end
