function y = wfdb_isqrs(a)
%WFDB_ISQRS True (1) if an annotation code denotes a QRS complex.
%   Y = wfdbx.wfdb_isqrs(A) is the same as wfdbx.isqrs(A): the
%   function version of the ecgmap.h macro, under the name the C library
%   gives it.
%
%   See also wfdbx.isqrs.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = wfdbx.isqrs(a);
end
