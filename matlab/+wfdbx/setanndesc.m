function stat = setanndesc(code, s)
%SETANNDESC Redefine the description of an annotation code.
%   STAT = wfdbx.setanndesc(CODE, S) makes S the description returned by
%   wfdbx.anndesc for annotation code CODE (0 to 49).  If CODE is positive, the change is recorded so that
%   it is written in the table of the annotation files written afterwards;
%   with -CODE, it is not.  STAT is 0, or -1 for an illegal code.
%
%   See also wfdbx.anndesc, wfdbx.setannstr.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.ann_state();
[tab, mflags, stat] = wfdbx.internal.ann_setdef(st.tstring, st.modified, code, s);
if stat == 0
    st.tstring = tab;
    st.modified = mflags;
else
    wfdbx.internal.wfdb_error('setanndesc: illegal annotation code %d\n', ...
        abs(code));
end
end
