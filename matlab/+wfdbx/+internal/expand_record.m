function r = expand_record(record)
%EXPAND_RECORD The record name as wfdb_open uses it.
%   R = wfdbx.internal.expand_record(RECORD) returns RECORD, except that a
%   name ending with '/' gets another copy of its final element
%   ('abc/123/' -> 'abc/123/123').  (wfdb-x: moved out of wfdb_open, for
%   wfdbx.internal.output_file.)

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

rlen = numel(record);
r = record;
if rlen > 1 && record(rlen) == '/'
    p = rlen;           % 1-based index of the final '/'
    q = p - 1;
    while q > 1
        if record(q) == '/'
            q = q + 1;
            break;
        end
        q = q - 1;
    end
    if q < p
        r = [record record(q:p-1)];
    end
end
end
