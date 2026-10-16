function y = wfdb_ammap(a)
%WFDB_AMMAP Map an AHA annotation code into an MIT annotation code.
%   Y = wfdbx.wfdb_ammap(A) is the same as wfdbx.ammap(A): the
%   function version of the ecgmap.h macro, under the name the C library
%   gives it.
%
%   See also wfdbx.ammap.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = wfdbx.ammap(a);
end
