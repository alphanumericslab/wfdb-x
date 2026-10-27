function status = cli_main(args)
%CLI_MAIN Run a WFDB-x tool from the command line.
%   STATUS = wfdbx.internal.cli_main(ARGS) runs the tool named by ARGS{1}
%   (e.g. 'rdsamp') with the arguments ARGS{2:end}, by calling
%   wfdbx.apps.<tool>(ARGS(2:end)), and returns its exit status.  The
%   standard output is flushed before returning.  An unknown tool gives a
%   message and status 1; an error (MATLAB exception) in the tool is
%   reported on the standard error output, with status 1.
%
%   This is the common part of the command-line drivers bin/wfdbx_cli.m
%   (Octave) and bin/wfdbx_matlab.sh (MATLAB), which exit with STATUS.
%   ARGS{1} may also be --list (list the tools) or --version.
%
%   See also wfdbx.internal.app_run.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

status = 1;
try
    if isempty(args) || strcmp(args{1}, '-h') || strcmp(args{1}, '--help')
        wfdbx.internal.cerr(sprintf(['usage: wfdbx TOOL [ARGUMENTS ...]\n' ...
            '       wfdbx --list\n']));
        status = double(isempty(args));
        return;
    end
    tool = args{1};
    appdir = fullfile(fileparts(mfilename('fullpath')), '..', '+apps');
    if strcmp(tool, '--list')
        d = dir(fullfile(appdir, '*.m'));
        names = sort({d.name});
        for k = 1:numel(names)
            wfdbx.internal.cout(sprintf('%s\n', names{k}(1:end-2)));
        end
        wfdbx.internal.cout();
        status = 0;
        return;
    end
    if strcmp(tool, '--version')
        wfdbx.internal.cout(sprintf('wfdb-x (WFDB %s)\n', wfdbx.wfdbversion()));
        wfdbx.internal.cout();
        status = 0;
        return;
    end
    % (a name [a-z][a-z0-9]*; not tested with regexp, which rejects
    % invalid UTF-8 in Octave)
    if isempty(tool) || ~(tool(1) >= 'a' && tool(1) <= 'z') || ...
            ~all((tool >= 'a' & tool <= 'z') | (tool >= '0' & tool <= '9')) || ...
            ~exist(fullfile(appdir, [tool '.m']), 'file')
        wfdbx.internal.cerr(sprintf( ...
            'wfdbx: unknown tool ''%s'' (try ''wfdbx --list'')\n', tool));
        return;
    end
    status = feval(['wfdbx.apps.' tool], args(2:end));
catch err
    wfdbx.internal.cout();
    if strcmp(err.identifier, 'wfdbx:exit')
        status = str2double(err.message);
    else
        msg = err.message;
        if isempty(msg) || msg(end) ~= char(10)
            msg = [msg char(10)];
        end
        wfdbx.internal.cerr(['wfdbx: error: ' msg]);
        status = 1;
    end
end
wfdbx.internal.cout();
end
