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
prefix = cell(1, 0);
ptype = zeros(1, 0);
if ischar(p)
    n = numel(p);
    q = 1;
    while q <= n
        while q <= n && any(p(q) == [' ' char([9 10 13])])   % space, \t \n \r
            q = q + 1;
        end
        start = q;
        q = q - 1;
        current_type = 0;
        slashes = 0;
        while true
            q = q + 1;
            if q <= n
                c = p(q);
            else
                c = char(0);
            end
            if c == ':'
                if q + 2 <= n && p(q+1) == '/' && p(q+2) == '/'
                    current_type = 1;
                elseif current_type ~= 1 || slashes > 2
                    break;
                end
            elseif any(c == [';' ' ' char([9 10 13 0])])   % separators, as in C
                break;
            elseif c == '/'
                slashes = slashes + 1;
            end
        end
        prefix{end+1} = p(start:q-1); %#ok<AGROW>
        ptype(end+1) = current_type; %#ok<AGROW>
        if q <= n
            q = q + 1;
        end
    end
end
st.path_prefix = prefix;
st.path_type = ptype;
end
