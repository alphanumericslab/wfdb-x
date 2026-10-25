function resetwfdb()
%RESETWFDB Restore the WFDB path to its initial value.
%   wfdbx.resetwfdb() restores the WFDB path returned by the first call of
%   wfdbx.getwfdb (it undoes wfdbx.setwfdb).  Called by wfdbx.wfdbquit.
%
%   See also wfdbx.getwfdb, wfdbx.setwfdb.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.io_state();
if ischar(st.wfdbpath_init)
    st.wfdbpath = st.wfdbpath_init;
end
end
