function ig_skip(ig, nb)
%IG_SKIP Skip NB bytes of an input signal group (a loop of r8() in isgsetframe).
%   wfdbx.internal.ig_skip(IG, NB) consumes NB bytes from the input group
%   IG as NB calls of r8() would, stopping early (after one more byte) if
%   the end of the file is reached (IG.stat <= 0).  The caller sets
%   IG.bp = IG.be = 0 and IG.stat = 1 first, as C does.
%
%   Part of the translation of lib/signal.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: a refill takes the blocks read ahead by the
% bulk reader first. Each change is marked "wfdb-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
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

bp = ig.bp;
be = ig.be;
stat = ig.stat;
buf = ig.buf;
while nb > 0 && stat > 0
    if bp >= be
        n = ig.bsize;
        if n <= 0
            S = wfdbx.internal.sig_state();
            n = S.ibsize;
        end
        if ~isempty(ig.ahead)
            % wfdb-x: the next block read ahead by the bulk reader
            m = min(n, numel(ig.ahead));
            b = ig.ahead(1:m);
            ig.ahead = ig.ahead(m + 1:end);
        elseif isempty(ig.fp)
            b = zeros(1, 0, 'uint8');
        else
            b = ig.fp.read(n);
        end
        stat = numel(b);
        if stat > 0
            buf = b;
        end
        bp = 0;
        be = stat;
        if stat <= 0
            bp = bp + 1;
            nb = nb - 1;
            break;
        end
    end
    k = min(nb, be - bp);
    bp = bp + k;
    nb = nb - k;
end
ig.buf = buf;
ig.bp = bp;
ig.be = be;
ig.stat = stat;
end
