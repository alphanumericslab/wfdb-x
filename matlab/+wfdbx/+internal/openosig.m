function [nsig, si_out] = openosig(func, si_in, nsig)
%OPENOSIG Open output signals (openosig in signal.c).
%   [N, SI] = wfdbx.internal.openosig(FUNC, SI_IN, NSIG) opens NSIG output
%   signals described by the wfdbx.siginfo struct array SI_IN; FUNC is
%   the name of the calling function (for messages).  Returns NSIG and
%   the descriptions of the signals opened, or a negative value on error.
%
%   Translation of the C function openosig() (lib/signal.c, WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: outside legacy mode, an output signal file that
% is one of the files of the open input record is refused ("output file NAME
% is also an input file"), so that it is neither created nor truncated. Each
% change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the
% reasons.
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
si_out = wfdbx.siginfo(0);
if S.obsize <= 0
    S.obsize = 8192;    % BUFSIZ
end
ga = S.nogroup;
ogd = S.ogd;
while numel(ogd) < S.nogroup + si_in(nsig).group + 1
    ogd{end + 1} = wfdbx.internal.OGData(); %#ok<AGROW>
end
S.ogd = ogd;
op = [];
for s = 1:nsig
    sin = si_in(s);
    os = struct('info', sin, 'samp', 0, 'skew', 0);
    if os.info.spf < 1
        os.info.spf = 1;
    end
    os.info.cksum = 0;
    os.info.nsamp = 0;
    os.info.group = os.info.group + ga;
    if isempty(S.osd)
        S.osd = os;
    else
        S.osd(end + 1) = os;
    end
    S.nosig = S.nosig + 1;
    k = numel(S.osd);
    si_out(end + 1) = os.info; %#ok<AGROW>
    if s == 1 || os.info.group ~= op.info.group
        og = ogd{os.info.group + 1};
        og.bsize = os.info.bsize;
        isflac = os.info.fmt >= 500 && os.info.fmt <= 532;     % FLAC formats
        if isflac
            ns = 1;
            while s + ns <= nsig && si_in(s + ns).group == sin.group
                ns = ns + 1;
            end
            if ~wfdbx.internal.pkg_has('internal.flac_osinit')
                wfdbx.internal.wfdb_error('%s: FLAC formats are not supported\n', func);
                wfdbx.internal.osigclose();
                nsig = -3;
                return;
            end
            if wfdbx.internal.flac_osinit(og, si_in(s:s + ns - 1), ns) < 0
                wfdbx.internal.osigclose();
                nsig = -3;
                return;
            end
        end
        if og.bsize
            og.obuflen = og.bsize;
        else
            og.obuflen = S.obsize;
        end
        og.buf = zeros(1, 0, 'uint8');
        if os.info.fmt == 0
            if ~ischar(os.info.fname) || strcmp(os.info.fname, '~')
                og.fp = [];
            else
                os.info.fmt = 16;
                S.osd(k).info.fmt = 16;
            end
        end
        if os.info.fmt ~= 0
            % wfdb-x: never one of the input files (see is_input_file)
            if ~S.legacy_mode && wfdbx.internal.is_input_file(os.info.fname)
                wfdbx.internal.wfdb_error( ...
                    '%s: output file %s is also an input file\n', func, ...
                    os.info.fname);
                wfdbx.internal.osigclose();
                nsig = -3;
                return;
            end
            og.fp = wfdbx.internal.wfdb_open(os.info.fname, [], 1);   % WFDB_WRITE
            if isempty(og.fp)
                wfdbx.internal.wfdb_error('%s: can''t open %s\n', func, os.info.fname);
                wfdbx.internal.osigclose();
                nsig = -3;
                return;
            end
        end
        if isflac
            if wfdbx.internal.flac_osopen(og) < 0
                wfdbx.internal.osigclose();
                nsig = -3;
                return;
            end
        end
        S.nogroup = S.nogroup + 1;
    else
        if os.info.fmt ~= op.info.fmt || os.info.bsize ~= op.info.bsize
            wfdbx.internal.wfdb_error( ...
                '%s: error in specification of signal %d or %d\n', func, s - 2, s - 1);
            nsig = -2;
            return;
        end
    end
    op = os;
end
end
