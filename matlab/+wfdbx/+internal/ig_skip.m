function ig_skip(ig, nb)
%IG_SKIP Skip NB bytes of an input signal group (a loop of r8() in isgsetframe).
%   wfdbx.internal.ig_skip(IG, NB) consumes NB bytes from the input group
%   IG as NB calls of r8() would, stopping early (after one more byte) if
%   the end of the file is reached (IG.stat <= 0).  The caller sets
%   IG.bp = IG.be = 0 and IG.stat = 1 first, as C does.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
        if isempty(ig.fp)
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
