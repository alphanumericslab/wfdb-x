%WFDBX_CLI Command-line driver of WFDB-x for GNU Octave.
%   octave-cli --no-gui --norc -q matlab/bin/wfdbx_cli.m TOOL [ARGS ...]
%
%   runs the WFDB-x tool TOOL (e.g. rdsamp) with the arguments ARGS, as the
%   C program of the same name would be run, and exits with its status.
%   The standard input is available to the tool; its output is written to
%   the standard output and error.  `wfdbx_cli.m --list` lists the tools.
%
%   This script adds the matlab/ directory (the parent of its own
%   directory) to the path, then calls wfdbx.internal.cli_main (after
%   wfdbx.internal.std_stream('cli'), so that a standard output that
%   cannot be written is detected).
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

% (no command history: Octave would save it under the home directory)
history_save(false);
addpath(fileparts(fileparts(mfilename('fullpath'))));
% (a standard output that cannot be written is detected: see std_stream)
wfdbx.internal.std_stream('cli');
exit(wfdbx.internal.cli_main(argv()'));
