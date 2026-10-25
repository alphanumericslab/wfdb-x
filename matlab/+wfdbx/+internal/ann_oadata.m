function oa = ann_oadata(f, name, ostat)
%ANN_OADATA A new output annotator structure (C's struct oadata).
%   OA = wfdbx.internal.ann_oadata(F, NAME, OSTAT) returns the output
%   annotator structure of the file F (a WFDBFile, just created) of
%   annotator NAME, in format OSTAT (1: MIT, 3: AHA).  Fields: file, name,
%   stat, rname and fname (the record name and the name of the file, set
%   by annopen), ann (the last annotation written), afreq (the time
%   resolution written), seqno (AHA serial number), out_of_order,
%   table_written, and the output buffer obuf (uint8) with its length
%   olen (see wfdbx.internal.ann_oflush).

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

OBUFLEN = 4096;     % initial size of the output buffer (bytes)
oa.file = f;
oa.name = name;
oa.stat = ostat;
oa.rname = [];
oa.fname = [];
oa.ann = wfdbx.annotation();
oa.afreq = 0;
oa.seqno = 0;
oa.out_of_order = 0;
oa.table_written = 0;
oa.obuf = zeros(1, OBUFLEN, 'uint8');
oa.olen = 0;
end
