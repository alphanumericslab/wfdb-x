function stat = osigfopen(si, nsig)
%OSIGFOPEN Open output signals as specified by signal descriptions.
%   N = wfdbx.osigfopen(SI) opens the output signals described by the
%   wfdbx.siginfo struct array SI (fields fname, desc, units, gain,
%   group, fmt, spf, bsize, adcres, adczero, baseline; the other fields
%   are ignored), closing any output signals open before.  Signals of the
%   same group (written in the same file) must be consecutive and have
%   the same file name.  N = wfdbx.osigfopen(SI, NSIG) opens the first
%   NSIG signals of SI.  Returns the number of signals opened, or a
%   negative value on error (and 0 if SI is empty).
%
%   Example:
%       si = wfdbx.siginfo(2);
%       [si.fname] = deal('out.dat'); [si.fmt] = deal(16);
%       wfdbx.osigfopen(si);
%       wfdbx.putvec([1 2]);
%       wfdbx.newheader('out');
%       wfdbx.wfdbquit();
%
%   See also wfdbx.osigopen, wfdbx.putvec, wfdbx.newheader.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

stat = wfdbx.internal.osigclose();
if nargin < 2
    nsig = numel(si);
end
if isempty(si) || nsig == 0
    return;
end
S = wfdbx.internal.sig_state();
if S.obsize <= 0
    S.obsize = 8192;
end
fmtlist = [0 8 16 61 80 160 212 310 311 24 32 508 516 524];
for s = 1:nsig
    x = si(s);
    lf = 0;
    if ischar(x.fname)
        lf = numel(x.fname);
    end
    ld = 0;
    if ischar(x.desc)
        ld = numel(x.desc);
    end
    if lf + ld > 200 || x.bsize < 0    % (limit as in C) || ~any(x.fmt == fmtlist)
        wfdbx.internal.wfdb_error('osigfopen: error in specification of signal %d\n', s - 1);
        stat = -2;
        return;
    end
    if ~((s == 1 && x.group == 0) || ...
            (s > 1 && x.group == si(s - 1).group && ...
            wfdbx.internal.cstreq(x.fname, si(s - 1).fname)) || ...
            (s > 1 && x.group == si(s - 1).group + 1 && ...
            ~wfdbx.internal.cstreq(x.fname, si(s - 1).fname)))
        wfdbx.internal.wfdb_error( ...
            'osigfopen: incorrect file name or group for signal %d\n', s - 1);
        stat = -2;
        return;
    end
end
stat = wfdbx.internal.openosig('osigfopen', si, nsig);
end
