function status = sampfreq(args)
%SAMPFREQ Print the sampling frequency of a WFDB record.
%   STATUS = wfdbx.apps.sampfreq(ARGS) runs the sampfreq tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       sampfreq [OPTION] RECORD
%   where OPTION may be either of:
%       -a   list all signals and their sampling frequencies
%       -h   show a usage summary
%       -H   show the maximum sampling frequency of a multifrequency record
%   Without OPTION, the base sampling frequency (frame rate) is printed.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.sampfreq({'100s'})
%
%   See also wfdbx.sampfreq, wfdbx.apps.wfdbdesc.
%
%   Translation of the C program sampfreq (app/sampfreq.c, WFDB 10.7.0):
%   same options and output. Differences: it prints 0 when the header gives
%   no sampling frequency; see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/sampfreq.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language and the --legacy
% option (as the first argument, it restores the original behavior). Through
% the library, a record whose header gives no sampling frequency has the
% frequency 0, which is printed (the original printed 250); see
% docs/DIVERGENCES.md.
%
% Original C program: app/sampfreq.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1998-2012 George B. Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'sampfreq'}, args]);
end

function help(pname)
wfdbx.internal.ceprintf('usage: %s [OPTION] RECORD\n', pname);
wfdbx.internal.ceprintf([' where RECORD is the name of the input record\n' ...
    ' and OPTION may be either of:\n' ...
    '  -a   list all signals and their sampling frequencies\n' ...
    '  -h   show this help\n' ...
    '  -H   show the maximum sampling frequency of a multifrequency record)\n' ...
    ' If no OPTION is used, show the base sampling frequency (frame rate).\n']);
end

function status = main(argv)
pname = argv{1};
argc = numel(argv);
status = 0;
if argc == 1
    help(pname);
    status = 1;
    return;
end
if argc == 2
    % WFDB-x: 0 if the header gives no sampling frequency (C: 250)
    wfdbx.internal.cprintf('%g\n', wfdbx.sampfreq(argv{2}));
    return;
end
if argc == 3 && (strcmp(argv{2}, '-a') || strcmp(argv{2}, '-H'))
    nsig = wfdbx.isigopen(argv{3}, 0);
    si = [];
    if nsig > 0
        [nsig, si] = wfdbx.isigopen(argv{3}, nsig); %#ok<ASGLU>
    end
    if argv{2}(2) == 'H'
        wfdbx.setgvmode(1);     % WFDB_HIGHRES
        wfdbx.internal.cprintf('%g\n', wfdbx.sampfreq([]));
        return;
    end
    wfdbx.setgvmode(0);         % WFDB_LOWRES
    freq = wfdbx.sampfreq([]);
    for i = 1:max(nsig, 0)
        wfdbx.internal.cprintf('%s\t%g\n', si(i).desc, si(i).spf * freq);
    end
end
end
