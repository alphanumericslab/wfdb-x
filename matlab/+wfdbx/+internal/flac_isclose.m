function stat = flac_isclose(ig)
%FLAC_ISCLOSE Finish reading a FLAC input group (flac_isclose).
%   STAT = wfdbx.internal.flac_isclose(IG) checks, if the environment
%   variable WFDB_FLAC_CHECK_MD5 was set when the group was opened and the
%   whole stream was decoded without seeking, the MD5 signature of the
%   decoded samples against STREAMINFO ("isigclose: warning: incorrect MD5
%   hash in FLAC input", STAT -1); STAT is 0 otherwise.

% Original C implementation: the FLAC support of lib/signal.c, written by
% Benjamin Moody (2020); lib/signal.c is Copyright (C) 1989-2013 George
% B. Moody.
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

stat = 0;
fi = ig.flac;
if ~isempty(fi) && fi.md5_check && ~isempty(fi.md5) && ...
        ~isempty(fi.decoded_md5) && ~fi.seeked && any(fi.md5) && ...
        ~isequal(fi.md5, fi.decoded_md5)
    wfdbx.internal.wfdb_error('isigclose: warning: incorrect MD5 hash in FLAC input\n');
    stat = -1;
end
end
