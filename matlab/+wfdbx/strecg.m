function code = strecg(s)
%STRECG Convert a fixed mnemonic string to an annotation code.
%   CODE = wfdbx.strecg(S) returns the annotation code (1 to 49) whose
%   fixed mnemonic (wfdbx.ecgstr) is S, or 0 (NOTQRS) if there is none.
%
%   See also wfdbx.ecgstr.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if ~ischar(s)
    s = '';
end
st = wfdbx.internal.ann_state();
t = st.cstring;
for code = 1:ACMAX
    if strcmp(s, t{code+1})
        return;
    end
end
code = 0;
end
