function stat = putvec(vector)
%PUTVEC Write a sample to each output signal.
%   STAT = wfdbx.putvec(V) writes the samples V (a vector: one sample per
%   output signal, or spf samples for a signal with spf samples per
%   frame) to the open output signals.  Samples equal to
%   wfdbx.WFDB_INVALID_SAMPLE() are written as the invalid value of the
%   format.  STAT is the number of output signals, 0 if a format 8
%   difference was out of range (and clipped), or -1 on a write error.
%
%   See also wfdbx.osigfopen, wfdbx.osigopen, wfdbx.newheader.
%
%   Translation of the C function putvec() (lib/signal.c, WFDB 10.7.0): same
%   arguments and results.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
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

WFDB_INVALID_SAMPLE = -32768;

S = wfdbx.internal.sig_state();
nosig = S.nosig;
stat = nosig;
osd = S.osd;
ogd = S.ogd;
vi = 0;
gcur = -1;
og = [];
bytes = zeros(1, 64);       % the bytes of the frame for a group (grows)
nb = 0;
count = 0;
data = 0;
datb = 0;
for s = 1:nosig
    info = osd(s).info;
    g = info.group;
    if g ~= gcur
        if gcur >= 0
            stat = commit(og, bytes, nb, count, data, datb, stat, s - 1);
        end
        gcur = g;
        og = ogd{g + 1};
        count = og.count;
        data = og.data;
        datb = og.datb;
        nb = 0;
    end
    fmt = info.fmt;
    if info.nsamp == 0
        info.initval = vector(vi + 1);
        osd(s).samp = vector(vi + 1);
    end
    info.nsamp = info.nsamp + 1;
    cks = info.cksum;
    osamp = osd(s).samp;
    for c = 1:info.spf
        samp = vector(vi + 1);
        vi = vi + 1;
        if samp == WFDB_INVALID_SAMPLE  % the lowest value of the format
            bits = wfdbx.internal.fmt_bits(fmt);
            if bits > 0
                samp = -2^(bits - 1);
            end
        end
        if nb + 4 > numel(bytes)
            bytes(2 * numel(bytes)) = 0;
        end
        % The encoders of signal.c (w16, w212, ...): the bytes are taken
        % with mod/floor by powers of 2; bit masks are noted in hex.
        switch fmt
            case 0
                osamp = samp;
            case 16
                x = mod(samp, 65536);
                bytes(nb + 1:nb + 2) = [mod(x, 256), floor(x / 256)];
                nb = nb + 2;
                osamp = samp;
            case 212
                if count == 0
                    data = mod(samp, 4096);
                    count = 1;
                else
                    count = 0;
                    data = data + bitand(mod(samp * 16, 65536), 61440);   % 0xf000
                    bytes(nb + 1:nb + 3) = [mod(data, 256), floor(data / 256), ...
                        mod(samp, 256)];
                    nb = nb + 3;
                end
                osamp = samp;
            case 61
                x = mod(samp, 65536);
                bytes(nb + 1:nb + 2) = [floor(x / 256), mod(x, 256)];
                nb = nb + 2;
                osamp = samp;
            case 80
                bytes(nb + 1) = mod(mod(samp, 256) + 128, 256);
                nb = nb + 1;
                osamp = samp;
            case 160
                x = mod(mod(samp, 65536) + 32768, 65536);
                bytes(nb + 1:nb + 2) = [mod(x, 256), floor(x / 256)];
                nb = nb + 2;
                osamp = samp;
            case 310
                if count == 0
                    data = bitand(mod(samp * 2, 65536), 2046);    % 0x7fe
                    count = 1;
                elseif count == 1
                    datb = bitand(mod(samp * 2, 65536), 2046);
                    count = 2;
                else
                    count = 0;
                    data = mod(data + samp * 2048, 65536);
                    u = mod(samp * 64, 65536);
                    datb = mod(datb + u - bitand(u, 2046), 65536);
                    bytes(nb + 1:nb + 4) = [mod(data, 256), floor(data / 256), ...
                        mod(datb, 256), floor(datb / 256)];
                    nb = nb + 4;
                end
                osamp = samp;
            case 311
                if count == 0
                    data = bitand(mod(samp, 65536), 1023);        % 0x3ff
                    count = 1;
                elseif count == 1
                    data = mod(data + samp * 1024, 65536);
                    bytes(nb + 1:nb + 2) = [mod(data, 256), floor(data / 256)];
                    nb = nb + 2;
                    datb = mod(floor(samp / 64), 16);
                    count = 2;
                else
                    count = 0;
                    datb = mod(datb + samp * 16, 16384);          % 14 bits
                    bytes(nb + 1:nb + 2) = [mod(datb, 256), floor(datb / 256)];
                    nb = nb + 2;
                end
                osamp = samp;
            case 24
                x = mod(samp, 16777216);
                bytes(nb + 1:nb + 3) = [mod(x, 256), mod(floor(x / 256), 256), ...
                    floor(x / 65536)];
                nb = nb + 3;
                osamp = samp;
            case 32
                x = mod(samp, 4294967296);
                bytes(nb + 1:nb + 4) = [mod(x, 256), mod(floor(x / 256), 256), ...
                    mod(floor(x / 65536), 256), floor(x / 16777216)];
                nb = nb + 4;
                osamp = samp;
            case {508, 516, 524}
                if wfdbx.internal.flac_putsamp(samp, fmt, og) < 0
                    stat = -1;
                end
                osamp = samp;
            otherwise   % format 8 and default
                dif = samp - osamp;
                dif = dif - 4294967296 * floor((dif + 2147483648) / 4294967296);   % (int)
                if dif < -128
                    dif = -128;
                    stat = 0;
                elseif dif > 127
                    dif = 127;
                    stat = 0;
                end
                osamp = osamp + dif;
                osamp = osamp - 4294967296 * floor((osamp + 2147483648) / 4294967296);   % (int)
                bytes(nb + 1) = mod(dif, 256);
                nb = nb + 1;
        end
        cks = cks + osamp;
    end
    osd(s).samp = osamp;
    info.cksum = cks - 4294967296 * floor((cks + 2147483648) / 4294967296);   % (int)
    osd(s).info = info;
end
if gcur >= 0
    stat = commit(og, bytes, nb, count, data, datb, stat, nosig);
end
S.osd = osd;
S.ostime = S.ostime + 1;
end

function stat = commit(og, bytes, nb, count, data, datb, stat, s)
% Store the group state and write the bytes of the frame.
og.count = count;
og.data = data;
og.datb = datb;
if nb > 0
    wfdbx.internal.og_put(og, bytes(1:nb));
    if ~isempty(og.fp) && og.fp.ferror()
        wfdbx.internal.wfdb_error('putvec: write error in signal %d\n', s - 1);
        stat = -1;
    end
end
end
