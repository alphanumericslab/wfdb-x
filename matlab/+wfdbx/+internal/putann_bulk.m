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
%
%   Part of the translation of lib/annot.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/annot.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/annot.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

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
