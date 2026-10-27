function stat = sigmap_init(first_segment)
%SIGMAP_INIT Prepare the signal mapping of multi-segment records (sigmap_init).
%   STAT = wfdbx.internal.sigmap_init(FIRST_SEGMENT) sets up (for the
%   first segment of a variable-layout record) or updates (for later
%   segments) the mapping from the signals of the current segment to those
%   of the record, or copies the input signal information to vsd for
%   other records.  Returns 0 (or the number of signals), or -1 on error.
%
%   Translation of the C function sigmap_init() (lib/signal.c, WFDB 10.7.0).

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
WFDB_SAMPLE_MIN = -2147483648;  % INT_MIN
WFDB_SAMPLE_MAX = 2147483647;   % INT_MAX

S = wfdbx.internal.sig_state();
stat = 0;
if S.in_msrec && first_segment && ~isempty(S.segarray) && S.segarray(1).nsamp == 0
    S.need_sigmap = 1;
    S.nvsig = S.nisig;
    S.vspfmax = S.ispfmax;
    isd = S.isd;
    tspf = 0;
    for s = 1:S.nisig
        tspf = tspf + isd(s).info.spf;
    end
    S.tspf = tspf;
    m0 = struct('desc', [], 'gain', 0, 'scale', 0, 'offset', 0, ...
        'sample_offset', 0, 'baseline', 0, 'index', 0, 'spf', 0);
    smi = repmat(m0, 1, tspf);
    j = 0;
    for i = 1:S.nisig
        m = m0;
        m.desc = isd(i).info.desc;
        m.gain = isd(i).info.gain;
        m.baseline = isd(i).info.baseline;
        m.spf = isd(i).info.spf;
        smi(j + 1:j + m.spf) = m;
        j = j + m.spf;
    end
    S.smi = smi;
    S.ovec = zeros(1, tspf);
    stat = make_vsd(S);
elseif S.need_sigmap
    smi = S.smi;
    tspf = S.tspf;
    for s = 1:tspf
        smi(s).index = 0;
        smi(s).scale = 0;
        smi(s).offset = 0;
        smi(s).sample_offset = WFDB_INVALID_SAMPLE;
    end
    S.ispfmax = S.vspfmax;
    isd = S.isd;
    if isd(1).info.fmt == 0 && S.nisig == 1
        S.smi = smi;
        return;
    end
    j = 0;
    segname = S.segarray(S.segp + 1).recname;
    for i = 1:S.nisig
        isi = isd(i).info;
        s = 0;
        while s < tspf
            if streq(smi(s + 1).desc, isi.desc)
                kmax = smi(s + 1).spf;
                if kmax ~= isi.spf
                    wfdbx.internal.wfdb_error(['sigmap_init: unexpected spf ' ...
                        'for signal %d in segment %s\n'], i - 1, segname);
                    if kmax > isi.spf
                        kmax = isi.spf;
                    end
                end
                for k = 0:kmax - 1
                    ps = smi(s + k + 1);
                    ps.index = j + k;
                    ps.scale = ps.gain / isi.gain;
                    if ps.scale < 1
                        wfdbx.internal.wfdb_error(['sigmap_init: loss of ' ...
                            'precision in signal %d in segment %s\n'], i - 1, segname);
                    end
                    ps.offset = ps.baseline - ps.scale * isi.baseline + 0.5;
                    % If an offset can make all the output values fit
                    % in a positive int, sigmap uses its fast case.
                    bits = wfdbx.internal.fmt_bits(isi.fmt);
                    if bits == 0
                        bits = 32;          % the range of WFDB_Sample
                    end
                    ivmin = -2^(bits - 1);
                    ivmax = 2^(bits - 1) - 1;
                    ovmin = ivmin * ps.scale + ps.offset;
                    ovmax = ivmax * ps.scale + ps.offset;
                    if ovmin < ovmax && ovmin >= WFDB_SAMPLE_MIN + 1 && ...
                            ovmax <= WFDB_SAMPLE_MAX && ...
                            ovmax - ovmin + 1 < WFDB_SAMPLE_MAX
                        ps.sample_offset = fix(ovmin - 1);
                        ps.offset = ps.offset - ps.sample_offset;
                    else
                        ps.sample_offset = 0;
                    end
                    smi(s + k + 1) = ps;
                end
                break;
            end
            s = s + smi(s + 1).spf;
        end
        j = j + isi.spf;
    end
    S.smi = smi;
    if j > tspf
        wfdbx.internal.wfdb_error( ...
            'sigmap_init: frame size too large in segment %s\n', segname);
        stat = -1;
    end
elseif S.in_msrec && ~first_segment && S.framelen == 0
    S.ispfmax = S.vspfmax;
    if S.nisig > S.nvsig
        wfdbx.internal.wfdb_error( ...
            'sigmap_init: wrong number of signals in segment %s\n', ...
            S.segarray(S.segp + 1).recname);
        stat = -1;
        return;
    end
    for i = 1:S.nisig
        if S.isd(i).info.spf ~= S.vsd(i).info.spf
            wfdbx.internal.wfdb_error( ...
                'sigmap_init: wrong spf for signal %d in segment %s\n', ...
                i - 1, S.segarray(S.segp + 1).recname);
            stat = -1;
            return;
        end
    end
else
    S.nvsig = S.nisig;
    S.vspfmax = S.ispfmax;
    tspf = 0;
    for s = 1:S.nisig
        tspf = tspf + S.isd(s).info.spf;
    end
    S.tspf = tspf;
    stat = make_vsd(S);
end
end

function n = make_vsd(S)
if S.nvsig ~= S.nisig
    wfdbx.internal.wfdb_error('make_vsd: oops! nvsig = %d, nisig = %d\n', ...
        S.nvsig, S.nisig);
    n = -1;
    return;
end
vsd = repmat(wfdbx.internal.isdata(), 1, S.nvsig);
isd = S.isd;
for i = 1:S.nvsig
    vsd(i).info = isd(i).info;
    vsd(i).skew = isd(i).skew;
end
S.vsd = vsd;
n = S.nvsig;
end

function tf = streq(a, b)
% Equality of two C strings ([] is NULL).
if ischar(a) && ischar(b)
    tf = strcmp(a, b);
else
    tf = ~ischar(a) && ~ischar(b);
end
end
