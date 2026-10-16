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
%   The pathname of the file found in the WFDB path is printed on the
%   standard output; if it is not found, a message is printed on the
%   standard error output and the status is 2.
%
%   Example:
%       wfdbx.apps.wfdbwhich({'hea', '100s'})
%
%   See also wfdbx.apps.wfdbcat, wfdbx.wfdbfile.

% Copyright (C) 1999 George B. Moody (original C program, app/wfdbwhich.c).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU General Public License, version 2 or later (see LICENSE).

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
