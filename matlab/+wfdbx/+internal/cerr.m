function cerr(s)
%CERR Write bytes to the standard error output.
%   wfdbx.internal.cerr(S) flushes the buffered standard output (see
%   wfdbx.internal.cout), then writes the char (codes 0-255) or uint8 vector
%   S to the standard error output, byte for byte, unbuffered.
%
%   See also wfdbx.internal.ceprintf, wfdbx.internal.cout.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

wfdbx.internal.cout();
if isempty(s)
    return;
end
fwrite(2, s, 'uint8');
if wfdbx.internal.is_octave()
    fflush(2);
end
end
