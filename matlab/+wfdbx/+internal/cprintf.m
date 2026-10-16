function cprintf(fmt, varargin)
%CPRINTF C printf(): formatted output to the standard output.
%   wfdbx.internal.cprintf(FMT, A1, A2, ...) is the same as
%   wfdbx.internal.cout(wfdbx.internal.csprintf(FMT, A1, A2, ...)).
%
%   See also wfdbx.internal.csprintf, wfdbx.internal.cout,
%   wfdbx.internal.ceprintf.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

wfdbx.internal.cout(wfdbx.internal.csprintf(fmt, varargin{:}));
end
