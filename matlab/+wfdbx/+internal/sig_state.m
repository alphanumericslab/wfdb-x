function st = sig_state()
%SIG_STATE The global state of the WFDB signal module (a wfdbx.internal.SigState).
%   ST = wfdbx.internal.sig_state() returns the handle object holding the
%   open input and output signals, the header data, the time base, etc.
%   It is created on the first call.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

persistent s
if isempty(s)
    s = wfdbx.internal.SigState();
end
st = s;
end
