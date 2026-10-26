function fid = std_stream(k)
%STD_STREAM File identifier for the standard output (K = 1) or error (K = 2).
%   FID = wfdbx.internal.std_stream(K) returns the file to which cout and
%   cerr write the bytes of the standard output or error.  It is the file
%   named by the environment variable WFDBX_STDOUT (K = 1) or WFDBX_STDERR
%   (K = 2) if that is set, opened once for binary writing, and otherwise
%   K itself.  The MATLAB driver (bin/wfdbx_matlab.sh) sets these variables:
%   MATLAB writes to file identifier 1 through its Command Window, as text
%   (a NUL byte becomes a space, and bytes above 127 are encoded as UTF-8),
%   so the bytes are written to these files and copied by the driver to the
%   real standard output and error once MATLAB has exited.  (The startup
%   messages MATLAB itself prints are then kept out of the output, too.)

% Part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

persistent fids
if isempty(fids)
    fids = [0 0];
end
if fids(k) == 0
    fids(k) = k;
    names = {'WFDBX_STDOUT', 'WFDBX_STDERR'};
    name = getenv(names{k});
    if ~isempty(name)
        f = fopen(name, 'w', 'ieee-le');
        if f >= 0
            fids(k) = f;
        end
    end
end
fid = fids(k);
end
