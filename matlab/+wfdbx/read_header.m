function hdr = read_header(record, varargin)
%READ_HEADER Read the header of a record.
%   HDR = wfdbx.read_header(RECORD) reads the header of record RECORD
%   (relative to the input directory, or a full path, ~ path or URL) and
%   returns a structure with the fields
%
%     name          the record name, as given
%     fs            sampling frequency (Hz), as wfdbx.sampfreq gives it (0
%                   if the header does not specify it)
%     counter_freq  counter frequency, as wfdbx.getcfreq gives it
%     base_counter  base counter value, as wfdbx.getbasecount gives it
%     nsamples      number of samples per signal given by the header's
%                   record line (0 if the header does not give it)
%     nsig          number of signals
%     siginfo       1-by-NSIG wfdbx.siginfo struct array describing the
%                   signals (fname, desc, units, gain, fmt, spf, adcres,
%                   adczero, baseline, nsamp, ...)
%     base_time     start time and date, as wfdbx.timstr(0) gives it
%                   (e.g. '[08:45:00 01/01/2001]'), or [] (as in
%                   wfdbx.read_record)
%     base_time_ms  the base time in milliseconds after midnight (a
%                   double: '14:00:03.500' is 50403500), or [] exactly
%                   when base_time is []
%     base_date     the base date as a 1-by-3 double [year month day], or
%                   [] if the header gives no date
%     comments      NC-by-1 cell of the info strings (header comments, as
%                   in wfdbx.read_record)
%
%   No signal file is opened.  An error is thrown if the header cannot be
%   read.
%
%   HDR = wfdbx.read_header(RECORD, 'input_dir', DIR, 'network', NET)
%   reads it with the input directory DIR and network access NET for
%   this call (see wfdbx.read_record).
%
%   HDR = wfdbx.read_header(RECORD, 'legacy', true) reads the header as
%   the original package did, with the library's legacy mode
%   (wfdbx.wfdbx_set_legacy) on during the call: a missing sampling
%   frequency is 250 Hz, and a missing ADC resolution is inferred from
%   the format or taken as 12 bits (default false: they are 0).  For
%   compatibility only: the values it assumes are exactly the silent
%   defaults wfdb-x removed, so results produced with it carry the same
%   risks.
%
%   The function calls wfdbx.wfdbquit when it is done, so any
%   signals or annotators opened with the low-level functions
%   (wfdbx.isigopen, wfdbx.annopen, ...) are closed.
%
%   Example:
%       hdr = wfdbx.read_header('100s');
%       hdr.fs                      % 360
%       {hdr.siginfo.desc}          % {'MLII', 'V5'}
%       [hdr.siginfo.gain]          % ADC units per mV of each signal
%
%   See also wfdbx.read_record, wfdbx.isigopen.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
hdr.siginfo = si;
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
