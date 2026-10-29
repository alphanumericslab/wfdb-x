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
%   WFDB-x: hdr_dir is the directory of the header read last
%   (wfdbx.internal.wfdb_dirname; [] if unknown: the standard input);
%   msrec_dir and msrec_name are the directory and name of the header of
%   the current multi-segment record (msrec_name [] if there is none);
%   user_segments is true while setmsheader reads the headers of the
%   segments it was given; cksum_quiet is true while a high-level reader
%   reads (getvec then records its checksum message without printing it);
%   bulk_read and bulk_vectors are the switch and counter of the bulk
%   reader (wfdbx.internal.bulk_frames).
%
%   Part of the translation of lib/signal.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: fields hold the directory of the last header
% read, the directory and name of the current multi-segment record, the
% legacy-mode setting, whether checksum messages are quieted during a
% high-level read, and the switch and counter of the bulk reader. Each
% change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the
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

    properties
        % header data
        hsd = []
        hheader = []
        hdr_dir = []            % WFDB-x (see above)
        msrec_dir = []
        msrec_name = []
        user_segments = false
        cksum_quiet = false     % WFDB-x: true during a high-level read
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
        nigalloc = 0    % (C: the number of allocated input groups, igd[])
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
        empty_group = false     % a signal group whose frames hold no samples
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
        % WFDB-x: legacy mode (wfdbx.wfdbx_set_legacy; not reset by wfdbquit)
        legacy_mode = 0
        % WFDB-x: the bulk reader (wfdbx.internal.bulk_frames): off when
        % false (for the tests), and the number of vectors it has read
        % (neither is reset by wfdbquit); the samples it decodes at a time
        bulk_read = true
        bulk_vectors = 0
        bulk_block = 65536
    end
end
