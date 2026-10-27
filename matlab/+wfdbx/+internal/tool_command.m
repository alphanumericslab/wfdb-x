function cmd = tool_command(tool)
%TOOL_COMMAND Shell command that runs a wfdb-x tool in a separate process.
%   CMD = wfdbx.internal.tool_command(TOOL) returns a shell command prefix
%   (a char vector, with its parts quoted for /bin/sh) that runs the wfdb-x
%   tool TOOL in a new process of the same interpreter; append the tool's
%   (quoted) arguments and run it with system().  This is how
%   oannclose runs sortann in legacy mode, as the C library does.
%
%   In Octave: '<OCTAVE_HOME>/bin/octave-cli' --no-gui --norc -q
%   '<matlab>/bin/wfdbx_cli.m' TOOL; in MATLAB: '<matlab>/bin/wfdbx_matlab.sh'
%   TOOL.
%
%   See also wfdbx.internal.shell_quote.
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

q = @wfdbx.internal.shell_quote;
bindir = fullfile(fileparts(fileparts(fileparts(mfilename('fullpath')))), 'bin');
if wfdbx.internal.is_octave()
    exe = fullfile(OCTAVE_HOME(), 'bin', 'octave-cli');
    if ~exist(exe, 'file')
        exe = 'octave-cli';
    end
    cmd = [q(exe) ' --no-gui --norc -q ' q(fullfile(bindir, 'wfdbx_cli.m')) ...
        ' ' q(tool)];
else
    cmd = [q(fullfile(bindir, 'wfdbx_matlab.sh')) ' ' q(tool)];
end
end
