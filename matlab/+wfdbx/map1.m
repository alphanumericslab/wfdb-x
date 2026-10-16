function y = map1(a)
%MAP1 Map an annotation code into NOTQRS, NORMAL, PVC, FUSION or LEARN.
%   Y = wfdbx.map1(A) returns the code to which the annotation code A is
%   mapped (NOTQRS for invalid codes).
%
%   See also wfdbx.ecgcodes, wfdbx.setmap1.

% Copyright (C) 1999 George B. Moody (original C header, lib/ecgmap.h).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if a > 0 && a <= ACMAX
    m = wfdbx.internal.ecgmap();
    y = m.mp1(a + 1);
else
    y = 0;
end
end
