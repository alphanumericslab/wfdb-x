function previous = wfdbx_set_legacy(on)
%WFDBX_SET_LEGACY Turn the library's legacy mode on or off.
%   PREVIOUS = wfdbx.wfdbx_set_legacy(ON) turns legacy mode on if ON is
%   true (nonzero) and off otherwise, and returns the previous setting (1:
%   on, 0: off).  Legacy mode is off by default.
%
%   In legacy mode, the library behaves exactly as the original WFDB
%   library, with its built-in defaults: a header without a sampling
%   frequency means 250 Hz (WFDB_DEFFREQ), a missing ADC resolution is
%   inferred from the format or taken as 12 bits (WFDB_DEFRES), the time
%   conversion functions use 1 sample per second when no frequency is
%   known, setifreq reports "no open input record", and the unit conversion
%   functions assume a gain of 200 (WFDB_DEFGAIN; and a baseline of 0 for
%   invalid signal numbers).
%
%   Legacy mode is kept for compatibility only: the values it assumes are
%   exactly the silent defaults that wfdb-x removed, so results produced
%   with it carry the same risks (see docs/DIVERGENCES.md).  This function
%   is a wfdb-x addition.
%
%   Example:
%       old = wfdbx.wfdbx_set_legacy(1);
%       f = wfdbx.sampfreq('null');     % 250 for a header without frequency
%       wfdbx.wfdbx_set_legacy(old);
%
%   See also wfdbx.wfdbx_get_legacy, wfdbx.wfdbx_legacy_args.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
previous = S.legacy_mode;
S.legacy_mode = double(logical(on));
end
