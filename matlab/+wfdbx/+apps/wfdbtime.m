function status = wfdbtime(args)
%WFDBTIME Convert between times and sample numbers of a WFDB record.
%   STATUS = wfdbx.apps.wfdbtime(ARGS) runs the wfdbtime tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       wfdbtime [ -r RECORD [ TIME ... ] ]
%   For each TIME, the sample number, the elapsed time and the absolute
%   time (if known) are printed.  wfdb-x: the record must specify its
%   sampling frequency (the C program assumed 250 Hz); see
%   docs/DIVERGENCES.md.
%
%   Example:
%       wfdbx.apps.wfdbtime({'-r', '100s', '1:00', 's100'})
%
%   See also wfdbx.apps.time2sec, wfdbx.strtim, wfdbx.timstr.

% Copyright (C) 2001 George B. Moody (original C program, app/wfdbtime.c;
% revised 2017-2018 by Benjamin Moody).
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
status = wfdbx.internal.app_run(@main, [{'wfdbtime'}, args]);
end

function status = main(argv)
record = [];
argc = numel(argv);
i = 1;
while i < argc
    if strcmp(argv{i + 1}, '-r')
        if ischar(record)
            wfdbx.wfdbquit();
        end
        i = i + 1;
        if i == argc
            break;
        end
        record = argv{i + 1};
        if wfdbx.isigopen(record, 0) < 0
            status = 2;
            return;
        end
        % wfdb-x: no default frequency (except in legacy mode)
        if ~wfdbx.wfdbx_get_legacy() && wfdbx.sampfreq([]) <= 0
            wfdbx.internal.ceprintf( ...
                '%s: sampling frequency of record %s is not specified\n', ...
                argv{1}, record);
            status = 2;
            return;
        end
    elseif ischar(record)
        t = wfdbx.strtim(argv{i + 1});
        if t < 0
            t = -t;
        end
        if t == 0
            e = '0:00.000';
        else
            e = wfdbx.mstimstr(t);
        end
        wfdbx.internal.cout([sprintf('%15s\t%15s', sprintf('s%d', t), e), ...
            sprintf('\t%15s\n', wfdbx.mstimstr(-t))]);
    end
    i = i + 1;
end
if ~ischar(record)
    wfdbx.internal.ceprintf('usage: %s [ -r RECORD [ TIME ] ]\n', argv{1});
    wfdbx.internal.ceprintf(' where RECORD is the name of the input record\n');
    wfdbx.internal.ceprintf(' Each TIME is a time to be converted\n');
    status = 1;
    return;
end
wfdbx.wfdbquit();
status = 0;
end
