function stat = setannstr(code, s)
%SETANNSTR Redefine the mnemonic of an annotation code.
%   STAT = wfdbx.setannstr(CODE, S) makes S the mnemonic returned by
%   wfdbx.annstr for annotation code CODE (0 to 49).  If CODE is positive, the change is recorded so that
%   it is written in the table of the annotation files written afterwards;
%   with -CODE, it is not.  STAT is 0, or -1 for an illegal code.
%
%   See also wfdbx.annstr, wfdbx.setanndesc.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
mflag = 0;
if code > 0
    mflag = 1;
else
    code = -code;
end
if code <= ACMAX
    if ~ischar(s)
        s = '';
    end
    st = wfdbx.internal.annstate();
    old = st.astring{code+1};
    if ~ischar(old) || ~strcmp(old, s)
        st.astring{code+1} = s;
        if mflag
            st.modified(code+1) = 1;
        end
    end
    stat = 0;
else
    wfdbx.internal.wfdb_error('setannstr: illegal annotation code %d\n', code);
    stat = -1;
end
end
