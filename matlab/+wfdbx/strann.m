function code = strann(s)
%STRANN Convert a mnemonic string to an annotation code.
%   CODE = wfdbx.strann(S) returns the annotation code (1 to 49) whose
%   mnemonic (wfdbx.annstr) is S, or 0 (NOTQRS) if there is none.
%
%   See also wfdbx.annstr, wfdbx.setannstr.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if ~ischar(s)
    s = '';
end
st = wfdbx.internal.annstate();
t = st.astring;
for code = 1:ACMAX
    if strcmp(s, t{code+1})
        return;
    end
end
code = 0;
end
