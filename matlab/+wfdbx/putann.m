function stat = putann(an, annot)
%PUTANN Write an annotation to an output annotator.
%   STAT = wfdbx.putann(AN, ANNOT) writes the annotation ANNOT (a
%   wfdbx.annotation() structure) to output annotator AN (0 for the first
%   output annotator opened by wfdbx.annopen).  ANNOT.aux is [] or a uint8
%   (or double) row vector whose first element is the length of the data
%   that follows.  STAT is 0 on success, -1 on a write error, or -2 if AN
%   is not an open output annotator.
%
%   Annotations should be written in canonical order (by time, then num,
%   then chan); otherwise the file is rearranged when it is closed (see
%   wfdbx.oannclose).
%
%   See also wfdbx.annopen, wfdbx.getann, wfdbx.oannclose.
%
%   Translation of the C function putann() (lib/annot.c, WFDB 10.7.0): same
%   arguments and results.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
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
if an < 0 || an >= numel(st.oad) || isempty(st.oad{an+1})
    wfdbx.internal.wfdb_error('putann: can''t write annotation file %d\n', an);
    stat = -2;
    return;
end
oa = st.oad{an+1};
if ~oa.table_written
    oa.table_written = 1;
    [stat, oa] = wfdbx.internal.ann_puttable(oa, an, st.oafreq, ...
        wfdbx.internal.ann_defs(st));
    st.oad{an+1} = oa;
    if stat < 0
        return;
    end
end
[stat, oa] = wfdbx.internal.ann_putword(oa, an, annot);
st.oad{an+1} = oa;
end
