function [v, stat] = getframes(n, minstat)
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
%   Whenever possible (signals in files of any format, including
%   multi-frequency records in both getvec modes and FLAC files, without
%   skew, variable-layout segments or setifreq resampling), many frames
%   are decoded at once with vector operations, which is much faster than
%   calling getvec for each sample; the results are always those of
%   getvec.
%
%   Example:
%       [n, si] = wfdbx.isigopen('100s', 2);
%       [x, stat] = wfdbx.getframes(1000);     % 1000-by-2 matrix
%
%   See also wfdbx.getvec, wfdbx.isigopen, wfdbx.isigsettime.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if nargin < 2
    minstat = 0;
end
S = wfdbx.internal.sigstate();
nsig = max(S.nvsig, S.nisig);
if nsig == 0 || S.nisig == 0
    % no signals: getvec reads nothing (0, or -1 at the end of a record)
    [stat, v] = wfdbx.getvec();
    v = zeros(0, nsig);
    return;
end
parts = {};
got = 0;
stat = nsig;
vec = zeros(1, max(nsig, 1));
acc = zeros(0, nsig);
nrows = 0;
while got < n
    % (read in blocks of at most 2^20 frames, so that N may be Inf)
    [blk, ok] = wfdbx.internal.bulk_frames(min(n - got, 2^20));
    if ok && ~isempty(blk)
        if nrows > 0
            parts{end + 1} = acc(1:nrows, :); %#ok<AGROW>
            nrows = 0;
        end
        parts{end + 1} = blk; %#ok<AGROW>
        got = got + size(blk, 1);
        continue;
    end
    [stat, vec] = wfdbx.getvec(vec);
    if stat < minstat || stat < 0
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
else
    v = vertcat(parts{:});
end
end
