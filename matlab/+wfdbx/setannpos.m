function y = setannpos(a, x)
%SETANNPOS Change the position code of an annotation code.
%   Y = wfdbx.setannpos(A, X) sets the entry of the annotation code A (1 to
%   49) to X (stored in a C char, i.e. wrapped to -128..127) and returns
%   the new entry; for an invalid code nothing is changed and 0 is
%   returned.
%
%   See also wfdbx.annpos.

% Copyright (C) 1999 George B. Moody (original C header, lib/ecgmap.h).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if a > 0 && a <= ACMAX
    m = wfdbx.internal.ecgmap();
    m.annp(a + 1) = mod(x + 128, 256) - 128;
    y = m.annp(a + 1);
else
    y = 0;
end
end
