function tf = is_octave()
%IS_OCTAVE True when running in GNU Octave (false in MATLAB).
%   TF = wfdbx.internal.is_octave() is cached after the first call.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

persistent v
if isempty(v)
    v = exist('OCTAVE_VERSION', 'builtin') ~= 0;
end
tf = v;
end
