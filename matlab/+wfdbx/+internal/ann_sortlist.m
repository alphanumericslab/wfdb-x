function [order, in_order] = ann_sortlist(t, num, chan, legacy)
%ANN_SORTLIST The order of annotations in the annotation list of sortann.
%   [ORDER, IN_ORDER] = wfdbx.internal.ann_sortlist(T, NUM, CHAN) inserts
%   the annotations whose times, num and chan fields are the rows T, NUM
%   and CHAN, one after the other, in the doubly-linked list of sortann.c
%   (insert_ann, same algorithm), and returns the indices of the
%   annotations in list order.  The list is ordered by time, then num,
%   then chan; an annotation with the same time, num and chan as one
%   already in the list replaces it (the later one wins).  IN_ORDER is 1
%   if every annotation was appended at the end (the input was in order).
%
%   [ORDER, IN_ORDER] = wfdbx.internal.ann_sortlist(T, NUM, CHAN, true)
%   uses the original insertion, in which the list head (an all-zero
%   annotation) takes part in the comparisons: an out-of-order annotation
%   at time 0 (num 0, chan 0) then "replaces" the head and is never
%   output, and neither is anything inserted after it (input times 5, 0, 3
%   give 5 only; see docs/KNOWN_C_BEHAVIORS.md).  wfdb-x: by default (and
%   for LEGACY false), the head is never compared, so that such an
%   annotation is inserted at the beginning (5, 0, 3 give 0, 3, 5); the
%   sortann tool uses the original insertion in legacy mode only.
%   (wfdb-x: moved from the sortann tool into the library, as in the C
%   reference, for wfdbx.internal.ann_sortfile.)
%
%   Part of the translation of lib/annot.c (WFDB 10.7.0).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/annot.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: moved from the sortann program into the
% library; outside legacy mode the list head is never compared as an
% annotation, so that an out-of-order annotation at time 0 is no longer
% lost. Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md
% gives the reasons.
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

% Node 1 is the static list head (an all-zero annotation, which takes part
% in comparisons); node k + 1 is annotation k.
if nargin < 4
    legacy = false;
end
n = numel(t);
in_order = 1;
if n <= 1
    order = 1:n;
    return;
end
gt = t(2:end) > t(1:end-1) | (t(2:end) == t(1:end-1) & ...
    (num(2:end) > num(1:end-1) | (num(2:end) == num(1:end-1) & ...
    chan(2:end) > chan(1:end-1))));
if all(gt)
    order = 1:n;
    return;
end
in_order = 0;
T = [0, t];
M = [0, num];
C = [0, chan];
nxt = zeros(1, n + 1);
prv = zeros(1, n + 1);
% the appended prefix
f = find(~gt, 1);           % annotation f+1 is the first not appended
nxt(1:f) = 2:f+1;
prv(2:f+1) = 1:f;
lastp = f + 1;
for x = f+2:n+1
    la = lastp;
    tx = T(x); mx = M(x); cx = C(x);
    if la == 1 || tx > T(la) || (tx == T(la) && (mx > M(la) || ...
            (mx == M(la) && cx > C(la))))
        prv(x) = la;
        nxt(la) = x;
        lastp = x;
        nxt(x) = 0;
        continue;
    end
    ap = la;
    while ap ~= 0
        if ap == 1 && ~legacy   % wfdb-x: the head is not an annotation
            ap = 0;
            break;
        end
        ta = T(ap);
        if tx > ta || (tx == ta && (mx > M(ap) || (mx == M(ap) && cx >= C(ap))))
            break;
        end
        ap = prv(ap);
    end
    if ap == 0
        prv(x) = 0;
        nxt(x) = nxt(1);
        nxt(1) = x;
        prv(nxt(x)) = x;
    elseif tx == T(ap) && mx == M(ap) && cx == C(ap)
        prv(x) = prv(ap);
        if prv(x) ~= 0
            nxt(prv(x)) = x;
        end
        nxt(x) = nxt(ap);
        if nxt(x) ~= 0
            prv(nxt(x)) = x;
        else
            lastp = x;
        end
        % If ap was the first entry of the list but its 'prev' link does not
        % lead back to the list head (an entry inserted at the beginning
        % gets a null link, and one whose predecessor replaced the head is
        % detached), C leaves the head pointing to the freed entry
        % (undefined behavior): here the head is updated, so that the
        % duplicate is replaced (see docs/KNOWN_C_BEHAVIORS.md).
        if ap ~= 1 && nxt(1) == ap
            nxt(1) = x;
        end
    else
        prv(x) = ap;
        nxt(x) = nxt(ap);
        nxt(ap) = x;
        prv(nxt(x)) = x;
    end
end
order = zeros(1, n);
k = 0;
p = nxt(1);
while p ~= 0
    k = k + 1;
    order(k) = p - 1;
    p = nxt(p);
end
order = order(1:k);
end
