function stat = ann_sortfile(fname, aname)
%ANN_SORTFILE Rearrange an output annotation file in canonical order.
%   STAT = wfdbx.internal.ann_sortfile(FNAME, ANAME) rearranges the
%   annotations of the (closed) annotation file FNAME of annotator ANAME
%   in the canonical order (by time, then num, then chan), in this process
%   (WFDB-x; see wfdbx.oannclose).  The result is identical, byte for
%   byte, to that of the sortann program as the C library ran it
%   ("sortann -r. RECORD -a ANNOTATOR"), but the header of the record is
%   not looked up.  As sortann does, the file (FNAME itself, not searched
%   for in the WFDB path) is read with any time resolution and annotation
%   type definitions it contains, its annotations at nonnegative times are
%   inserted in the annotation list of sortann
%   (wfdbx.internal.ann_sortlist: the last of several annotations with the
%   same time, num and chan is kept), and, unless they were already in
%   order, the file is rewritten in MIT format, with the time resolution
%   of the input file (if any), the definitions read, and without the
%   NOTQRS annotations.  Its own reader, writer and definition table
%   (starting from the defaults) are used: the library's annotators,
%   tables and settings are not changed.  STAT is 0 on success, or -1 if
%   the file cannot be read (or ends unexpectedly) or written.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/annot.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: this function is a WFDB-x addition: it
% rearranges an out-of-order output annotation file in this process, with
% the result of the sortann program, which the C library ran through the
% shell. docs/DIVERGENCES.md gives the reasons.
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

NOTQRS = 0;         % lib/ecgcodes.h
WFDB_WRITE = 1;
WFDB_AHA_READ = 2;
stat = -1;
% Read the file, starting from the default definition table.
defs = wfdbx.internal.ann_defs(wfdbx.internal.AnnState());
f = wfdbx.internal.wfdb_fopen(fname, 'rb');
if isempty(f)
    return;
end
D = f.readall();
f.close();
istat = wfdbx.internal.ann_format(D);
ia = wfdbx.internal.ann_iadata([], aname, istat, ...
    wfdbx.internal.ann_parse(D, istat == WFDB_AHA_READ));
[~, ia, defs] = wfdbx.internal.ann_readtable(ia, defs);
[s, A] = wfdbx.internal.ann_getbulk(ia, inf, false, false);
if s ~= -1                  % -1: the logical end of the file
    return;
end
% As sortann (whose -f time is 0), skip annotations at negative times.
A = sel(A, A.time >= 0);
[order, in_order] = wfdbx.internal.ann_sortlist(A.time, A.num, A.chan, false);
if in_order                 % (sortann writes nothing then)
    stat = 0;
    return;
end
A = sel(A, order);
A = sel(A, A.anntyp ~= NOTQRS);
f = wfdbx.internal.wfdb_fopen(fname, 'wb');
if isempty(f)
    return;
end
oa = wfdbx.internal.ann_oadata(f, aname, WFDB_WRITE);
ok = true;
if ~isempty(A.time)         % (the table precedes the first annotation)
    oa.table_written = 1;
    [s, oa] = wfdbx.internal.ann_puttable(oa, 0, ia.afreq, defs);
    ok = s == 0;
    if ok
        [s, oa] = wfdbx.internal.ann_putbulk(oa, 0, A, 1:numel(A.time));
        ok = s >= 0;
    end
end
oa = wfdbx.internal.ann_oflush(oa);
f.p16(0);                   % end of file marker
if f.ferror()
    ok = false;
end
if f.close()
    ok = false;
end
if ok
    stat = 0;
end
end

function A = sel(A, k)
A.time = A.time(k);
A.anntyp = A.anntyp(k);
A.subtyp = A.subtyp(k);
A.chan = A.chan(k);
A.num = A.num(k);
A.aux = A.aux(k);
end
