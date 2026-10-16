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
%   Tools must write their output only with cout/cprintf (or cerr/ceprintf
%   for the standard error), never with fprintf or disp.
%
%   See also wfdbx.internal.cprintf, wfdbx.internal.cerr.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

MAXPARTS = 1024;        % write the buffer when it holds this many strings
MAXBYTES = 262144;      % ... or this many bytes (256 KiB)

persistent parts n nbytes buffered
if isempty(n)
    parts = cell(1, MAXPARTS);
    n = 0;
    nbytes = 0;
    buffered = true;
end
if nargin == 0
    if n > 0
        data = [parts{1:n}];
        parts(1:n) = {[]};
        n = 0;
        nbytes = 0;
        write_out(data);
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
    write_out(data);
end
end

function write_out(data)
fwrite(1, data, 'uint8');
if wfdbx.internal.is_octave()
    fflush(1);
end
end
