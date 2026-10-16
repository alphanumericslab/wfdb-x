function args = hexargs(hex)
%HEXARGS Decode command-line arguments passed as hexadecimal strings.
%   ARGS = wfdbx.internal.hexargs(HEX) converts a cell array of strings of
%   hexadecimal digits (two per byte, as written by `od -tx1`) into a cell
%   row of char vectors with those bytes.  bin/wfdbx_matlab.sh passes the
%   arguments of a tool to MATLAB this way, so that any bytes (quotes,
%   non-ASCII characters) arrive unchanged.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

args = cell(1, numel(hex));
for k = 1:numel(hex)
    h = hex{k};
    if isempty(h)
        args{k} = '';
    else
        args{k} = char(hex2dec(reshape(h, 2, [])')');
    end
end
end
