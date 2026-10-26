function resetwfdb()
%RESETWFDB Restore the input directory set by setwfdb.
%   wfdbx.resetwfdb() restores the input directory set by the last call of
%   wfdbx.setwfdb, if any (wfdb-x; wfdbx.wfdbquit does not call it).
%
%   In legacy mode, it restores the WFDB path returned by the first call
%   of wfdbx.getwfdb (it undoes wfdbx.setwfdb), and is called by
%   wfdbx.wfdbquit.
%
%   See also wfdbx.getwfdb, wfdbx.setwfdb.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.io_state();
if ~wfdbx.wfdbx_get_legacy()    % wfdb-x
    if st.setwfdb_called
        wfdbx.internal.put_input_dir(st, st.setwfdb_input_dir);
    end
    return;
end
if ischar(st.wfdbpath_init)
    st.wfdbpath = st.wfdbpath_init;
end
end
