function msg = wfdberror()
%WFDBERROR The most recent WFDB library error message.
%   MSG = wfdbx.wfdberror() returns the last error message of the library
%   (ending with a newline), or, if no error has occurred, a message giving
%   the version of the library ('WFDB library version 10.7.0 (Jun 10
%   2022).').
%
%   See also wfdbx.wfdbquiet, wfdbx.wfdbversion.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.iostate();
if ~st.error_flag
    st.error_message = sprintf('WFDB library version %s (%s).\n', ...
        wfdbx.wfdbversion(), 'Jun 10 2022');
end
msg = st.error_message;
end
