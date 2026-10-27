function status = wfdbcat(args)
%WFDBCAT Copy WFDB files to the standard output.
%   STATUS = wfdbx.apps.wfdbcat(ARGS) runs the wfdbcat tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       wfdbcat FILE [FILE ...]
%
%   Each FILE is read from where it is named (the input directory, a full
%   path or a URL; in legacy mode, the WFDB path) and copied to the
%   standard output; a message is printed for each file not found.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with wfdb-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.wfdbcat({'100s.hea'})
%
%   See also wfdbx.apps.wfdbwhich, wfdbx.wfdbfile.
%
%   Translation of the C program wfdbcat (app/wfdbcat.c, WFDB 10.7.0): same
%   options and output. Differences: files are not searched for in the WFDB
%   path (except in legacy mode); see docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/wfdbcat.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language and the --legacy
% option (as the first argument, it restores the original behavior). Through
% the library, each file is read from where it is named (the input directory, a
% full path or a URL), not found by a search of the WFDB path; see
% docs/DIVERGENCES.md.
%
% Original C program: app/wfdbcat.c, WFDB Software Package 10.7.0.
%   Copyright (C) 2000 George B. Moody; revised 2018 by Benjamin Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'wfdbcat'}, args]);
end

function status = main(argv)
pname = argv{1};
argc = numel(argv);
if argc < 2 || (argc == 2 && strcmp(argv{2}, '-h'))
    wfdbx.internal.ceprintf('usage: %s FILE [FILE ...]\n', pname);
    status = 1;
    return;
end
for i = 2:argc
    f = wfdbx.internal.wfdb_open(argv{i}, [], 0);
    if isempty(f)
        wfdbx.internal.ceprintf('%s: `%s'' not found\n', pname, argv{i});
    else
        wfdbx.internal.cout(f.readall());
        f.close();
    end
end
status = 0;
end
