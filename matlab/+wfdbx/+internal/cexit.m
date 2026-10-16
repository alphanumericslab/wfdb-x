function cexit(status)
%CEXIT C exit(): terminate the running tool with an exit status.
%   wfdbx.internal.cexit(STATUS) ends the tool being run by
%   wfdbx.internal.app_run (which returns STATUS), by throwing an error
%   with the identifier 'wfdbx:exit'.  Use it where the C source calls
%   exit(); a tool's main function may also simply return its status.
%
%   See also wfdbx.internal.app_run.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

error('wfdbx:exit', '%d', status);
end
