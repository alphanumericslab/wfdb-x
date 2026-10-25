function istat = ann_format(D)
%ANN_FORMAT The format of an input annotation file.
%   ISTAT = wfdbx.internal.ann_format(D) returns the format of the
%   annotation file whose bytes are D (a uint8 row): 0 (WFDB_READ, MIT
%   format) or 2 (WFDB_AHA_READ), guessed as annopen does from the first
%   16-bit word (read as C's 16-bit getc() pair: a missing byte reads as
%   EOF, 0xff): an AHA file starts with a null byte followed by an AHA code
%   other than '[' or ']'.  (wfdb-x: this was part of annopen; the sorting
%   of output files, wfdbx.internal.ann_sortfile, uses it too.)

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

NOTQRS = 0;         % lib/ecgcodes.h
if numel(D) >= 2
    w = double(D(1)) + 256 * double(D(2));
elseif numel(D) == 1
    w = double(D(1)) + 256 * 255;
else
    w = 65535;
end
a = floor(w / 256);
if mod(w, 256) ~= 0 || wfdbx.ammap(a) == NOTQRS || a == '[' || a == ']'
    istat = 0;      % WFDB_READ
else
    istat = 2;      % WFDB_AHA_READ
end
end
