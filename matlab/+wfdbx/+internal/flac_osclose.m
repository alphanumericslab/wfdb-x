function stat = flac_osclose(og)
%FLAC_OSCLOSE Finish writing a FLAC output group (flac_osclose).
%   STAT = wfdbx.internal.flac_osclose(OG) encodes the remaining samples,
%   rewrites STREAMINFO (sample count, frame sizes and MD5 signature) if
%   OG.fp is seekable, and sets OG.flac to [] and OG.buf to an empty
%   buffer (the caller then closes OG.fp).  Returns 0.

% Original C implementation: the FLAC support of lib/signal.c, written by
% Benjamin Moody (2020); lib/signal.c is Copyright (C) 1989-2013 George
% B. Moody.
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

fo = og.flac;
try
    while fo.nbuf > 0
        fo = wfdbx.internal.flac_writeblock(og, fo, min(fo.nbuf, 4096));
    end
    if ~isempty(og.fp) && og.fp.seek(fo.header_pos + 8, 0) == 0
        md5 = wfdbx.internal.md5(fo.md5data(1:fo.md5len));
        og.fp.write(wfdbx.internal.flac_streaminfo(fo, fo.total, md5));
        og.fp.seek(0, 2);
    end
catch err
    % (the group is closed even if finishing it failed, so that a later
    % wfdbquit does not try again)
    og.flac = [];
    og.buf = zeros(1, 0, 'uint8');
    rethrow(err);
end
og.flac = [];
og.buf = zeros(1, 0, 'uint8');
stat = 0;
end
