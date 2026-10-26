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

n = numel(A.time);
stat = 0;
if n == 0
    return;
end
st = wfdbx.internal.ann_state();
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
[s, oa] = wfdbx.internal.ann_putbulk(oa, an, A, first:n);
st.oad{an+1} = oa;
if stat == 0 || s < 0
    stat = s;
end
end

function stat = scalar(an, A, idx)
stat = 0;
a = wfdbx.annotation();
for k = reshape(idx, 1, [])
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
