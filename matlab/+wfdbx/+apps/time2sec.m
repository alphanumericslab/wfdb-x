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
%
%   Translation of the C program time2sec (app/time2sec.c, WFDB 10.7.0):
%   same options and output.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/time2sec.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language and the --legacy
% option (as the first argument, it restores the original behavior).
%
% Original C program: app/time2sec.c, WFDB Software Package 10.7.0.
%   Copyright (C) 2003-2009 George B. Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

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
    % (as in C: with no sampling frequency, t / sf is infinite or NaN)
    seconds = wfdbx.internal.d2l(t / sf);
    t = t - seconds * sf;
    milliseconds = wfdbx.internal.cint32(wfdbx.internal.d2l((t * 1000) / sf + 0.5));
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
