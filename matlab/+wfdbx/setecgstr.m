function stat = setecgstr(code, s)
%SETECGSTR Redefine the fixed mnemonic of an annotation code.
%   STAT = wfdbx.setecgstr(CODE, S) makes S the string returned by
%   wfdbx.ecgstr(CODE) (CODE 0 to 49).  STAT is 0, or -1 for an illegal
%   code.
%
%   See also wfdbx.ecgstr, wfdbx.setannstr.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if code >= 0 && code <= ACMAX
    if ~ischar(s)
        s = '';
    end
    st = wfdbx.internal.ann_state();
    st.cstring{code+1} = s;
    stat = 0;
else
    wfdbx.internal.wfdb_error('setecgstr: illegal annotation code %d\n', code);
    stat = -1;
end
end
