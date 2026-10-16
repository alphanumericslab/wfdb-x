function y = wfdb_mamap(a, s)
%WFDB_MAMAP Map an MIT annotation code and subtype into an AHA code.
%   Y = wfdbx.wfdb_mamap(A, S) is the same as wfdbx.mamap(A, S): the
%   function version of the ecgmap.h macro, under the name the C library
%   gives it.
%
%   See also wfdbx.mamap.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = wfdbx.mamap(a, s);
end
