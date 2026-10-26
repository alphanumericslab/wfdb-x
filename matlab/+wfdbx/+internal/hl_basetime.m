function [base_time, base_time_ms, base_date] = hl_basetime(fs)
%HL_BASETIME Base time and date of the open record (high-level readers).
%   [BASE_TIME, BASE_TIME_MS, BASE_DATE] = wfdbx.internal.hl_basetime(FS)
%   returns, for the record whose header was read last (FS: its sampling
%   frequency, sampfreq):
%     BASE_TIME     wfdbx.timstr(0) (e.g. '[08:45:00 01/01/2001]'), or []
%                   if the header gives no base time (or FS is 0: timstr
%                   needs the sampling frequency)
%     BASE_TIME_MS  the base time in milliseconds after midnight (the
%                   library's btime: '14:00:03.500' gives 50403500), or []
%                   exactly when BASE_TIME is []
%     BASE_DATE     the base date as a 1-by-3 double [y m d] (converted as
%                   wfdbx.datstr converts it), or [] if the header gives
%                   no date

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
base_time = [];
base_time_ms = [];
if fs > 0       % (timstr needs the sampling frequency)
    base_time = wfdbx.timstr(0);
    if ~strncmp(base_time, '[', 1)
        base_time = [];
    else
        base_time_ms = double(S.btime);
    end
end
base_date = [];
if S.bdate ~= 0
    base_date = wfdbx.internal.datymd(double(S.bdate));
end
end
