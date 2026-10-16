function stat = osigclose()
%OSIGCLOSE Close the output signals (osigclose in signal.c).
%   STAT = wfdbx.internal.osigclose() flushes and closes the output
%   signal files and the output header; returns 0, or -4 on a write error.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
stat = 0;
ogd = S.ogd;
for g = 1:min(S.nogroup, numel(ogd))
    ogd{g}.force_flush = 1;
end
wfdbx.internal.wfdb_osflush();
S.osd = [];
S.nosig = 0;
for g = numel(ogd):-1:1
    og = ogd{g};
    if ~isempty(og.fp)
        flac = ~isempty(og.flac);
        if flac
            wfdbx.internal.flac_osclose(og);
        end
        if og.bsize && ~flac && numel(og.buf) < og.obuflen
            og.buf = [og.buf, zeros(1, og.obuflen - numel(og.buf), 'uint8')];
        end
        if ~isempty(og.buf)
            og.fp.write(og.buf);
            og.buf = zeros(1, 0, 'uint8');
        end
        if og.fp.is_std
            og.fp.flush();
        end
        errflag = og.fp.ferror();
        if ~og.fp.is_std
            if og.fp.close()
                errflag = true;
            end
            og.fp = [];
        end
        if errflag
            wfdbx.internal.wfdb_error( ...
                'osigclose: write error in signal group %d\n', g - 1);
            stat = -4;
        end
    end
end
S.ogd = {};
S.nogroup = 0;
S.ostime = 0;
if ~isempty(S.oheader)
    errflag = S.oheader.ferror();
    if S.oheader.close()
        errflag = true;
    end
    if errflag
        wfdbx.internal.wfdb_error('osigclose: write error in header file\n');
        stat = -4;
    end
    if S.outinfo_hdr
        S.outinfo = [];
        S.outinfo_hdr = false;
    end
    S.oheader = [];
end
if S.nisig == 0 && ~isempty(S.hsd)
    S.hsd = [];
end
end
