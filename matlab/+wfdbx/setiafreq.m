function setiafreq(an, f)
%SETIAFREQ Set the time resolution of an input annotator.
%   wfdbx.setiafreq(AN, F) makes wfdbx.getann(AN) return times in units of
%   1/F seconds (F > 0), converted from the file's time resolution (or
%   from the sampling frequency of the record if the file does not record
%   one).  F <= 0 restores the file's own units.
%
%   See also wfdbx.getiafreq, wfdbx.getiaorigfreq.
%
%   Translation of the C function setiafreq() (lib/annot.c, WFDB 10.7.0):
%   same arguments and results.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/annot.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/annot.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

st = wfdbx.internal.ann_state();
if an >= 0 && an < numel(st.iad) && ~isempty(st.iad{an+1})
    ia = st.iad{an+1};
    if f > 0 && ia.afreq > 0
        ia.tmul = f / ia.afreq;
    else
        if f > 0
            sf = wfdbx.sampfreq([]);
        else
            sf = 0;
        end
        if f > 0 && sf > 0
            ia.tmul = f * wfdbx.getspf() / sf;
        else
            ia.tmul = 1;
        end
    end
    r = wfdbx.internal.ann_round([ia.ann_tt, ia.pann_tt, ia.prev_tt] * ia.tmul);
    ia.ann.time = r(1);
    ia.pann.time = r(2);
    ia.prev_time = r(3);
    st.iad{an+1} = ia;
end
end
