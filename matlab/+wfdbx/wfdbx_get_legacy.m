function on = wfdbx_get_legacy()
%WFDBX_GET_LEGACY True if the library's legacy mode is on.
%   ON = wfdbx.wfdbx_get_legacy() returns 1 if legacy mode is on (the
%   original package's built-in defaults; see wfdbx.wfdbx_set_legacy), 0
%   otherwise.  This function is a wfdb-x addition.
%
%   See also wfdbx.wfdbx_set_legacy, wfdbx.wfdbx_legacy_args.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
on = S.legacy_mode;
end
