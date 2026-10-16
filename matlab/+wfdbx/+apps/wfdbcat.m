function status = wfdbcat(args)
%WFDBCAT Copy WFDB files (found in the WFDB path) to the standard output.
%   STATUS = wfdbx.apps.wfdbcat(ARGS) runs the wfdbcat tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       wfdbcat FILE [FILE ...]
%
%   Each FILE is searched in the WFDB path and copied to the standard
%   output; a message is printed for each file not found.
%
%   Example:
%       wfdbx.apps.wfdbcat({'100s.hea'})
%
%   See also wfdbx.apps.wfdbwhich, wfdbx.wfdbfile.

% Copyright (C) 2000 George B. Moody (original C program, app/wfdbcat.c;
% revised 2018 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU General Public License, version 2 or later (see LICENSE).

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
