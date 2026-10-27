function status = wfdbwhich(args)
%WFDBWHICH Find a WFDB file and print its pathname.
%   STATUS = wfdbx.apps.wfdbwhich(ARGS) runs the wfdbwhich tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       wfdbwhich [-r RECORD] FILENAME
%       wfdbwhich FILE-TYPE RECORD
%
%   The file is looked for where it is named: in the input directory, by
%   a full path or as a URL (in legacy mode, in the WFDB path). Its
%   pathname is printed on the standard output; if it is not found, a message is printed on the
%   standard error output and the status is 2.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.wfdbwhich({'hea', '100s'})
%
%   See also wfdbx.apps.wfdbcat, wfdbx.wfdbfile.
%
%   Translation of the C program wfdbwhich (app/wfdbwhich.c, WFDB 10.7.0):
%   same options and output. Differences: files are not searched for in the
%   WFDB path (except in legacy mode); see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/wfdbwhich.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language and the --legacy
% option (as the first argument, it restores the original behavior). Through
% the library, the file is looked for only where it is named (the input
% directory, a full path or a URL), not by a search of the WFDB path; see
% docs/DIVERGENCES.md.
%
% Original C program: app/wfdbwhich.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1999 George B. Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'wfdbwhich'}, args]);
end

function status = main(argv)
pname = argv{1};
argc = numel(argv);
status = 0;
if argc == 2 && strcmp(argv{2}, '-h')
    argc = 0;
end
switch argc
    case 2
        filename = wfdbx.wfdbfile(argv{2}, []);
        if ischar(filename)
            wfdbx.internal.cprintf('%s\n', filename);
        else
            wfdbx.internal.ceprintf('`%s'' not found\n', argv{2});
            wfdbx.internal.ceprintf('(WFDB path = %s)\n', wfdbx.getwfdb());
            status = 2;
        end
    case 3
        wfdbx.wfdbquiet();
        wfdbx.isigopen(argv{3}, 0);
        filename = wfdbx.wfdbfile(argv{2}, argv{3});
        if ischar(filename)
            wfdbx.internal.cprintf('%s\n', filename);
        else
            wfdbx.internal.ceprintf( ...
                'No file of type `%s'' found for record `%s''\n', ...
                argv{2}, argv{3});
            wfdbx.internal.ceprintf('(WFDB path = %s)\n', wfdbx.getwfdb());
            status = 2;
        end
    otherwise
        if argc ~= 4 || ~strcmp(argv{2}, '-r')
            wfdbx.internal.ceprintf('usage: %s [-r RECORD ] FILENAME\n', pname);
            wfdbx.internal.ceprintf(' -or-  %s FILE-TYPE RECORD\n', pname);
            status = 1;
        else
            wfdbx.isigopen(argv{3}, 0);
            filename = wfdbx.wfdbfile(argv{4}, []);
            if ischar(filename)
                wfdbx.internal.cprintf('%s\n', filename);
            else
                wfdbx.internal.ceprintf('`%s'' not found\n', argv{4});
                wfdbx.internal.ceprintf('(WFDB path = %s)\n', wfdbx.getwfdb());
                status = 2;
            end
        end
end
end
