function st = ann_state()
%ANN_STATE The global state of the WFDB annotation module (a wfdbx.internal.AnnState).
%   ST = wfdbx.internal.ann_state() returns the handle object holding the
%   open annotators and the mnemonic tables.  It is created on the first
%   call.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

persistent s
if isempty(s)
    s = wfdbx.internal.AnnState();
end
st = s;
end
