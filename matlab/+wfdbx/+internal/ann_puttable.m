function stat = ann_puttable(i)
%ANN_PUTTABLE Write the annotation table at the start of an output file.
%   STAT = wfdbx.internal.ann_puttable(I) (put_ann_table in annot.c)
%   writes, as NOTE annotations at time 0 of output annotator I, the time
%   resolution set by wfdbx.setafreq (if it differs from the annotator's)
%   and the mnemonics and descriptions redefined by wfdbx.setannstr and
%   wfdbx.setanndesc, followed by a null annotation.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
st = wfdbx.internal.annstate();
oa = st.oad{i+1};
flag = 0;
annot = wfdbx.annotation();
annot.anntyp = 22;                      % NOTE
stat = -1;
if st.oafreq ~= oa.afreq && st.oafreq > 0
    annot.aux = auxof(wfdbx.internal.csprintf('## time resolution: %.12g', ...
        st.oafreq));
    oa.afreq = st.oafreq;
    st.oad{i+1} = oa;
    if wfdbx.putann(i, annot) < 0
        return;
    end
    flag = 1;
end
for a = 0:ACMAX
    if st.modified(a+1)
        if flag < 2
            annot.aux = auxof('## annotation type definitions');
            if wfdbx.putann(i, annot) < 0
                return;
            end
        end
        d = wfdbx.anndesc(a);
        if ischar(d)
            s = sprintf('%d %s %s', a, wfdbx.annstr(a), d);
        else
            s = sprintf('%d %s ', a, wfdbx.annstr(a));
        end
        annot.aux = uint8([min(numel(s), 255), double(s)]);
        if wfdbx.putann(i, annot) < 0
            return;
        end
        flag = 2;
    end
end
if flag == 2
    annot.aux = auxof('## end of definitions');
    if wfdbx.putann(i, annot) < 0
        return;
    end
end
if flag
    annot.anntyp = 0;
    annot.aux = [];
    if wfdbx.putann(i, annot) < 0
        return;
    end
end
stat = 0;
end

function a = auxof(s)
a = uint8([mod(numel(s), 256), double(s)]);
end
