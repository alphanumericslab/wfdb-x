function status = time2sec(args)
%TIME2SEC Convert a time interval to seconds.
%   STATUS = wfdbx.apps.time2sec(ARGS) runs the time2sec tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       time2sec [-r RECORD] TIME
%   where TIME (in hh:mm:ss format) is a time interval to be converted
%   into seconds; a time of day in square brackets (e.g., [9:0:0]) is
%   converted to the elapsed time from the beginning of RECORD.
%
%   Example:
%       wfdbx.apps.time2sec({'1:30'})
%
%   See also wfdbx.apps.wfdbtime, wfdbx.strtim.

% Copyright (C) 2003-2009 George B. Moody (original C program, app/time2sec.c).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU General Public License, version 2 or later (see LICENSE).

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'time2sec'}, args]);
end

function status = main(argv)
argc = numel(argv);
status = 0;
if argc == 4 && strcmp(argv{2}, '-r')
    wfdbx.isigopen(argv{3}, 0);
    t = wfdbx.strtim(argv{4});
    if t < 0
        t = -t;
    end
    sf = wfdbx.sampfreq([]);
    seconds = fix(t / sf);
    t = t - seconds * sf;
    milliseconds = fix((t * 1000) / sf + 0.5);
    if milliseconds >= 1000
        seconds = seconds + 1;
        milliseconds = milliseconds - 1000;
    end
    s = wfdbx.internal.csprintf('%ld', seconds);
    if milliseconds
        s = [s, wfdbx.internal.csprintf('.%03d', milliseconds)];
    end
    wfdbx.internal.cout([s, char(10)]);
    return;
elseif argc == 2 && ~strncmp(argv{2}, '-', 1)
    wfdbx.setsampfreq(1000);
    wfdbx.internal.cprintf('%.12g\n', wfdbx.strtim(argv{2}) / 1000);
    return;
end
wfdbx.internal.ceprintf('usage: %s [-r RECORD] TIME\n', argv{1});
wfdbx.internal.ceprintf(' where TIME (in hh:mm:ss format) is a time interval\n');
wfdbx.internal.ceprintf(' to be converted into seconds.  Enclose TIME in\n');
wfdbx.internal.ceprintf(' square brackets (e.g., [9:0:0]) to convert a time\n');
wfdbx.internal.ceprintf(' of day to the elapsed time in seconds from the\n');
wfdbx.internal.ceprintf(' beginning of the (optionally) specified RECORD.\n');
status = 1;
end
