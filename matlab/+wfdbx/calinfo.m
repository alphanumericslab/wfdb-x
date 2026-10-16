function c = calinfo()
%CALINFO A WFDB_Calinfo structure (calibration information).
%   C = wfdbx.calinfo() returns a structure with the fields of the C
%   WFDB_Calinfo structure, with their initial values:
%
%     low      0    low level of the calibration pulse (physical units)
%     high     0    high level of the calibration pulse
%     scale    0    customary plotting scale (physical units per cm)
%     sigtype  []   signal type (NULL)
%     units    []   physical units (NULL)
%     caltype  0    calibration pulse type: 0 (AC coupled) or 1 (DC
%                   coupled), plus 2 (square), 4 (sine), 6 (sawtooth)
%                   or 8 (undefined shape); these are WFDB_AC_COUPLED,
%                   WFDB_DC_COUPLED, WFDB_CAL_SQUARE, ... of lib/wfdb.h
%
%   See also wfdbx.getcal, wfdbx.putcal.

% Copyright (C) 1983-2013 George B. Moody (original C header, lib/wfdb.h, which
% defines the structure; revised 2010-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

c = struct('low', 0, 'high', 0, 'scale', 0, 'sigtype', [], 'units', [], ...
    'caltype', 0);
end
