function isigclose()
%ISIGCLOSE Close the input signals (isigclose in signal.c).
%   wfdbx.internal.isigclose() closes the signal files of the open input
%   record and resets the input signal state.
%
%   Translation of the C function isigclose() (lib/signal.c, WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

S = wfdbx.internal.sig_state();
if ~isempty(S.sbuf) && ~S.in_msrec
    S.sbuf = [];
    S.sample_vflag = 0;
end
S.isd = [];
S.plan = [];
S.skip_pending = false;
S.nisig = 0;
S.framelen = 0;
S.empty_group = false;
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
