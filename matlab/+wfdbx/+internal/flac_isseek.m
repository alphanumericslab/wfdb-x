function stat = flac_isseek(ig, t)
%FLAC_ISSEEK Seek to a frame of a FLAC input group (flac_isseek).
%   STAT = wfdbx.internal.flac_isseek(IG, T) positions the input group IG
%   at frame T (counted from IG.start samples into the stream); it
%   returns IG.stat (1), or -1 if T is out of range or the stream cannot
%   be decoded.

% Original C implementation: the FLAC support of lib/signal.c, written by
% Benjamin Moody (2020); lib/signal.c is Copyright (C) 1989-2013 George
% B. Moody.
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

fi = wfdbx.internal.flac_ensure(ig);
ig.stat = 1;
ig.count = 0;
fi.seeked = true;
if ~isempty(fi.error)
    ig.flac = fi;
    ig.stat = -1;
    stat = -1;
    return;
end
tt = t * fi.spf + ig.start;
if fi.aborted || tt > fi.total || tt < 0
    % (libFLAC refuses to seek once decoding was aborted, or past the end
    % of the stream; the buffered samples are discarded anyway)
    fi.discarded = true;
    ig.flac = fi;
    ig.stat = -1;
    stat = -1;
    return;
end
fi = wfdbx.internal.flac_pack(fi, tt);
fi.discarded = false;
% The seek decodes the block that contains sample tt - 1 (sample 0 if tt is
% 0): libFLAC seeks to it, and the first sample is skipped.
fi.dec_end = wfdbx.internal.flac_block_end(fi, max(tt, 1));
ig.flac = fi;
stat = ig.stat;
end
