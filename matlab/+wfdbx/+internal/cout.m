function cout(s, opt, val)
%COUT Write bytes to the standard output (buffered).
%   wfdbx.internal.cout(S) writes the char (codes 0-255) or uint8 vector S
%   to the standard output, byte for byte.  Output is buffered for speed;
%   the buffer is written when it grows large, when wfdbx.internal.cerr
%   writes to the standard error, when a tool run by wfdbx.internal.app_run
%   returns, and by the command-line drivers before they exit.
%
%   wfdbx.internal.cout() writes the buffer (flushes the standard output).
%
%   wfdbx.internal.cout('', 'buffered', TF) turns buffering on (TF true,
%   the default) or off (each call writes immediately).
%
%   If the standard output cannot be written (a failure that can be
%   detected: see wfdbx.internal.std_stream), the rest of the output is
%   dropped, silently, and the failure is noted (the property
%   stdout_failed of wfdbx.internal.io_state(); wfdbx.internal.app_run
%   reports it).
%
%   Tools must write their output only with cout/cprintf (or cerr/ceprintf
%   for the standard error), never with fprintf or disp.
%
%   See also wfdbx.internal.cprintf, wfdbx.internal.cerr.
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

MAXPARTS = 1024;        % write the buffer when it holds this many strings
MAXBYTES = 262144;      % ... or this many bytes (256 KiB)

persistent parts n nbytes buffered failed
if isempty(n)
    parts = cell(1, MAXPARTS);
    n = 0;
    nbytes = 0;
    buffered = true;
    failed = false;
end
if nargin == 0
    if n > 0
        data = [parts{1:n}];
        parts(1:n) = {[]};
        n = 0;
        nbytes = 0;
        failed = write_out(data, failed);
    end
    return;
end
if nargin >= 3 && strcmp(opt, 'buffered')
    buffered = logical(val);
end
if isempty(s)
    if ~buffered
        wfdbx.internal.cout();
    end
    return;
end
if ~ischar(s)
    s = char(s);
end
n = n + 1;
parts{n} = s(:)';
nbytes = nbytes + numel(s);
if n == MAXPARTS || nbytes >= MAXBYTES || ~buffered
    data = [parts{1:n}];
    parts(1:n) = {[]};
    n = 0;
    nbytes = 0;
    failed = write_out(data, failed);
end
end

function failed = write_out(data, failed)
% write data, unless the standard output has failed; true if it has
if failed
    return;
end
[fid, check] = wfdbx.internal.std_stream(1);
k = fwrite(fid, data, 'uint8');
if ~check
    % (a failure cannot be detected)
    if wfdbx.internal.is_octave()
        fflush(fid);
    end
    return;
end
% (fseek flushes the file and reports a failure, Octave's fflush does not)
if k < numel(data) || fseek(fid, 0, 'cof') ~= 0
    failed = true;
    st = wfdbx.internal.io_state();
    st.stdout_failed = true;
end
end
