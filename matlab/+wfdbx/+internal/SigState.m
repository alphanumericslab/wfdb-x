classdef SigState < handle
%SIGSTATE Global state of the WFDB signal module (the statics of signal.c).
%   The single instance is returned by wfdbx.internal.sig_state().  Its
%   properties have the names of the static variables of lib/signal.c (as
%   in the Python port's _SigState).  Per-signal data are struct arrays:
%
%     hsd  header data: fields info (a wfdbx.siginfo structure), start, skew
%     isd  input signals: info, samp, skew, gvindex, gvcount
%     vsd  the same, for the signals returned by getvec (sigmap)
%     osd  output signals: info, samp, skew
%     smi  variable-layout mapping: desc, gain, scale, offset,
%          sample_offset, baseline, index (0-based), spf
%
%   Signal groups are cell rows of handle objects: igd (wfdbx.internal.IGData)
%   and ogd (wfdbx.internal.OGData); group number g (0-based, as in
%   siginfo.group) is igd{g+1}.  segarray is a wfdbx.seginfo struct array
%   ([] if none) and segp the 0-based index of the current segment.
%   hheader, oheader and outinfo are WFDBFile objects or [].

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

    properties
        % header data
        hsd = []
        hheader = []
        % timing
        ffreq = 0
        ifreq = 0
        sfreq = 0
        cfreq = 0
        spfmax = 0
        btime = 0
        bdate = 0
        nsamples = 0
        bcount = 0
        prolog_bytes = 0
        % multi-segment records
        segments = 0
        in_msrec = 0
        msbtime = 0
        msbdate = 0
        msnsamples = 0
        segarray = []
        segp = 0
        segend = 0
        % input signals
        isd = []
        igd = {}
        nisig = 0
        nigroup = 0
        ispfmax = 0
        tvector = []
        uvector = []
        vvector = []
        tuvlen = 0
        istime = 0
        ibsize = 0
        skewmax = 0
        dsbuf = []
        has_dsbuf = false
        dsbi = -1
        dsblen = 0
        framelen = 0
        plan = []               % cached per-signal constants (getskewedframe)
        skip_pending = false    % some input group has initial_skip set
        gvmode = 0
        gvc = 0
        isedf = 0
        sbuf = []
        sample_vflag = 0
        sample_tt = -1
        % output signals
        osd = []
        ogd = {}
        nosig = 0
        nogroup = 0
        oheader = []
        outinfo = []
        outinfo_hdr = false     % true if outinfo is oheader
        ostime = 0
        obsize = 0
        % info strings
        pinfo = []
        has_pinfo = false
        ninfo = 0
        info_i = 0
        % variable layout (sigmap)
        need_sigmap = 0
        nvsig = 0
        tspf = 0
        vspfmax = 0
        vsd = []
        ovec = []
        smi = []
        % getvec resampling
        mticks = 0
        nticks = 0
        mnticks = 0
        rgvstat = 0
        rgvtime = 0
        gvtime = 0
        gv0 = []
        gv1 = []
        rgetvec_stat = 0
        % time/date strings
        date_string = ''
        time_string = ''
        pdays = -1
        % wfdb-x: legacy mode (wfdbx.wfdbx_set_legacy; not reset by wfdbquit)
        legacy_mode = 0
    end
end
