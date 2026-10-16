function ceprintf(fmt, varargin)
%CEPRINTF C fprintf(stderr, ...): formatted output to the standard error.
%   wfdbx.internal.ceprintf(FMT, A1, A2, ...) is the same as
%   wfdbx.internal.cerr(wfdbx.internal.csprintf(FMT, A1, A2, ...)).
%
%   See also wfdbx.internal.csprintf, wfdbx.internal.cerr.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

wfdbx.internal.cerr(wfdbx.internal.csprintf(fmt, varargin{:}));
end
