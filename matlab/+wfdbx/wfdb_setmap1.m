function y = wfdb_setmap1(a, x)
%WFDB_SETMAP1 Change the map1 table entry of an annotation code.
%   Y = wfdbx.wfdb_setmap1(A, X) is the same as wfdbx.setmap1(A, X): the
%   function version of the ecgmap.h macro, under the name the C library
%   gives it.
%
%   See also wfdbx.setmap1.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = wfdbx.setmap1(a, x);
end
