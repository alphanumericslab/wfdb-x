function stat = newcal(cfname)
%NEWCAL Write the calibration list to a file.
%   STAT = wfdbx.newcal(CFNAME) writes the calibration list to the file
%   CFNAME (in the current directory), in the format read by
%   wfdbx.calopen.  STAT is 0, or -1 on error.
%
%   See also wfdbx.calopen, wfdbx.putcal.
%
%   Translation of the C function newcal() (lib/calib.c, WFDB 10.7.0): same
%   arguments and results.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/calib.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/calib.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1991-2013 George B. Moody; revised 2019-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

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
