function fi = flac_ensure(ig)
%FLAC_ENSURE Decode the FLAC stream of an input group (once).
%   FI = wfdbx.internal.flac_ensure(IG) decodes the whole FLAC stream of
%   the input group IG (from its file IG.fp) on the first call, and
%   returns IG.flac.  Decoding errors are reported as getvec does
%   ("getvec: unable to decode FLAC ..."), and recorded in FI.error.
%
%   Part of the translation of the FLAC support of lib/signal.c (WFDB
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
if fi.decoded
    return;
end
fi.decoded = true;
try
    [arr, bps, md5, ~, fi.block_ends] = wfdbx.internal.flac_decode( ...
        ig.fp.readall(), fi.nsig, fi.datb);
    fi.md5 = md5;
    n = size(arr, 2);
    if n == 0
        arr = zeros(fi.nsig, 0);
    end
    if fi.md5_check && n
        nb = floor((bps + 7) / 8);
        b = reshape(typecast(int32(reshape(arr, 1, [])), 'uint8'), 4, []);
        b = b(1:nb, :);
        fi.decoded_md5 = wfdbx.internal.md5(b(:)');
    end
    fi.arr = arr;
    fi.total = n;
    fi = wfdbx.internal.flac_pack(fi, 0);
catch err
    id = err.identifier;
    if ~strncmp(id, 'wfdbx:flac:', 11)
        rethrow(err);
    end
    status = id(12:end);
    switch status
        case 'sync'
            wfdbx.internal.wfdb_error('getvec: unable to decode FLAC (lost sync)\n');
        case 'header'
            wfdbx.internal.wfdb_error('getvec: unable to decode FLAC (invalid header)\n');
        case 'crc'
            wfdbx.internal.wfdb_error('getvec: unable to decode FLAC (CRC mismatch)\n');
        case 'unparseable'
            wfdbx.internal.wfdb_error('getvec: unable to decode FLAC (unsupported format)\n');
        case 'eof'
            wfdbx.internal.wfdb_error('getvec: unable to decode FLAC\n');
        case 'meta'
            wfdbx.internal.wfdb_error('getvec: unexpected FLAC decoding error\n');
    end
    fi.error = status;
    fi.samples = zeros(1, 0);
end
ig.flac = fi;
end
