function [stat, annot] = getann(an, annot)
%GETANN Read the next annotation from an input annotator.
%   [STAT, ANNOT] = wfdbx.getann(AN) reads the next annotation from input
%   annotator AN (0 for the first annotator opened by wfdbx.annopen).
%   STAT is 0 on success, -1 at the end of the file, -2 if AN is not an
%   open input annotator, or -3 if the file ends unexpectedly.  ANNOT is a
%   wfdbx.annotation() structure (time, anntyp, subtyp, chan, num, aux).
%
%   [STAT, ANNOT] = wfdbx.getann(AN, ANNOT0) returns ANNOT0 unchanged when
%   no annotation is read (as the C function leaves its argument);
%   without ANNOT0, a zero annotation is returned then.
%
%   ANNOT.aux is [] or a uint8 row vector whose first element is the
%   length of the data that follows (as in C, the data may be followed by
%   stale bytes of the library's aux buffer, up to a null byte).
%
%   To read a whole annotation file into arrays, wfdbx.read_annotations
%   is much faster than calling getann in a loop.
%
%   Example:
%       wfdbx.annopen('100s', wfdbx.anninfo('atr', wfdbx.WFDB_READ()));
%       [stat, a] = wfdbx.getann(0);
%       while stat == 0
%           fprintf('%d %s\n', a.time, wfdbx.annstr(a.anntyp));
%           [stat, a] = wfdbx.getann(0);
%       end
%       wfdbx.wfdbquit();
%
%   See also wfdbx.annopen, wfdbx.ungetann, wfdbx.iannsettime,
%   wfdbx.read_annotations.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.ann_state();
if an < 0 || an >= numel(st.iad) || isempty(st.iad{an+1})
    wfdbx.internal.wfdb_error('getann: can''t read annotator %d\n', an);
    stat = -2;
    if nargin < 2
        annot = wfdbx.annotation();
    end
    return;
end
ia = st.iad{an+1};
P = ia.P;
j = ia.k + 1;
if ia.pann.anntyp == 0 && ia.ateof == 0 && ia.auxpos < 0 && j <= P.N && ...
        ~P.aha && P.tokcnt(j) == 0 && (j < P.N || ~P.eofend)
    % fast path (MIT format, no aux strings involved): inline ann_get1
    annot = ia.ann;
    ia.prev_time = annot.time;
    ia.prev_tt = ia.ann_tt;
    ia.k = j;
    tt = P.tt(j);
    ia.ann_tt = tt;
    ia.ann.anntyp = P.typ(j);
    ia.ann.subtyp = P.sub(j);
    ia.ann.chan = P.chan(j);
    ia.ann.num = P.num(j);
    x = tt * ia.tmul;
    if x >= 0 && x < 9007199254740992   % 2^53: exact, round here
        t = fix(x);
        ia.ann.time = t + (x - t >= 0.5);
    else
        ia.ann.time = wfdbx.internal.ann_round(x);
    end
    st.iad{an+1} = ia;
    stat = 0;
    return;
end
[stat, a, ia] = wfdbx.internal.ann_get1(ia);
st.iad{an+1} = ia;
if stat == 0
    annot = a;
elseif nargin < 2
    annot = wfdbx.annotation();
end
end
