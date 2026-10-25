function stat = newcal(cfname)
%NEWCAL Write the calibration list to a file.
%   STAT = wfdbx.newcal(CFNAME) writes the calibration list to the file
%   CFNAME (in the current directory), in the format read by
%   wfdbx.calopen.  STAT is 0, or -1 on error.
%
%   See also wfdbx.calopen, wfdbx.putcal.

% Copyright (C) 1991-2013 George B. Moody (original C implementation,
% lib/calib.c; revised 2019-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if wfdbx.internal.wfdb_checkname(cfname, 'calibration file') < 0
    stat = -1;
    return;
end
f = wfdbx.internal.wfdb_open(cfname, [], 1);
if isempty(f)
    wfdbx.internal.wfdb_error('newcal: can''t create calibration file %s\n', cfname);
    stat = -1;
    return;
end
st = wfdbx.internal.cal_state();
L = st.list;
for k = 1:numel(L)
    c = L(k);
    if ischar(c.sigtype) && ~isempty(c.sigtype)
        s = [c.sigtype, char(9)];
    else
        s = ['*', char(9)];
    end
    if bitand(c.caltype, 1)
        s = [s, wfdbx.internal.csprintf('%g ', c.low)]; %#ok<AGROW>
    else
        s = [s, '- ']; %#ok<AGROW>
    end
    if c.high ~= c.low
        s = [s, wfdbx.internal.csprintf('%g ', c.high)]; %#ok<AGROW>
    else
        s = [s, '- ']; %#ok<AGROW>
    end
    switch c.caltype - bitand(c.caltype, 1)
        case 2
            pt = 'square';
        case 4
            pt = 'sine';
        case 6
            pt = 'sawtooth';
        otherwise
            pt = 'undefined';
    end
    s = [s, wfdbx.internal.csprintf('%s %g %s\r\n', pt, c.scale, c.units)]; %#ok<AGROW>
    f.write(s);
end
errflag = f.ferror();
if f.close()
    errflag = true;
end
if errflag
    wfdbx.internal.wfdb_error('newcal: write error in calibration file\n');
    stat = -1;
    return;
end
stat = 0;
end
