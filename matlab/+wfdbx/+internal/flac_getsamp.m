function v = flac_getsamp(ig)
%FLAC_GETSAMP The next sample of a FLAC input group (flac_getsamp).
%   V = wfdbx.internal.flac_getsamp(IG) returns the next sample of the
%   input group IG in frame order (see wfdbx.internal.flac_isopen).  At
%   the end of the data, 0 is returned and IG.stat is set to 0 (the first
%   time, a warning gives the number of samples left over that do not
%   fill a frame); after a decoding error, 0 is returned and IG.stat is
%   -2.  After a failed seek (IG.stat negative), the next sample that
%   needs a FLAC block to be decoded makes the decoding fail ("getvec:
%   unexpected FLAC decoding error"; IG.stat -2), as libFLAC aborts in the
%   C library.  IG.stat is not changed otherwise.
%
%   See also wfdbx.internal.flac_getsamps (many samples at once).

% Original C implementation: the FLAC support of lib/signal.c, written by
% Benjamin Moody (2020); lib/signal.c is Copyright (C) 1989-2013 George
% B. Moody.
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

fi = ig.flac;
if ~fi.decoded
    fi = wfdbx.internal.flac_ensure(ig);
end
if ~isempty(fi.error)
    ig.stat = -2;
    v = 0;
    return;
end
v = 0;
if fi.aborted
    return;     % (the decoder does nothing; ig.stat is negative)
end
p = fi.pos;
if p < numel(fi.samples)
    % The frame of the next sample must have been decoded.
    need = fi.base + (floor(p / (fi.nsig * fi.spf)) + 1) * fi.spf;
    if fi.discarded || need > fi.dec_end
        if ig.stat < 0
            if fi.dec_end < fi.total
                flac_abort(ig);
            end
            return;
        end
        fi.dec_end = wfdbx.internal.flac_block_end(fi, need);
    end
    fi.pos = p + 1;
    ig.flac = fi;
    v = fi.samples(p + 1);
    return;
end
if fi.discarded && fi.dec_end < fi.total
    flac_abort(ig);
    return;
end
if ig.stat < 0
    return;
end
fi.dec_end = fi.total;
if fi.leftover
    wfdbx.internal.wfdb_error( ...
        'getvec: warning: %d samples left over at end of file\n', fi.leftover);
    fi.leftover = 0;
end
ig.flac = fi;
ig.stat = 0;
v = 0;
end

function flac_abort(ig)
% Decoding a block after a failed seek (ig.stat < 0): iflac_samples()
% aborts the decoder, and flac_getsamp() reports the error.
fi = ig.flac;
fi.aborted = true;
ig.flac = fi;
if ig.stat ~= -2
    wfdbx.internal.wfdb_error('getvec: unexpected FLAC decoding error\n');
    ig.stat = -2;
end
end
