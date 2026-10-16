function behavior = wfdb_me_fatal()
%WFDB_ME_FATAL Return the behavior on memory errors set by wfdbmemerr.
%   BEHAVIOR = wfdbx.wfdb_me_fatal() returns the value most recently
%   passed to wfdbx.wfdbmemerr (1, the default, means that memory errors
%   are fatal).
%
%   See also wfdbx.wfdbmemerr.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.iostate();
behavior = st.mem_behavior;
end
