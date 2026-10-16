function y = wfdb_map2(a)
%WFDB_MAP2 Map an annotation code into one of the classes of wfdbx.map2.
%   Y = wfdbx.wfdb_map2(A) is the same as wfdbx.map2(A): the
%   function version of the ecgmap.h macro, under the name the C library
%   gives it.
%
%   See also wfdbx.map2.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = wfdbx.map2(a);
end
