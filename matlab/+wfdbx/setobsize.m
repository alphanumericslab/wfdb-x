function n = setobsize(n)
%SETOBSIZE Set the size of the output buffers.
%   N = wfdbx.setobsize(N) sets the default output buffer size (bytes; 0
%   for the default, 8192).  Must be called before osigopen/osigfopen.
%   Returns the size set, or -1 (signals already open) or -2 (N < 0).
%
%   See also wfdbx.setibsize, wfdbx.osigopen.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
if S.nosig
    wfdbx.internal.wfdb_error('setobsize: can''t change buffer size after osig[f]open\n');
    n = -1;
    return;
end
if n < 0
    wfdbx.internal.wfdb_error('setobsize: illegal buffer size %d\n', n);
    n = -2;
    return;
end
if n == 0
    n = 8192;
end
S.obsize = n;
end
