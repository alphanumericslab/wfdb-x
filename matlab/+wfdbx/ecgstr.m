function s = ecgstr(code)
%ECGSTR Convert an annotation code to a fixed mnemonic string.
%   S = wfdbx.ecgstr(CODE) returns the fixed mnemonic of annotation code
%   CODE (0 to 49; not changed by wfdbx.setannstr), or '[CODE]' for other
%   codes.
%
%   See also wfdbx.strecg, wfdbx.annstr.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if code >= 0 && code <= ACMAX
    st = wfdbx.internal.ann_state();
    s = st.cstring{code+1};
else
    s = sprintf('[%d]', code);
end
end
