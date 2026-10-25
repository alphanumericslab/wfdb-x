function st = io_state()
%IO_STATE The global state of the WFDB I/O layer (a wfdbx.internal.IOState).
%   ST = wfdbx.internal.io_state() returns the handle object that holds the
%   WFDB path, the error reporting state and the name of the last file
%   opened.  It is created on the first call.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

persistent s
if isempty(s)
    s = wfdbx.internal.IOState();
end
st = s;
end
