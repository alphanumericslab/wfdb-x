function hdr = read_header(record, varargin)
%READ_HEADER Read the header of a record.
%   HDR = wfdbx.read_header(RECORD) reads the header of the record RECORD
%   without opening its signal files.  RECORD is a record name read from the
%   input directory, or a full path, a ~ path or a URL.
%
%   HDR = wfdbx.read_header(RECORD, NAME, VALUE, ...) takes the options
%   'input_dir', 'network' and 'legacy' of wfdbx.read_record.
%
%   HDR has these fields:
%
%     name          the record name
%     fs            sampling frequency in Hz (0 if the header gives none)
%     counter_freq  counter frequency
%     base_counter  base counter value
%     nsamples      number of samples per signal (0 if the header does not
%                   give the length)
%     nsig          number of signals
%     siginfo       the signal specifications, a wfdbx.siginfo structure
%                   array (fname, desc, units, gain, fmt, spf, adcres,
%                   adczero, baseline, nsamp, ...; desc without the white
%                   space that a header may put at either end of it)
%     base_time, base_time_ms, base_date, comments
%                   as in wfdbx.read_record
%
%   Errors: an error (identifier 'wfdbx:read_header') is thrown if the
%   header cannot be read.
%
%   The function calls wfdbx.wfdbquit, which closes anything opened with the
%   WFDB library functions.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       hdr = wfdbx.read_header('100s');
%       hdr.fs                      % 360
%       {hdr.siginfo.desc}          % {'MLII', 'V5'}
%       [hdr.siginfo.gain]          % [200 200]
%
%   See also wfdbx.read_record, wfdbx.isigopen.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

record = wfdbx.internal.strarg(record);
opt = wfdbx.internal.hl_options(struct('input_dir', [], 'network', [], ...
    'legacy', false), varargin, 'read_header');
legacy = wfdbx.internal.hl_legacy(opt.legacy, 'read_header'); %#ok<NASGU>
% wfdb-x: the input directory and network access for this call
restore_input = wfdbx.internal.hl_input(opt.input_dir, opt.network, 'read_header'); %#ok<NASGU>
n = wfdbx.isigopen(record, 0);
if n < 0
    wfdbx.wfdbquit();
    error('wfdbx:read_header', 'can''t read header for record %s', record);
end
[n, si] = wfdbx.isigopen(record, -n);
S = wfdbx.internal.sig_state();
hdr.name = record;
hdr.fs = wfdbx.sampfreq([]);
hdr.counter_freq = wfdbx.getcfreq();
hdr.base_counter = wfdbx.getbasecount();
% (the record line's sample count; that of the master header of a
% multi-segment record, as strtim('e') gives it in WFDB_LOWRES mode)
if S.in_msrec
    hdr.nsamples = double(S.msnsamples);
else
    hdr.nsamples = double(S.nsamples);
end
hdr.nsig = n;
% wfdb-x: the signal names without the white space at their ends
hdr.siginfo = wfdbx.internal.strip_desc(si);
[hdr.base_time, hdr.base_time_ms, hdr.base_date] = ...
    wfdbx.internal.hl_basetime(hdr.fs);
comments = cell(0, 1);
c = wfdbx.getinfo(record);
while ischar(c)
    comments{end + 1, 1} = c; %#ok<AGROW>
    c = wfdbx.getinfo([]);
end
hdr.comments = comments;
wfdbx.wfdbquit();
end
