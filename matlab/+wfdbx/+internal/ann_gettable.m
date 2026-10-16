function stat = ann_gettable(i)
%ANN_GETTABLE Read the annotation table at the start of an annotation file.
%   STAT = wfdbx.internal.ann_gettable(I) (get_ann_table in annot.c) reads
%   the NOTE annotations at time 0 at the start of input annotator I: the
%   time resolution ("## time resolution: F") and the redefinitions of
%   mnemonics and descriptions ("CODE MNEMONIC DESCRIPTION"); the first
%   other annotation is pushed back.  Then the time resolution of the
%   annotator is set (setiafreq) from the input frequency.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
NOTE = 22;      % comment annotation
TRES = '## time resolution: ';

st = wfdbx.internal.annstate();
ia = st.iad{i+1};
ia.tmul = 1;
ia.afreq = 0;
st.iad{i+1} = ia;
[stat, annot] = wfdbx.getann(i);
if stat < 0
    stat = -1;
    return;
end
while true
    [s, annot] = wfdbx.getann(i, annot);
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
                ia = st.iad{i+1};
                ia.afreq = v;
                st.iad{i+1} = ia;
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
            wfdbx.setanndesc(a, text(p2+1:end));
        else
            wfdbx.setanndesc(a, []);
        end
        wfdbx.setannstr(a, text(p1:p2-1));
    end
end
if annot.time ~= 0 || annot.anntyp ~= NOTE || annot.subtyp ~= 0 || ...
        isempty(annot.aux)
    wfdbx.ungetann(i, annot);
end
wfdbx.setiafreq(i, wfdbx.getifreq());
stat = 0;
end
