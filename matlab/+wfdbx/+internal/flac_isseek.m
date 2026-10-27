function stat = flac_isseek(ig, t)
%FLAC_ISSEEK Seek to a frame of a FLAC input group (flac_isseek).
%   STAT = wfdbx.internal.flac_isseek(IG, T) positions the input group IG
%   at frame T (counted from IG.start samples into the stream); it
%   returns IG.stat (1), or -1 if T is out of range or the stream cannot
%   be decoded.
%
%   Translation of the C function flac_isseek() (lib/signal.c, WFDB 10.7.0).

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
