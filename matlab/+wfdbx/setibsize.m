function n = setibsize(n)
%SETIBSIZE Set the size of the input buffers.
%   N = wfdbx.setibsize(N) sets the default input buffer size (bytes; 0
%   for the default, 8192).  Must be called before isigopen.  Returns the
%   size set, or -1 (signals already open) or -2 (N < 0).
%
%   See also wfdbx.setobsize, wfdbx.isigopen.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
if S.nisig
    wfdbx.internal.wfdb_error('setibsize: can''t change buffer size after isigopen\n');
    n = -1;
    return;
end
if n < 0
    wfdbx.internal.wfdb_error('setibsize: illegal buffer size %d\n', n);
    n = -2;
    return;
end
if n == 0
    n = 8192;
end
S.ibsize = n;
end
