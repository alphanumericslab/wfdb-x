function y = mamap(a, s)
%MAMAP Map an MIT annotation code into an AHA annotation code.
%   Y = wfdbx.mamap(A, S) returns the AHA annotation code (a character
%   code, as a double) of the MIT annotation code A with subtype S.
%   Invalid codes map to double('O').
%
%   See also wfdbx.ammap.

% Copyright (C) 1999 George B. Moody (original C header, lib/ecgmap.h).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
persistent t
if isempty(t)
    t = double('ONNNNVFNNNENPQUOOOOOOOOOONOOOOQO[]NNOONOOROOOOOOOO');     % codes 0 to ACMAX
end
if a > 0 && a <= ACMAX
    y = t(a + 1);
    if y == 'U' && s ~= -1
        y = double('O');
    end
else
    y = double('O');
end
end
