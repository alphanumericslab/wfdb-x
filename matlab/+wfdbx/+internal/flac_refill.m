function ok = flac_refill(ig, ahead)
%FLAC_REFILL Decode FLAC frames until more samples are available.
%   OK = wfdbx.internal.flac_refill(IG) decodes the frames of the FLAC
%   input group IG until samples are added to those not yet returned, as
%   flac_getsamp does when none is left.  OK is false at the end of the
%   data (IG.stat 0, with a warning if samples are left over that do not
%   fill a frame) or after an error (IG.stat -2, with a message).
%
%   OK = wfdbx.internal.flac_refill(IG, true) decodes ahead, for the bulk
%   readers, while decoded samples may remain: the outcome of a failure
%   (IG.stat) is then deferred, so that the samples decoded before it are
%   returned as they would be, and the next call of flac_getsamp that
%   finds no sample left gives the failure without decoding.  (The FLAC
%   decoder does not depend on the samples that have been returned, so
%   decoding a frame earlier gives the same results.)
%
%   Part of the translation of the FLAC support of lib/signal.c (WFDB
%   10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
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

if nargin > 1 && ahead
    old = ig.stat;
    ok = wfdbx.internal.flac_refill(ig);
    if ~ok
        fi = ig.flac;
        fi.pending = ig.stat;
        ig.flac = fi;
        ig.stat = old;
    end
    return;
end
ok = false;
fi = ig.flac;
if isempty(fi.dec)
    fi.dec = wfdbx.internal.flac_dec_open(ig);
    ig.flac = fi;
end
D = fi.dec;
n0 = fi.len - fi.pos;
while fi.len - fi.pos <= n0
    oldcount = size(fi.partial, 2);
    fi = [];        % (the samples are then appended in place)
    [D, good] = wfdbx.internal.flac_decoder('process', D);
    fi = ig.flac;           % (with the samples decoded)
    fi.dec = D;
    ig.flac = fi;
    if ~good
        if ig.stat ~= -2
            wfdbx.internal.wfdb_error('getvec: unexpected FLAC decoding error\n');
            ig.stat = -2;
        end
        return;
    end
    if ig.stat <= 0
        return;
    end
    count = size(fi.partial, 2);
    if fi.len - fi.pos <= n0 && count == oldcount
        st = D.state;
        if st == 4          % END_OF_STREAM
            if count
                wfdbx.internal.wfdb_error(['getvec: warning: %d samples ' ...
                    'left over at end of file\n'], count);
            end
            fi.partial = [];
            ig.flac = fi;
            ig.stat = 0;
            return;
        end
        if st > 2           % (not looking for metadata or a frame)
            wfdbx.internal.wfdb_error('getvec: unknown FLAC decoding state\n');
            ig.stat = -2;
            return;
        end
    end
end
ok = true;
end
