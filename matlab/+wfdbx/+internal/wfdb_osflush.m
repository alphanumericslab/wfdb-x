function wfdb_osflush()
%WFDB_OSFLUSH Write the buffered output samples to the signal files.
%   wfdbx.internal.wfdb_osflush() (wfdb_osflush in signal.c) writes any
%   samples of incomplete bit-packed groups (rewinding the file so that
%   they are rewritten later, if it is seekable) and flushes the output
%   buffers.
%
%   Translation of the C function wfdb_osflush() (lib/signal.c, WFDB
%   10.7.0).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

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
