function si = read_header(record, varargin)
%READ_HEADER Read the signal descriptions of a record.
%   SI = wfdbx.read_header(RECORD) reads the header of record RECORD
%   (relative to the input directory, or a full path, ~ path or URL) and
%   returns a 1-by-NSIG wfdbx.siginfo struct array describing its signals
%   (fname, desc, units, gain, fmt, spf, adcres, adczero, baseline,
%   nsamp, ...).  No signal file is opened.
%   An error is thrown if the header cannot be read.
%
%   SI = wfdbx.read_header(RECORD, 'input_dir', DIR, 'network', NET)
%   reads it with the input directory DIR and network access NET for
%   this call (see wfdbx.read_record).
%
%   SI = wfdbx.read_header(RECORD, 'legacy', true) reads the header as the
%   original package did, with the library's legacy mode
%   (wfdbx.wfdbx_set_legacy) on during the call: a missing ADC resolution
%   is inferred from the format or taken as 12 bits (default false: it is
%   0).  For compatibility only: the values it assumes are exactly the
%   silent defaults wfdb-x removed, so results produced with it carry the
%   same risks.
%
%   The function calls wfdbx.wfdbquit when it is done, so any
%   signals or annotators opened with the low-level functions
%   (wfdbx.isigopen, wfdbx.annopen, ...) are closed.
%
%   Example:
%       si = wfdbx.read_header('100s');
%       {si.desc}           % {'MLII', 'V5'}
%       [si.gain]           % ADC units per mV of each signal
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
[n, si] = wfdbx.isigopen(record, -n); %#ok<ASGLU>
wfdbx.wfdbquit();
end
