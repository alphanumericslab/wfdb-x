function c = hl_settings()
%HL_SETTINGS Keep the getvec mode and the annotation time resolution.
%   C = wfdbx.internal.hl_settings() (WFDB-x), called at the start of a
%   high-level function that opens a record (read_record, read_header,
%   read_annotations, write_record, write_annotations, check_record),
%   saves the getvec mode (wfdbx.getgvmode) and the time resolution of
%   output annotators (wfdbx.getafreq).  The onCleanup object C restores
%   them (wfdbx.setgvmode, then wfdbx.setafreq) when it is cleared, i.e.
%   when the calling function returns or throws an error.  Opening an EDF
%   record sets both, as in C (the time resolution to the record's
%   sampling frequency when none is set, and the WFDB_HIGHRES bit of the
%   getvec mode), and wfdbx.wfdbquit resets neither; without this, a later
%   write_annotations would record that frequency, and later reading would
%   be in high resolution.  (The input annotators, and their frequencies,
%   are closed by wfdbquit.)  The C-style functions keep the behavior of C.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

gvmode = wfdbx.getgvmode();
afreq = wfdbx.getafreq();
c = onCleanup(@() restore(gvmode, afreq));
end

function restore(gvmode, afreq)
wfdbx.setgvmode(gvmode);
wfdbx.setafreq(afreq);
end
