function wfdbquiet()
%WFDBQUIET Suppress WFDB library error messages.
%   wfdbx.wfdbquiet() stops the library from printing error messages on the
%   standard error output (they are still available from wfdbx.wfdberror).
%
%   See also wfdbx.wfdbverbose, wfdbx.wfdberror.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.iostate();
st.error_print = false;
end
