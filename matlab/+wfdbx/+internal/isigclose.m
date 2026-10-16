function isigclose()
%ISIGCLOSE Close the input signals (isigclose in signal.c).
%   wfdbx.internal.isigclose() closes the signal files of the open input
%   record and resets the input signal state.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
if ~isempty(S.sbuf) && ~S.in_msrec
    S.sbuf = [];
    S.sample_vflag = 0;
end
S.isd = [];
S.plan = [];
S.skip_pending = false;
S.nisig = 0;
S.framelen = 0;
igd = S.igd;
for g = 1:numel(igd)
    ig = igd{g};
    if ~isempty(ig.flac)
        wfdbx.internal.flac_isclose(ig);
    end
    if ~isempty(ig.fp)
        ig.fp.close();
    end
end
S.igd = {};
S.nigroup = 0;
S.istime = 0;
S.gvc = 1;
S.ispfmax = 1;
if ~isempty(S.hheader)
    S.hheader.close();
    S.hheader = [];
end
if S.nosig == 0 && ~isempty(S.hsd)
    S.hsd = [];
end
end
