function fi = flac_ensure(ig)
%FLAC_ENSURE Decode the FLAC stream of an input group (once).
%   FI = wfdbx.internal.flac_ensure(IG) decodes the whole FLAC stream of
%   the input group IG (from its file IG.fp) on the first call, and
%   returns IG.flac.  Decoding errors are reported as getvec does
%   ("getvec: unable to decode FLAC ..."), and recorded in FI.error.

% Original C implementation: the FLAC support of lib/signal.c, written by
% Benjamin Moody (2020); lib/signal.c is Copyright (C) 1989-2013 George
% B. Moody.
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
