function s = annstr(code)
%ANNSTR Convert an annotation code to its mnemonic string.
%   S = wfdbx.annstr(CODE) returns the mnemonic of annotation code CODE
%   (0 to 49), as possibly redefined by wfdbx.setannstr or by the table of
%   an annotation file, or '[CODE]' for other codes.
%
%   See also wfdbx.strann, wfdbx.anndesc.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if code >= 0 && code <= ACMAX
    st = wfdbx.internal.annstate();
    s = st.astring{code+1};
else
    s = sprintf('[%d]', code);
end
end
