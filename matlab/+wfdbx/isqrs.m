function y = isqrs(a)
%ISQRS True (1) if an annotation code denotes a QRS complex.
%   Y = wfdbx.isqrs(A) returns 1 if the annotation code A denotes a QRS
%   complex, 0 otherwise (and for invalid codes).
%
%   See also wfdbx.ecgcodes, wfdbx.setisqrs.

% Copyright (C) 1999 George B. Moody (original C header, lib/ecgmap.h).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if a > 0 && a <= ACMAX
    m = wfdbx.internal.ecgmap();
    y = m.qrs(a + 1);
else
    y = 0;
end
end
