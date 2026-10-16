function tf = isann(a)
%ISANN True if A is a legal annotation code (1 to ACMAX = 49).
%   TF = wfdbx.isann(A) returns true if 0 < A <= 49 (elementwise if A
%   is an array).
%
%   See also wfdbx.ecgcodes.

% Copyright (C) 1999 George B. Moody (original C header, lib/ecgmap.h).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
tf = a > 0 & a <= ACMAX;
end
