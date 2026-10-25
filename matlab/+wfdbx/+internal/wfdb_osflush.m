function wfdb_osflush()
%WFDB_OSFLUSH Write the buffered output samples to the signal files.
%   wfdbx.internal.wfdb_osflush() (wfdb_osflush in signal.c) writes any
%   samples of incomplete bit-packed groups (rewinding the file so that
%   they are rewritten later, if it is seekable) and flushes the output
%   buffers.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
if isempty(S.osd) || isempty(S.ogd)
    return;
end
osd = S.osd;
ogd = S.ogd;
for s = 1:S.nosig
    og = ogd{osd(s).info.group + 1};
    if og.nrewind == 0
        if ~og.force_flush && og.seek == 0
            if og.bsize == 0 && ~isempty(og.fp) && og.fp.seek(0, 1) == 0
                og.seek = 1;
            else
                og.seek = -1;
            end
        end
        if og.force_flush || og.seek > 0
            switch osd(s).info.fmt
                case 212
                    if og.count == 1
                        w16(og, og.data);
                        og.nrewind = 2;
                    end
                case 310
                    if og.count == 1
                        w16(og, og.data);
                        og.nrewind = 2;
                    elseif og.count == 2
                        w16(og, og.data);
                        w16(og, og.datb);
                        og.nrewind = 4;
                    end
                case 311
                    if og.count == 1
                        w16(og, og.data);
                        og.nrewind = 2;
                    elseif og.count == 2
                        w16(og, og.datb);
                        og.nrewind = 2;
                    end
            end
        end
    end
end
for g = 1:S.nogroup
    og = ogd{g};
    if og.bsize == 0 && ~isempty(og.buf)
        if ~isempty(og.fp)
            og.fp.write(og.buf);
        end
        og.buf = zeros(1, 0, 'uint8');
    end
    if ~isempty(og.fp)
        og.fp.flush();
        if ~og.force_flush && og.nrewind ~= 0
            og.fp.seek(-og.nrewind, 1);
            og.nrewind = 0;
        end
    end
end
end

function w16(og, x)
x = mod(x, 65536);
wfdbx.internal.og_put(og, [mod(x, 256), floor(x / 256)]);
end
