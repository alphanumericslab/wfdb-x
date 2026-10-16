function y = wfdb_isann(a)
%WFDB_ISANN True if A is a legal annotation code (1 to 49).
%   Y = wfdbx.wfdb_isann(A) is the same as wfdbx.isann(A): the
%   function version of the ecgmap.h macro, under the name the C library
%   gives it.
%
%   See also wfdbx.isann.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = wfdbx.isann(a);
end
