function c = hl_input(d, net, fname)
%HL_INPUT Set the input directory and network access for one call.
%   C = wfdbx.internal.hl_input(D, NET, FNAME), where D and NET are the
%   'input_dir' and 'network' options of the high-level reader FNAME
%   (WFDB-x): if D is a char vector (a directory, a ~ name or a URL; ''
%   means the default), the library's input directory
%   (wfdbx.wfdbx_set_input_dir) is set to it; if NET is not [] (true or
%   false), network access (wfdbx.wfdbx_set_network) is allowed or
%   forbidden.  The onCleanup object C restores the previous settings
%   when it is cleared, i.e. when the calling function returns or throws
%   an error (C = [] if nothing was set).  An error is thrown for an
%   invalid option.
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

c = [];
set_dir = ischar(d);
if ~set_dir && ~isempty(d)
    error(['wfdbx:' fname], '%s: input_dir must be a directory name or URL', ...
        fname);
end
set_net = ~isempty(net);
if set_net && ~((islogical(net) || isnumeric(net)) && isscalar(net))
    error(['wfdbx:' fname], '%s: network must be true or false', fname);
end
if ~set_dir && ~set_net
    return;
end
previous_dir = [];
previous_net = [];
if set_dir
    previous_dir = wfdbx.wfdbx_set_input_dir(d);
end
if set_net
    previous_net = wfdbx.wfdbx_set_network(logical(net));
end
c = onCleanup(@() restore(set_dir, previous_dir, set_net, previous_net));
end

function restore(set_dir, previous_dir, set_net, previous_net)
if set_net
    wfdbx.wfdbx_set_network(previous_net);
end
if set_dir
    wfdbx.wfdbx_set_input_dir(previous_dir);
end
end
