function [v, stat, last] = getframes(n, minstat)
%GETFRAMES Read up to N sample vectors at once (fast).
%   [V, STAT] = wfdbx.getframes(N) is equivalent to calling wfdbx.getvec
%   up to N times, stopping at the first negative status: V has one row
%   per sample vector read (as returned by getvec) and one column per
%   signal (N may be Inf, to read to the end of the record); STAT is the
%   status of the first vector that could not be read
%   (a negative value), or the number of signals if all N were read.
%
%   [V, STAT] = wfdbx.getframes(N, MINSTAT) stops instead at the first
%   vector for which getvec returns less than MINSTAT (that vector is not
%   included in V), as a C loop "while (getvec(v) >= MINSTAT)" does.  (In
%   a variable-layout record, getvec returns a positive value smaller than
%   the number of signals in a segment that lacks some of them.)
%   If no input signals are open, V is empty and STAT is the value
%   returned by getvec (0, or -1).
%
%   [V, STAT, LAST] = wfdbx.getframes(...) also returns the sample vector
%   (1-by-NSIG) filled by the getvec call that stopped the reading ([] if
%   all N vectors were read, or if no input signals are open).  For a
%   checksum error (STAT -4) it is the last frame of the record, read
%   completely (WFDB-x; wfdbx.read_record returns it).
%
%   Whenever possible (signals in files of any format, including
%   multi-frequency records in both getvec modes, FLAC files and the
%   segments of multi-segment records, without skew or setifreq
%   resampling), many frames are decoded at once with vector operations,
%   which is much faster than calling getvec for each sample; the results
%   are always those of getvec.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       [n, si] = wfdbx.isigopen('100s', 2);
%       [x, stat] = wfdbx.getframes(1000);     % 1000-by-2 matrix
%
%   See also wfdbx.getvec, wfdbx.isigopen, wfdbx.isigsettime.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: this function is a WFDB-x addition: it reads
% many sample vectors at once, with the results of repeated getvec() calls.
%
% Original C code: lib/signal.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 2
    minstat = 0;
end
S = wfdbx.internal.sig_state();
nsig = max(S.nvsig, S.nisig);
if nsig == 0 || S.nisig == 0
    % no signals: getvec reads nothing (0, or -1 at the end of a record)
    stat = wfdbx.getvec();
    v = zeros(0, nsig);
    last = [];
    return;
end
parts = {};
got = 0;
stat = nsig;
last = [];
vec = zeros(1, max(nsig, 1));
acc = zeros(0, nsig);
nrows = 0;
io = wfdbx.internal.io_state();
while got < n
    % (read in blocks of at most 2^22 frames, so that N may be Inf)
    [blk, ok] = wfdbx.internal.bulk_frames(min(n - got, 4194304), minstat);
    if ok && ~isempty(blk)
        if nrows > 0
            parts{end + 1} = acc(1:nrows, :); %#ok<AGROW>
            nrows = 0;
        end
        % (getvec leaves the values after the nvsig signals unchanged)
        nb = size(blk, 2);
        vec(1:nb) = blk(end, :);
        if nb < nsig
            blk = [blk, repmat(vec(nb + 1:nsig), size(blk, 1), 1)]; %#ok<AGROW>
        end
        parts{end + 1} = blk(:, 1:nsig); %#ok<AGROW>
        got = got + size(blk, 1);
        continue;
    end
    io.capture_row = got;       % (for the messages kept by wfdb_error)
    [stat, vec] = wfdbx.getvec(vec);
    if stat < minstat || stat < 0
        last = vec(1:nsig);
        break;
    end
    if nrows == size(acc, 1)
        acc = [acc; zeros(max(16, nrows), nsig)]; %#ok<AGROW>
    end
    nrows = nrows + 1;
    acc(nrows, :) = vec(1:nsig);
    got = got + 1;
end
if nrows > 0
    parts{end + 1} = acc(1:nrows, :);
end
if isempty(parts)
    v = zeros(0, nsig);
elseif numel(parts) == 1
    v = parts{1};
else
    v = vertcat(parts{:});
end
end
