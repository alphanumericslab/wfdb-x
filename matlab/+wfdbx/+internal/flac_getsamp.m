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
%
%   Translation of the C function flac_getsamp() (lib/signal.c, WFDB
%   10.7.0).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of the FLAC support of lib/signal.c (the
% code that connects FLAC to the signal functions) from the WFDB Software
% Package 10.7.0, by Benjamin Moody (2020). The translation follows the logic
% and behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c (FLAC support), WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by
%   Benjamin Moody, including FLAC support (2020).
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

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
