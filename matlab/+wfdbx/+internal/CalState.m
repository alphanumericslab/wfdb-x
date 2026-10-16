classdef CalState < handle
%CALSTATE The calibration list of the WFDB library (statics of calib.c).
%   The single instance is returned by wfdbx.internal.calstate().  Its
%   property list is a 1-by-N struct array of wfdbx.calinfo structures.

% Copyright (C) 1991-2013 George B. Moody (original C implementation,
% lib/calib.c; revised 2019-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

    properties
        list = repmat(wfdbx.calinfo(), 1, 0)
    end
end
