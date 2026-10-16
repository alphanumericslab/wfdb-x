function s = wfdbdefwfdbcal()
%WFDBDEFWFDBCAL The default name of the calibration file.
%   S = wfdbx.wfdbdefwfdbcal() returns 'wfdbcal' (used when the environment
%   variable WFDBCAL is not set).
%
%   See also wfdbx.wfdbdefwfdb, wfdbx.calopen.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

s = 'wfdbcal';
end
