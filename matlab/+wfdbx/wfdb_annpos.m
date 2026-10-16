function y = wfdb_annpos(a)
%WFDB_ANNPOS The position code of an annotation code.
%   Y = wfdbx.wfdb_annpos(A) is the same as wfdbx.annpos(A): the
%   function version of the ecgmap.h macro, under the name the C library
%   gives it.
%
%   See also wfdbx.annpos.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = wfdbx.annpos(a);
end
