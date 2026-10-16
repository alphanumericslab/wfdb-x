function wfdb_error(fmt, varargin)
%WFDB_ERROR Report an error of the WFDB library (printf-style).
%   wfdbx.internal.wfdb_error(FMT, A1, A2, ...) formats the message as C
%   sprintf does (see wfdbx.internal.csprintf), saves it (it is returned by
%   wfdbx.wfdberror) and writes it to the standard error output unless
%   wfdbx.wfdbquiet() is in effect.
%
%   See also wfdbx.wfdberror, wfdbx.wfdbquiet, wfdbx.wfdbverbose.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.iostate();
st.error_flag = true;
st.error_message = wfdbx.internal.csprintf(fmt, varargin{:});
if st.error_print
    wfdbx.internal.cerr(st.error_message);
end
end
