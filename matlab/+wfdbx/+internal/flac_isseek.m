function stat = flac_isseek(ig, t)
%FLAC_ISSEEK Seek to a frame of a FLAC input group (flac_isseek).
%   STAT = wfdbx.internal.flac_isseek(IG, T) positions the input group IG
%   at frame T (counted from IG.start samples into the stream); it
%   returns IG.stat (1), or -1 if T is out of range or libFLAC's seek
%   fails.  The samples decoded are discarded; the seek decodes the frame
%   that holds the sample before frame T (sample 0 for frame 0), and that
%   sample is discarded.
%
%   Translation of the C function flac_isseek() (lib/signal.c, WFDB 10.7.0).

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

fi = ig.flac;
if isempty(fi.dec)
    fi.dec = wfdbx.internal.flac_dec_open(ig);
end
D = fi.dec;
if D.state == 6         % SEEK_ERROR
    D = wfdbx.internal.flac_decoder('flush', D);
end
fi.samples = zeros(1, 0);
fi.len = 0;
fi.pos = 0;
fi.partial = [];
fi.skip = 0;
fi.pending = [];
ig.stat = 1;
ig.count = 0;
% (seeking to the sample before the target, then discarding it, allows a
% seek to the end of the stream)
tt = t * fi.spf + ig.start;
if tt ~= 0
    tt = tt - 1;
    fi.skip = 1;
end
ig.flac = fi;
[D, ok] = wfdbx.internal.flac_decoder('seek', D, tt);
fi = ig.flac;
fi.dec = D;
ig.flac = fi;
if ~ok
    ig.stat = -1;
end
stat = ig.stat;
end
