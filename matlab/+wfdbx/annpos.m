function y = annpos(a)
%ANNPOS The position code of an annotation code.
%   Y = wfdbx.annpos(A) returns the annotation position code (APUNDEF,
%   APSTD, ...) of the annotation code A (APUNDEF for invalid codes).
%
%   See also wfdbx.ecgcodes, wfdbx.setannpos.

% Copyright (C) 1999 George B. Moody (original C header, lib/ecgmap.h).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if a > 0 && a <= ACMAX
    m = wfdbx.internal.ecgmap();
    y = m.annp(a + 1);
else
    y = 0;
end
end
