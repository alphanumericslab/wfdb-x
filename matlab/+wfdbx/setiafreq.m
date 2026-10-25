function setiafreq(an, f)
%SETIAFREQ Set the time resolution of an input annotator.
%   wfdbx.setiafreq(AN, F) makes wfdbx.getann(AN) return times in units of
%   1/F seconds (F > 0), converted from the file's time resolution (or
%   from the sampling frequency of the record if the file does not record
%   one).  F <= 0 restores the file's own units.
%
%   See also wfdbx.getiafreq, wfdbx.getiaorigfreq.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
