function [nsig, si_out] = openosig(func, si_in, nsig)
%OPENOSIG Open output signals (openosig in signal.c).
%   [N, SI] = wfdbx.internal.openosig(FUNC, SI_IN, NSIG) opens NSIG output
%   signals described by the wfdbx.siginfo struct array SI_IN; FUNC is
%   the name of the calling function (for messages).  Returns NSIG and
%   the descriptions of the signals opened, or a negative value on error.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
