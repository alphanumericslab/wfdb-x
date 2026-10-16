function y = wfdb_setmap2(a, x)
%WFDB_SETMAP2 Change the map2 table entry of an annotation code.
%   Y = wfdbx.wfdb_setmap2(A, X) is the same as wfdbx.setmap2(A, X): the
%   function version of the ecgmap.h macro, under the name the C library
%   gives it.
%
%   See also wfdbx.setmap2.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = wfdbx.setmap2(a, x);
end
