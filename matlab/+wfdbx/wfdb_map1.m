function y = wfdb_map1(a)
%WFDB_MAP1 Map an annotation code into NOTQRS, NORMAL, PVC, FUSION, LEARN.
%   Y = wfdbx.wfdb_map1(A) is the same as wfdbx.map1(A): the
%   function version of the ecgmap.h macro, under the name the C library
%   gives it.
%
%   See also wfdbx.map1.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = wfdbx.map1(a);
end
