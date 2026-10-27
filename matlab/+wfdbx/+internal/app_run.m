function status = app_run(main, argv)
%APP_RUN Run a tool's main function as a C program.
%   STATUS = wfdbx.internal.app_run(MAIN, ARGV) calls STATUS = MAIN(ARGV),
%   where ARGV is the C argv as a cell row of char vectors (ARGV{1} is the
%   program name).  A call of wfdbx.internal.cexit(S) anywhere in the tool
%   ends it with status S.  The standard output is flushed when the tool
%   ends.  As every C tool does first, a first argument '--legacy' is
%   removed and turns legacy mode on (wfdbx.wfdbx_legacy_args); the
%   previous setting is restored when the tool ends.  Other errors are
%   passed on to the caller (the command-line driver reports them and exits
%   with status 1).
%
%   wfdb-x: at the end, in normal mode, a standard output that could not be
%   written is reported ("PROGRAM: write error on standard output"), and the
%   exit status 0 becomes 1 if the standard output or another output file
%   could not be written (see wfdbx.wfdbx_write_errors), as for the
%   standard tools.  Legacy mode keeps the original exit status.
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
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

legacy = wfdbx.wfdbx_get_legacy();
[~, argv] = wfdbx.wfdbx_legacy_args(argv);
st = wfdbx.internal.io_state();
errors = st.write_errors;
try
    status = main(argv);
    if isempty(status)
        status = 0;
    end
catch err
    if ~strcmp(err.identifier, 'wfdbx:exit')
        wfdbx.internal.cout();
        wfdbx.wfdbx_set_legacy(legacy);
        rethrow(err);
    end
    status = str2double(err.message);
end
wfdbx.internal.cout();
mode = wfdbx.wfdbx_get_legacy();
wfdbx.wfdbx_set_legacy(legacy);
if ~mode
    failed = st.stdout_failed;
    if failed
        [~, pname, ext] = fileparts(argv{1});
        wfdbx.internal.cerr(sprintf('%s: write error on standard output\n', ...
            [pname ext]));
    end
    if status == 0 && (failed || st.write_errors > errors)
        status = 1;
    end
end
end
