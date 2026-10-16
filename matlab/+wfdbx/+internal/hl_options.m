function opt = hl_options(opt, args, fname)
%HL_OPTIONS Parse name-value pairs (high-level API).
%   OPT = wfdbx.internal.hl_options(OPT, ARGS, FNAME) sets the fields of
%   the structure OPT (the defaults) from the name-value pairs of the cell
%   ARGS (names are case-insensitive and must be fields of OPT).  MATLAB
%   strings are converted to char (wfdbx.internal.strarg).  Errors
%   mention FNAME.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if mod(numel(args), 2) ~= 0
    error(['wfdbx:' fname], '%s: options must be name-value pairs', fname);
end
for k = 1:2:numel(args)
    name = wfdbx.internal.strarg(args{k});
    if ~ischar(name) || ~isfield(opt, lower(name))
        if ischar(name)
            error(['wfdbx:' fname], '%s: unknown option ''%s''', fname, name);
        end
        error(['wfdbx:' fname], '%s: option names must be strings', fname);
    end
    opt.(lower(name)) = wfdbx.internal.strarg(args{k + 1});
end
end
