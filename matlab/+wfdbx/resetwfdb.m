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
%
%   Translation of the C function resetwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
%   arguments and results. Differences: it restores the input directory set by
%   the last setwfdb() (the WFDB path in legacy mode); see docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/wfdbio.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

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
