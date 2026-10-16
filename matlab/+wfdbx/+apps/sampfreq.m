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
%   Example:
%       wfdbx.apps.sampfreq({'100s'})
%
%   See also wfdbx.sampfreq, wfdbx.apps.wfdbdesc.

% Copyright (C) 1998-2012 George B. Moody (original C program, app/sampfreq.c).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU General Public License, version 2 or later (see LICENSE).

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
