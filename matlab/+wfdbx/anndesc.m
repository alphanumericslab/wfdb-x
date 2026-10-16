function s = anndesc(code)
%ANNDESC Description of an annotation code.
%   S = wfdbx.anndesc(CODE) returns the description of annotation code
%   CODE (0 to 49), e.g. 'Normal beat'; [] (NULL) if it has none, or
%   'illegal annotation code' for other codes.
%
%   See also wfdbx.setanndesc, wfdbx.annstr.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if code >= 0 && code <= ACMAX
    st = wfdbx.internal.annstate();
    s = st.tstring{code+1};
else
    s = 'illegal annotation code';
end
end
