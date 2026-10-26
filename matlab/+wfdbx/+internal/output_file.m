function p = output_file(name)
%OUTPUT_FILE The local file that an output file name designates.
%   P = wfdbx.internal.output_file(NAME) (wfdb-x) returns the name of the
%   local file that wfdb_open(NAME, [], WFDB_WRITE) creates in normal mode
%   (under the output directory, for a relative name), or [] if it creates
%   none (NAME empty, '-' for the standard output, or a URL).

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

p = [];
if ~ischar(name) || isempty(name) || strcmp(name, '-')
    return;
end
r = wfdbx.internal.expand_record(name);
if wfdbx.internal.is_url(r)
    return;
end
p = wfdbx.internal.resolve_name(r, true);
end
