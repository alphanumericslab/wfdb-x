function [stat, A] = getann_bulk(an, m, noaux, nofail)
%GETANN_BULK Read many annotations at once (repeated getann).
%   [STAT, A] = wfdbx.internal.getann_bulk(AN, M) has exactly the effect of
%   up to M calls of wfdbx.getann(AN), stopping at the first call that
%   fails (M may be Inf).  A is a structure of 1-by-N rows (N <= M, the
%   number of annotations read): time, anntyp, subtyp, chan, num, and aux
%   (a cell row of [] or uint8 rows, as the aux field of getann).  STAT is
%   0 if M annotations were read, otherwise the status of the call that
%   failed (-1 at the end of the file, -3 after an unexpected end, -2 for
%   an invalid annotator; error messages are printed as by getann).
%
%   [STAT, A] = wfdbx.internal.getann_bulk(AN, M, true) does not build
%   the aux strings (A.aux is empty), for callers that skip annotations.
%
%   [STAT, A] = wfdbx.internal.getann_bulk(AN, M, NOAUX, true) does not
%   make the call that fails: STAT is then 1 if fewer than M annotations
%   could be read (the next getann call will fail).  Callers that may stop
%   reading early use this so that the error message of a failing call is
%   printed only if C would make that call.
%
%   The annotations of MIT-format files are decoded with vector
%   operations; the aux buffer of the C library is emulated exactly.
%
%   Part of the translation of lib/annot.c (WFDB 10.7.0).

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

if nargin < 3
    noaux = false;
end
if nargin < 4
    nofail = false;
end
A = struct('time', zeros(1, 0), 'anntyp', zeros(1, 0), ...
    'subtyp', zeros(1, 0), 'chan', zeros(1, 0), 'num', zeros(1, 0), ...
    'aux', {cell(1, 0)});
st = wfdbx.internal.ann_state();
if an < 0 || an >= numel(st.iad) || isempty(st.iad{an+1})
    if m > 0
        wfdbx.internal.wfdb_error('getann: can''t read annotator %d\n', an);
        stat = -2;
    else
        stat = 0;
    end
    return;
end
[stat, A, ia] = wfdbx.internal.ann_getbulk(st.iad{an+1}, m, noaux, nofail);
st.iad{an+1} = ia;
end
