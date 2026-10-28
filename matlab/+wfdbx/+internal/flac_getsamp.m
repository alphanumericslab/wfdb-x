function v = flac_getsamp(ig)
%FLAC_GETSAMP The next sample of a FLAC input group (flac_getsamp).
%   V = wfdbx.internal.flac_getsamp(IG) returns the next sample of the
%   input group IG in frame order (see wfdbx.internal.flac_isopen).  At
%   the end of the data, 0 is returned and IG.stat is set to 0 (the first
%   time, a warning gives the number of samples left over that do not
%   fill a frame); after a decoding error, 0 is returned and IG.stat is
%   -2.  The next FLAC frame is decoded when no decoded sample is left.
%   After an error (IG.stat negative), the next frame decoded makes the
%   decoding stop ("getvec: unexpected FLAC decoding error" if no message
%   was given; IG.stat -2), as libFLAC aborts in the C library.  IG.stat
%   is not changed otherwise.
%
%   See also wfdbx.internal.flac_getsamps (many samples at once).
%
%   Translation of the C function flac_getsamp() (lib/signal.c, WFDB
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

fi = ig.flac;
p = fi.pos;
if p < fi.len
    fi.pos = p + 1;
    ig.flac = fi;
    v = fi.samples(p + 1);
    return;
end
v = 0;
if ~isempty(fi.pending)
    % (a failure found by decoding ahead: see flac_refill)
    ig.stat = fi.pending;
    fi.pending = [];
    ig.flac = fi;
    return;
end
fi = [];        %#ok<NASGU> (the samples are then appended in place)
if ~wfdbx.internal.flac_refill(ig)
    return;
end
fi = ig.flac;
p = fi.pos;
fi.pos = p + 1;
ig.flac = fi;
v = fi.samples(p + 1);
end
