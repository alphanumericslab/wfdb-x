function wfdb_parse_path(p)
%WFDB_PARSE_PATH Split a WFDB path into its components.
%   wfdbx.internal.wfdb_parse_path(P) parses the WFDB path P (components
%   separated by white space or ';', or by ':' for local directories) and
%   stores the components and their types (local or network) in
%   wfdbx.internal.io_state() (path_prefix, path_type).

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.io_state();
[st.path_prefix, st.path_type] = wfdbx.internal.path_components(p);
end
