function [stat, oa] = ann_puttable(oa, n, freq, defs)
%ANN_PUTTABLE Write the annotation table at the start of an output file.
%   [STAT, OA] = wfdbx.internal.ann_puttable(OA, N, FREQ, DEFS)
%   (put_ann_table in annot.c) writes, as NOTE annotations at time 0 of the
%   output annotator structure OA (number N, in messages), the time
%   resolution FREQ (if it is > 0 and differs from the annotator's) and the
%   mnemonics and descriptions of the codes marked as modified in the
%   definition table DEFS (see wfdbx.internal.ann_defs), followed by a
%   null annotation.  putann passes the time resolution set by
%   wfdbx.setafreq and the library's table (redefined by wfdbx.setannstr
%   and wfdbx.setanndesc); WFDB-x: the C function used these directly, and
%   wfdbx.internal.ann_sortfile passes its own.  STAT is 0, or -1 on an
%   error.
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
% Changes from the original: the table is passed as an argument, so that
% ann_sortfile can pass its own. Each change is marked "WFDB-x:" in the
% code; docs/DIVERGENCES.md gives the reasons.
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

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
flag = 0;
annot = wfdbx.annotation();
annot.anntyp = 22;                      % NOTE
stat = -1;
if freq ~= oa.afreq && freq > 0
    annot.aux = auxof(wfdbx.internal.csprintf('## time resolution: %.12g', ...
        freq));
    oa.afreq = freq;
    [s, oa] = wfdbx.internal.ann_putword(oa, n, annot);
    if s < 0
        return;
    end
    flag = 1;
end
for a = 0:ACMAX
    if defs.mod(a+1)
        if flag < 2
            annot.aux = auxof('## annotation type definitions');
            [s, oa] = wfdbx.internal.ann_putword(oa, n, annot);
            if s < 0
                return;
            end
        end
        d = defs.tstr{a+1};
        if ischar(d)
            t = sprintf('%d %s %s', a, defs.astr{a+1}, d);
        else
            t = sprintf('%d %s ', a, defs.astr{a+1});
        end
        annot.aux = uint8([min(numel(t), 255), double(t)]);
        [s, oa] = wfdbx.internal.ann_putword(oa, n, annot);
        if s < 0
            return;
        end
        flag = 2;
    end
end
if flag == 2
    annot.aux = auxof('## end of definitions');
    [s, oa] = wfdbx.internal.ann_putword(oa, n, annot);
    if s < 0
        return;
    end
end
if flag
    annot.anntyp = 0;
    annot.aux = [];
    [s, oa] = wfdbx.internal.ann_putword(oa, n, annot);
    if s < 0
        return;
    end
end
stat = 0;
end

function a = auxof(s)
a = uint8([mod(numel(s), 256), double(s)]);
end
