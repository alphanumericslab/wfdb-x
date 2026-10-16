%WFDBX_CLI Command-line driver of wfdb-x for GNU Octave.
%   octave-cli --no-gui --norc -q matlab/bin/wfdbx_cli.m TOOL [ARGS ...]
%
%   runs the wfdb-x tool TOOL (e.g. rdsamp) with the arguments ARGS, as the
%   C program of the same name would be run, and exits with its status.
%   The standard input is available to the tool; its output is written to
%   the standard output and error.  `wfdbx_cli.m --list` lists the tools.
%
%   This script adds the matlab/ directory (the parent of its own
%   directory) to the path, then calls wfdbx.internal.cli_main.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU General Public License, version 2 or later (see LICENSE).

addpath(fileparts(fileparts(mfilename('fullpath'))));
exit(wfdbx.internal.cli_main(argv()'));
