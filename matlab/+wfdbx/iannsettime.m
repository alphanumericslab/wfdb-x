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
%
%   Translation of the C function iannsettime() (lib/annot.c, WFDB 10.7.0):
%   same arguments and results.

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

st = wfdbx.internal.ann_state();
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
