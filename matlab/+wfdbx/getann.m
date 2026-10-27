function [stat, annot] = getann(an, annot)
%GETANN Read the next annotation from an input annotator.
%   [STAT, ANNOT] = wfdbx.getann(AN) reads the next annotation from input
%   annotator AN (0 for the first annotator opened by wfdbx.annopen).
%   STAT is 0 on success, -1 at the end of the file, -2 if AN is not an
%   open input annotator, or -3 if the file ends unexpectedly.  ANNOT is a
%   wfdbx.annotation() structure (time, anntyp, subtyp, chan, num, aux).
%
%   [STAT, ANNOT] = wfdbx.getann(AN, ANNOT0) returns ANNOT0 unchanged when
%   no annotation is read (as the C function leaves its argument);
%   without ANNOT0, a zero annotation is returned then.
%
%   ANNOT.aux is [] or a uint8 row vector whose first element is the
%   length of the data that follows (as in C, the data may be followed by
%   stale bytes of the library's aux buffer, up to a null byte).
%
%   To read a whole annotation file into arrays, wfdbx.read_annotations
%   is much faster than calling getann in a loop.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with wfdb-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.annopen('100s', wfdbx.anninfo('atr', wfdbx.WFDB_READ()));
%       [stat, a] = wfdbx.getann(0);
%       while stat == 0
%           fprintf('%d %s\n', a.time, wfdbx.annstr(a.anntyp));
%           [stat, a] = wfdbx.getann(0);
%       end
%       wfdbx.wfdbquit();
%
%   See also wfdbx.annopen, wfdbx.ungetann, wfdbx.iannsettime,
%   wfdbx.read_annotations.
%
%   Translation of the C function getann() (lib/annot.c, WFDB 10.7.0): same
%   arguments and results.

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
if an < 0 || an >= numel(st.iad) || isempty(st.iad{an+1})
    wfdbx.internal.wfdb_error('getann: can''t read annotator %d\n', an);
    stat = -2;
    if nargin < 2
        annot = wfdbx.annotation();
    end
    return;
end
ia = st.iad{an+1};
P = ia.P;
j = ia.k + 1;
if ia.pann.anntyp == 0 && ia.ateof == 0 && ia.auxpos < 0 && j <= P.N && ...
        ~P.aha && P.tokcnt(j) == 0 && (j < P.N || ~P.eofend)
    % fast path (MIT format, no aux strings involved): inline ann_get1
    annot = ia.ann;
    ia.prev_time = annot.time;
    ia.prev_tt = ia.ann_tt;
    ia.k = j;
    tt = P.tt(j);
    ia.ann_tt = tt;
    ia.ann.anntyp = P.typ(j);
    ia.ann.subtyp = P.sub(j);
    ia.ann.chan = P.chan(j);
    ia.ann.num = P.num(j);
    x = tt * ia.tmul;
    if x >= 0 && x < 9007199254740992   % 2^53: exact, round here
        t = fix(x);
        ia.ann.time = t + (x - t >= 0.5);
    else
        ia.ann.time = wfdbx.internal.ann_round(x);
    end
    st.iad{an+1} = ia;
    stat = 0;
    return;
end
[stat, a, ia] = wfdbx.internal.ann_get1(ia);
st.iad{an+1} = ia;
if stat == 0
    annot = a;
elseif nargin < 2
    annot = wfdbx.annotation();
end
end
