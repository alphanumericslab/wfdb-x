function wfdbmemerr(behavior)
%WFDBMEMERR Set the behavior of the library on memory allocation errors.
%   wfdbx.wfdbmemerr(BEHAVIOR) is accepted for compatibility with C (where
%   BEHAVIOR 0 makes allocation errors return instead of aborting); memory
%   errors are MATLAB errors in wfdb-x.
%
%   See also wfdbx.wfdberror.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.iostate();
st.mem_behavior = behavior;
end
