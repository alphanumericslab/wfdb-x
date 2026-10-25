function stat = calopen(cfname)
%CALOPEN Read a calibration file into the calibration list.
%   STAT = wfdbx.calopen(CFNAME) reads the calibration file CFNAME (found
%   in the WFDB path).  The calibration list is emptied first, unless
%   CFNAME begins with '+' (then the entries are appended).  Without
%   CFNAME (or with []), the file named by the environment variable
%   WFDBCAL is read, or 'wfdbcal' if it is not set.  STAT is 0, or -2 if
%   the file cannot be read.
%
%   Each line of the file is "SIGTYPE<tab>LOW HIGH PULSETYPE SCALE UNITS"
%   ('*' for any signal type, '-' for an undefined level); lines starting
%   with '#' are comments.
%
%   See also wfdbx.getcal, wfdbx.putcal, wfdbx.newcal, wfdbx.flushcal.

% Copyright (C) 1991-2013 George B. Moody (original C implementation,
% lib/calib.c; revised 2019-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if nargin >= 1 && isa(cfname, 'string')   % MATLAB string
    cfname = char(cfname);
end
if nargin < 1 || ~ischar(cfname)
    cfname = wfdbx.internal.cgetenv('WFDBCAL');
    if ~ischar(cfname)
        cfname = wfdbx.wfdbdefwfdbcal();
    end
end
if ~isempty(cfname) && cfname(1) == '+'
    cfname = cfname(2:end);
else
    wfdbx.flushcal();
end
f = wfdbx.internal.wfdb_open(cfname, [], 0);
if isempty(f)
    wfdbx.internal.wfdb_error('calopen: can''t read calibration file %s\n', cfname);
    stat = -2;
    return;
end
st = wfdbx.internal.cal_state();
tab = char(9);
ws = sprintf(' \t');
while true
    buf = f.getline();
    if isempty(buf)
        break;
    end
    i = 1;
    while i <= numel(buf) && any(buf(i) == sprintf(' \t\r'))
        i = i + 1;
    end
    if i <= numel(buf) && buf(i) == '#'
        continue;
    end
    t = wfdbx.internal.Strtok(buf(i:end));
    p1 = t.next(tab);
    p2 = [];
    p3 = [];
    p4 = [];
    p5 = [];
    p6 = [];
    if ischar(p1)
        p2 = t.next(ws);
    end
    if ischar(p2)
        p3 = t.next(ws);
    end
    if ischar(p3)
        p4 = t.next(ws);
    end
    if ischar(p4)
        p5 = t.next(ws);
    end
    if ischar(p5)
        p6 = t.next(sprintf(' \t\r\n'));
    end
    if ~ischar(p6)
        continue;
    end
    c = wfdbx.calinfo();
    if strcmp(p1, '*')
        p1 = '';
    end
    c.sigtype = p1;
    if strcmp(p2, '-')
        c.caltype = 0;                  % WFDB_AC_COUPLED
        c.low = 0;
    else
        c.caltype = 1;                  % WFDB_DC_COUPLED
        c.low = wfdbx.internal.strtod(p2);
    end
    if strcmp(p3, '-')
        c.high = 0;
        c.low = 0;
    else
        c.high = wfdbx.internal.strtod(p3);
    end
    switch p4
        case 'square'
            c.caltype = bitor(c.caltype, 2);
        case 'sine'
            c.caltype = bitor(c.caltype, 4);
        case 'sawtooth'
            c.caltype = bitor(c.caltype, 6);
    end
    c.scale = wfdbx.internal.strtod(p5);
    c.units = p6;
    st.list(end+1) = c;
end
f.close();
stat = 0;
end
