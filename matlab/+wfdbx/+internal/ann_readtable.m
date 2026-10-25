function [stat, ia, defs] = ann_readtable(ia, defs)
%ANN_READTABLE Read the annotation table of an input annotator structure.
%   [STAT, IA, DEFS] = wfdbx.internal.ann_readtable(IA, DEFS) is the body of
%   get_ann_table (wfdb-x), for the input annotator structure IA (just
%   opened) and the definition table DEFS (see wfdbx.internal.ann_defs:
%   the library's, or one of wfdbx.internal.ann_sortfile): it reads the
%   NOTE annotations at time 0 at the start of the file, sets IA.afreq from
%   the time resolution ("## time resolution: F"; IA.tmul is 1), records
%   the redefinitions of mnemonics and descriptions ("CODE MNEMONIC
%   DESCRIPTION") in DEFS (as setannstr and setanndesc do), and pushes the
%   first other annotation back.  STAT is 0, or -1 if the file has no
%   annotation.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
NOTE = 22;      % comment annotation
TRES = '## time resolution: ';

ia.tmul = 1;
ia.afreq = 0;
[stat, annot, ia] = wfdbx.internal.ann_get1(ia);
if stat < 0
    stat = -1;
    return;
end
while true
    [s, g, ia] = wfdbx.internal.ann_get1(ia);
    if s == 0
        annot = g;
    end
    if ~(s == 0 && annot.time == 0 && annot.anntyp == NOTE && annot.subtyp == 0)
        break;
    end
    if isempty(annot.aux) || annot.aux(1) < 1
        continue;
    end
    b = annot.aux(2:end);
    z = find(b == 0, 1);
    if ~isempty(z)
        b = b(1:z-1);
    end
    text = char(b);
    if ~isempty(text) && text(1) == '#'
        if strncmp(text, TRES, numel(TRES))
            [v, e] = wfdbx.internal.strtod(text, numel(TRES));
            if e ~= numel(TRES)
                ia.afreq = v;
            end
        end
        continue;
    end
    n = numel(text);
    p1 = 1;
    while p1 <= n && (text(p1) == ' ' || text(p1) == char(9))
        p1 = p1 + 1;
    end
    [a, p2] = wfdbx.internal.strtol(text, 10, p1);
    if a < 0 || a > ACMAX || p1 == p2
        continue;
    end
    while p2 <= n && text(p2) ~= ' ' && text(p2) ~= char(9)
        p2 = p2 + 1;
    end
    p1 = p2;
    while p1 <= n && (text(p1) == ' ' || text(p1) == char(9))
        p1 = p1 + 1;
    end
    p2 = p1;
    while p2 <= n && text(p2) ~= ' ' && text(p2) ~= char(9)
        p2 = p2 + 1;
    end
    if p2 ~= p1
        if p2 <= n
            d = text(p2+1:end);
        else
            d = [];
        end
        [defs.tstr, defs.mod] = wfdbx.internal.ann_setdef(defs.tstr, ...
            defs.mod, a, d);
        [defs.astr, defs.mod] = wfdbx.internal.ann_setdef(defs.astr, ...
            defs.mod, a, text(p1:p2-1));
    end
end
if annot.time ~= 0 || annot.anntyp ~= NOTE || annot.subtyp ~= 0 || ...
        isempty(annot.aux)
    ia = wfdbx.internal.ann_unget(ia, annot);
end
stat = 0;
end
