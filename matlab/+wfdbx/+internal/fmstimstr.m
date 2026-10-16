function s = fmstimstr(t, f)
%FMSTIMSTR Time string with milliseconds at frequency F (fmstimstr in signal.c).
%   S = wfdbx.internal.fmstimstr(T, F) converts T (sample intervals at F
%   Hz) to "hh:mm:ss.mmm" (elapsed time, T > 0 or no base time) or to
%   "[hh:mm:ss.mmm dd/mm/yyyy]" (absolute time -T after the base time).
%   The result is also saved as sigstate().time_string.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody, who contributed this
% function in 2011).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
if t > 0 || (S.btime == 0 && S.bdate == 0)
    if t < 0
        t = -t;
    end
    sec = fix(t / f);
    msec = fix((t - sec * f) * 1000 / f + 0.5);
    if msec == 1000
        msec = 0;
        sec = sec + 1;
    end
    t = sec;
    seconds = mod(t, 60);
    t = floor(t / 60);
    minutes = mod(t, 60);
    hours = floor(t / 60);
    if hours > 0
        s = sprintf('%2d:%02d:%02d.%03d', hours, minutes, seconds, msec);
    else
        s = sprintf('   %2d:%02d.%03d', minutes, seconds, msec);
    end
else
    tms = S.btime - (t * 1000 / f);
    sec = fix(tms / 1000);
    msec = fix((tms - sec * 1000) + 0.5);
    if msec == 1000
        msec = 0;
        sec = sec + 1;
    end
    t = sec;
    seconds = rem(t, 60);
    t = fix(t / 60);
    minutes = rem(t, 60);
    t = fix(t / 60);
    hours = rem(t, 24);
    days = fix(t / 24);
    if days ~= S.pdays
        if S.bdate > 0
            wfdbx.datstr(days + S.bdate);
        elseif days == 0
            S.date_string = '';
        else
            S.date_string = sprintf(' %d', days);
        end
        S.pdays = days;
    end
    s = sprintf('[%02d:%02d:%02d.%03d%s]', hours, minutes, seconds, msec, ...
        S.date_string);
end
S.time_string = s;
end
