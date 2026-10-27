function s = fmstimstr(t, f)
%FMSTIMSTR Time string with milliseconds at frequency F (fmstimstr in signal.c).
%   S = wfdbx.internal.fmstimstr(T, F) converts T (sample intervals at F
%   Hz) to "hh:mm:ss.mmm" (elapsed time, T > 0 or no base time) or to
%   "[hh:mm:ss.mmm dd/mm/yyyy]" (absolute time -T after the base time).
%   The result is also saved as sig_state().time_string.
%
%   Translation of the C function fmstimstr() (lib/signal.c, WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin
%   Moody, who contributed this function in 2011.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

S = wfdbx.internal.sig_state();
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
