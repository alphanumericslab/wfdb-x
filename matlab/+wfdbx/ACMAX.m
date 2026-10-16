function v = ACMAX()
%ACMAX Value of the largest valid annotation code (49).
%   V = wfdbx.ACMAX() returns 49.
%   Annotation codes (lib/ecgcodes.h) are also available as fields of
%   the structure returned by wfdbx.ecgcodes(), which is faster in loops.
%
%   See also wfdbx.ecgcodes.

% Copyright (C) 1999 George B. Moody (original C header, lib/ecgcodes.h, by
% T. Baker and G. Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

v = 49;
end
