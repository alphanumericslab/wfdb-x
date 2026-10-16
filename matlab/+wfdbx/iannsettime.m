function stat = iannsettime(t)
%IANNSETTIME Skip input annotators to a given time.
%   STAT = wfdbx.iannsettime(T) positions all input annotators so that the
%   next annotation returned by wfdbx.getann is the first one at or after
%   time T (in sample intervals; a negative T other than the minimum time
%   is taken as -T, an absolute time from wfdbx.strtim).  STAT is 0 on
%   success, -1 if no annotator has annotations at or after T (or on an
%   improper seek).
%
%   See also wfdbx.getann, wfdbx.strtim.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.annstate();
stat = 0;
niavalid = numel(st.iad);
LONG_MIN = -9223372036854775808;   % (C: -t overflows)
if t < 0 && t ~= LONG_MIN
    t = -t;
end
for i = 1:numel(st.iad)
    ia = st.iad{i};
    if ia.ann.time >= t
        ia.pann.anntyp = 0;
        if ia.file.seek(0, 0) == -1
            wfdbx.internal.wfdb_error('iannsettime: improper seek\n');
            stat = -1;
            return;
        end
        ia.ann.subtyp = 0;
        ia.ann.chan = 0;
        ia.ann.num = 0;
        ia.ateof = 0;
        ia.ann.time = 0;
        ia.k = 0;                       % start of a new pass over the file
        [~, ~, ia] = wfdbx.internal.ann_get1(ia);
    end
    if ia.ann.time < t && ia.pann.anntyp ~= 0
        [stat, ~, ia] = wfdbx.internal.ann_get1(ia);    % the pushed-back one
    end
    st.iad{i} = ia;
    if ia.ann.time < t
        % getann until the current annotation is at or after t.
        m = inf;
        P = ia.P;
        if ia.ateof == 0
            x = P.tt(ia.k+1:end) * ia.tmul;
            c = find(wfdbx.internal.ann_round(x) >= t, 1);
            if ~isempty(c)
                m = c;
            end
        end
        stat = wfdbx.internal.getann_bulk(i - 1, m, true);
    end
    if stat < 0
        niavalid = niavalid - 1;
    end
end
if niavalid > 0
    stat = 0;
else
    stat = -1;
end
end
