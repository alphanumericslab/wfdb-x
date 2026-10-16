function status = app_run(main, argv)
%APP_RUN Run a tool's main function as a C program.
%   STATUS = wfdbx.internal.app_run(MAIN, ARGV) calls STATUS = MAIN(ARGV),
%   where ARGV is the C argv as a cell row of char vectors (ARGV{1} is the
%   program name).  A call of wfdbx.internal.cexit(S) anywhere in the tool
%   ends it with status S.  The standard output is flushed when the tool
%   ends.  As every C tool does first, a first argument '--legacy' is
%   removed and turns legacy mode on (wfdbx.wfdbx_legacy_args); the
%   previous setting is restored when the tool ends.  Other errors are passed on to the caller (the command-line
%   driver reports them and exits with status 1).
%
%   Each tool +wfdbx/+apps/NAME.m is written as
%
%       function status = NAME(args)
%       %NAME ... help ...
%       if nargin < 1, args = {}; end
%       status = wfdbx.internal.app_run(@main, [{'NAME'}, args]);
%       end
%
%       function status = main(argv)
%       ... port of main() of the C program; argc = numel(argv) ...
%       status = 0;
%       end
%
%   See also wfdbx.internal.cexit, wfdbx.internal.cli_main.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

legacy = wfdbx.wfdbx_get_legacy();
[~, argv] = wfdbx.wfdbx_legacy_args(argv);
try
    status = main(argv);
    if isempty(status)
        status = 0;
    end
catch err
    wfdbx.internal.cout();
    wfdbx.wfdbx_set_legacy(legacy);
    if strcmp(err.identifier, 'wfdbx:exit')
        status = str2double(err.message);
        return;
    end
    rethrow(err);
end
wfdbx.internal.cout();
wfdbx.wfdbx_set_legacy(legacy);
end
