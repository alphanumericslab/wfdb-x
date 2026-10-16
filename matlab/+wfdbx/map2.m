function y = map2(a)
%MAP2 Map an annotation code into NOTQRS, NORMAL, SVPB, PVC, FUSION, LEARN.
%   Y = wfdbx.map2(A) returns the code to which the annotation code A is
%   mapped (NOTQRS for invalid codes).
%
%   See also wfdbx.ecgcodes, wfdbx.setmap2.

% Copyright (C) 1999 George B. Moody (original C header, lib/ecgmap.h).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if a > 0 && a <= ACMAX
    m = wfdbx.internal.ecgmap();
    y = m.mp2(a + 1);
else
    y = 0;
end
end
