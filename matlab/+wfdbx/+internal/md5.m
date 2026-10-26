function d = md5(data)
%MD5 The MD5 message digest of a byte vector.
%   D = wfdbx.internal.md5(DATA) returns the 16-byte MD5 digest (uint8
%   row) of the bytes DATA (a uint8 or char vector).  Octave's built-in
%   hash function, or Java's MessageDigest in MATLAB, is used when
%   available (they are much faster); otherwise the MATLAB implementation
%   wfdbx.internal.md5_pure.  All give the same result.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

persistent mode
if isempty(mode)
    mode = 0;
    if wfdbx.internal.is_octave()
        try
            if strcmp(hash('md5', ''), 'd41d8cd98f00b204e9800998ecf8427e')
                mode = 1;
            end
        catch
        end
    else
        try
            java.security.MessageDigest.getInstance('MD5');
            mode = 2;
        catch
        end
    end
end
data = reshape(uint8(data), 1, []);
switch mode
    case 1
        h = hash('md5', char(data));
        d = uint8(hex2dec(reshape(h, 2, [])'))';
    case 2
        md = java.security.MessageDigest.getInstance('MD5');
        if ~isempty(data)
            % (MATLAB cannot pass an empty array to update(byte[]): its
            % overloads take the empty array for a missing scalar)
            md.update(typecast(data, 'int8'));
        end
        d = typecast(int8(md.digest()), 'uint8');
        d = reshape(d, 1, []);
    otherwise
        d = wfdbx.internal.md5_pure(data);
end
end
